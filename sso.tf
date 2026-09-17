# Copyright 2026 BitWise Media Group Ltd
# SPDX-License-Identifier: MIT

# The per-cluster SSO client pairs between dex and its relying parties: the
# platform's own (the Flux status web UI, the public kubectl client) and every
# client an application declares (applications[*].dex_clients). The
# confidential ones are internal shared secrets with the cluster's lifecycle
# -- generated here, never entered out of band: each value is an ephemeral
# random_password written through write-only attributes, so it exists in
# Secrets Manager and nowhere else (not in state, not in plan). The platform's
# dex component syncs each ${SECRET_PREFIX}dex-client-<id> secret into dex's
# env, and an application's own secret-sync recipe reads it into its
# namespace through the readers it declares.
#
# One platform consumer needs the value INLINE in a composed config document
# rather than as a raw key: flux-web-auth-config, the flux-operator Web Config
# API document (the operator accepts no file or env indirection). Written from
# the same ephemeral value as the raw dex-client-flux-web secret in the same
# apply, so the pair cannot drift. An application needing the same treatment
# either reads the raw synced key (dex supports clientSecretFile-style
# consumers) or composes its document in a second-stage module of its own
# repository, reading the container by its static name after the cluster
# apply -- the cluster module never learns an application's config shape.
#
# Everything here follows the elections (platform_components, sso.kubectl,
# applications) and requires the DNS surface (issuer and redirect URLs need the
# domain): an unelected relying party gets no client, no secret, no grants.
#
# dex federates to whatever upstream identity provider sso.connector
# declares; local.dex_connectors normalizes that declaration (defaulting
# id and name, injecting a shared redirectURI) into the shape flux.tf
# publishes as DEX_CONNECTORS. The dex-<id>-<field> credential containers
# the declaration implies live in modules/sso-secrets, instantiated in a
# durable root and fed the same sso value verbatim (applying the same
# id-defaults-to-type rule, so the naming cannot drift) -- an upstream
# OAuth client outlives any one cluster, so its out-of-band credentials
# must too. The prefix-scoped reader roles (iam.tf) make them readable
# here the moment the cluster exists.

locals {
  # Normalized secret-name prefix (the variable is nullable; the empty-string
  # convention applies everywhere downstream).
  secret_prefix = var.secret_prefix != null ? var.secret_prefix : ""

  # The platform's own relying parties: the Flux status web UI when elected,
  # and the PUBLIC kubectl client (no secret: the OIDC/PKCE flow kubelogin
  # drives cannot hold one) when sso.kubectl is on. Both exist only when sso
  # deploys dex.
  platform_dex_clients = var.sso.enabled ? merge(
    contains(var.platform_components, "flux-web") ? {
      flux-web = {
        name          = "Flux Status"
        public        = false
        redirect_uris = ["https://flux.${local.platform_domain}/oauth2/callback"]
        readers       = []
        version       = try(var.sso.clients["flux-web"].version, 1)
      }
    } : {},
    var.sso.kubectl.enabled ? {
      (var.sso.kubectl.client_id) = {
        name          = "kubectl"
        public        = true
        redirect_uris = var.sso.kubectl.redirect_uris
        readers       = []
        version       = 1
      }
    } : {},
  ) : {}

  # Every client an application declares, flattened into the one dex client
  # namespace (var.applications' validations guarantee the ids are unique
  # across applications and never collide with the platform's). The display
  # name defaults to the id.
  application_dex_clients = var.sso.enabled ? merge([
    for app in values(var.applications) : {
      for id, client in app.dex_clients : id => {
        name          = coalesce(client.name, id)
        public        = client.public
        redirect_uris = client.redirect_uris
        readers       = client.readers
        version       = client.version
      }
    }
  ]...) : {}

  # client id -> the normalized client, platform and application alike. This
  # is what DEX_CLIENTS publishes (flux.tf) and what the secrets below are
  # minted from, so the two cannot drift.
  dex_clients = merge(local.platform_dex_clients, local.application_dex_clients)

  # The clients that carry a generated secret, with the KSA subjects allowed
  # to read it: always dex (staticClients read via env), plus whichever
  # secret-sync readers the client declares (an application's own
  # namespace/service-account pairs, validated to exist in
  # workload_identity.secret_readers).
  dex_client_readers = {
    for id, client in local.dex_clients : id => concat(["dex/dex-secrets"], tolist(client.readers))
    if !client.public
  }

  # The normalized connector dex's config renders from (flux.tf), kept as
  # a one-entry map keyed by the effective id so the published
  # DEX_CONNECTORS JSON array -- and the manifests ranging over it -- is
  # unchanged from the map-shaped variable days. The connector shares the
  # cluster's callback endpoint; inject it as a default so callers don't
  # have to repeat their own domain, but let an explicit config.redirectURI
  # win.
  dex_connector_id = var.sso.connector != null ? coalesce(var.sso.connector.id, var.sso.connector.type) : null

  dex_connectors = var.sso.enabled ? {
    (local.dex_connector_id) = {
      type    = var.sso.connector.type
      name    = coalesce(var.sso.connector.name, local.dex_connector_id)
      secrets = var.sso.connector.secrets
      config  = merge({ redirectURI = "https://dex.${local.platform_domain}/callback" }, var.sso.connector.config)
    }
  } : {}
}

# The generated client secrets. Ephemeral: re-opened every run, persisted
# nowhere; the write-only versions below only consume a fresh result when their
# rotation number (the client's version) moves.
ephemeral "random_password" "dex_client" {
  for_each = local.dex_client_readers

  length  = 48
  special = false
}

resource "aws_secretsmanager_secret" "dex_client" {
  for_each = local.dex_client_readers

  name        = "${local.secret_prefix}dex-client-${each.key}"
  description = "dex OAuth2 client secret for ${each.key} (${var.name})"

  # No recovery window anywhere in this file: deleted secrets vanish
  # immediately rather than lingering in a 30-day scheduled-deletion state
  # that would block recreating the cluster under the same names.
  recovery_window_in_days = 0

  tags = var.tags
}

resource "aws_secretsmanager_secret_version" "dex_client" {
  for_each = aws_secretsmanager_secret.dex_client

  secret_id = each.value.id

  # Write-only: the value reaches Secrets Manager without ever entering state
  # or a plan file. Bumping the rotation counter is what re-reads the ephemeral
  # password.
  secret_string_wo         = ephemeral.random_password.dex_client[each.key].result
  secret_string_wo_version = local.dex_clients[each.key].version
}

# The Flux status web UI's Web Config API document, client secret embedded.
# Synced to flux-system/flux-web-auth (the platform contract's fixed name,
# wired to the operator in flux.tf) by the platform's flux-web component and
# hot-reloaded by flux-operator.
resource "aws_secretsmanager_secret" "flux_web_auth_config" {
  count = contains(keys(local.dex_client_readers), "flux-web") ? 1 : 0

  name                    = "${local.secret_prefix}flux-web-auth-config"
  description             = "flux-operator Web Config API document (${var.name})"
  recovery_window_in_days = 0

  tags = var.tags
}

resource "aws_secretsmanager_secret_version" "flux_web_auth_config" {
  count = length(aws_secretsmanager_secret.flux_web_auth_config)

  secret_id = aws_secretsmanager_secret.flux_web_auth_config[0].id

  secret_string_wo = yamlencode({
    apiVersion = "web.fluxcd.controlplane.io/v1"
    kind       = "Config"
    spec = {
      baseURL = "https://flux.${local.platform_domain}"
      authentication = {
        type = "OAuth2"
        oauth2 = {
          provider     = "OIDC"
          issuerURL    = "https://dex.${local.platform_domain}"
          clientID     = "flux-web"
          clientSecret = ephemeral.random_password.dex_client["flux-web"].result

          # The groups claim drives the UI's Kubernetes impersonation, which
          # the RBAC_GROUP_* bindings (the platform's rbac component)
          # authorize against -- dex resolves group membership from its
          # upstream provider, so the same group names work here and in
          # kubectl. Scopes and expressions mirror the operator's own defaults,
          # pinned so the RBAC contract survives upstream default drift.
          scopes = ["openid", "offline_access", "profile", "email", "groups"]
          impersonation = {
            username = "has(claims.email) ? claims.email : ''"
            groups   = "has(claims.groups) ? claims.groups : []"
          }
        }
      }
    }
  })
  secret_string_wo_version = local.dex_clients["flux-web"].version
}

# Read access for the syncing KSAs, as a resource policy per secret naming its
# exact readers. The identity side (iam.tf) already scopes each reader role to
# ${SECRET_PREFIX}*; this narrows the other direction, so a secret and the
# audience allowed to read it are declared - and deleted - together.
locals {
  # Which secret-reader identities the SSO surface implies. Derived rather than
  # caller-listed: the pairs are fixed by the platform contract, and an
  # unelected relying party must not get a role. iam.tf turns each into a
  # workload role with an IRSA trust (the syncs are podless), keyed
  # secrets-<ns>-<sa>. Application readers arrive through
  # workload_identity.secret_readers instead.
  sso_secret_readers = var.sso.enabled ? concat(
    [{ namespace = "dex", service_account = "dex-secrets" }],
    contains(var.platform_components, "flux-web") ? [{ namespace = "flux-system", service_account = "flux-web-secrets" }] : [],
  ) : []

  # A STATIC key per secret -> its (apply-time) ARN and the workload role keys
  # allowed to read it. Keying on the secret's own id would make for_each
  # unknown at plan time - every key here is derived from the election alone,
  # so the instance set is fixed before anything is created.
  secret_reader_roles = merge(
    {
      for client, readers in local.dex_client_readers :
      "dex-client-${client}" => {
        arn   = aws_secretsmanager_secret.dex_client[client].arn
        roles = [for reader in readers : "secrets-${replace(reader, "/", "-")}"]
      }
    },
    contains(keys(local.dex_client_readers), "flux-web") ? {
      flux-web-auth-config = {
        arn   = aws_secretsmanager_secret.flux_web_auth_config[0].arn
        roles = ["secrets-flux-system-flux-web-secrets"]
      }
    } : {},
  )
}

data "aws_iam_policy_document" "secret_readers" {
  for_each = local.secret_reader_roles

  statement {
    sid       = "AllowSyncingWorkloads"
    effect    = "Allow"
    actions   = ["secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret"]
    resources = ["*"]

    principals {
      type        = "AWS"
      identifiers = [for key in each.value.roles : aws_iam_role.workload[key].arn]
    }
  }
}

resource "aws_secretsmanager_secret_policy" "readers" {
  for_each = local.secret_reader_roles

  secret_arn = each.value.arn
  policy     = data.aws_iam_policy_document.secret_readers[each.key].json
}
