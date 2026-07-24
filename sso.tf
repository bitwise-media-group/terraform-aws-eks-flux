# Copyright 2026 BitWise Media Group Ltd
# SPDX-License-Identifier: MIT

# The per-cluster SSO client pairs between dex and its in-cluster relying
# parties (the Flux status web UI, the patchy status page). These are internal
# shared secrets with the cluster's lifecycle -- generated here, never entered
# out of band: each value is an ephemeral random_password written through
# write-only attributes, so it exists in Secrets Manager and nowhere else (not
# in state, not in plan). The manifests stack syncs each secret into its
# consumer namespaces under the same SECRET_PREFIX this module publishes.
#
# Two consumers need the value INLINE in a composed config document rather than
# as a raw key:
#   - flux-web-auth-config: the flux-operator Web Config API document (the
#     operator accepts no file or env indirection). Written from the same
#     ephemeral value as the raw dex-client-flux-web secret in the same apply,
#     so the pair cannot drift.
#   - patchy-status-auth-config: patchy's status server DOES support
#     clientSecretFile, so its document is secretless and both sides read the
#     one dex-client-patchy-status version.
#
# Everything here follows the optional-tier election (stack_components) and
# requires the DNS surface (issuer and redirect URLs need the domain): an
# unelected relying party gets no client, no secret, no grants.
#
# The one place this diverges from the GKE module: dex keeps its Google
# Workspace connector so users and RBAC groups are identical across both
# clouds, but EKS has no way to impersonate a Google service account. The
# directory-reader key therefore arrives OUT OF BAND into the container created
# below -- terraform owns the container and the accessor grant, never the
# value.

locals {
  # Normalized secret-name prefix (the variable is nullable; the empty-string
  # convention applies everywhere downstream).
  secret_prefix = var.secret_prefix != null ? var.secret_prefix : ""

  # client id -> the KSA subjects allowed to read its raw secret: always dex
  # (staticClients read via secretEnv), plus patchy's status server for the
  # client whose config points clientSecretFile at the synced key. A pair
  # exists only when sso deploys dex AND the relying party is elected.
  dex_client_readers = var.sso.enabled ? merge(
    contains(var.stack_components, "flux-web") ? {
      flux-web = ["dex/dex-secrets"]
    } : {},
    contains(var.stack_components, "patchy") ? {
      patchy-status = ["dex/dex-secrets", "patchy/patchy-secrets"]
    } : {},
  ) : {}

  dex_directory_secret_name = var.sso.enabled ? "${local.secret_prefix}dex-directory" : ""
}

# The Workspace directory-reader credentials dex impersonates for group claims.
# Terraform creates the container and the reader grant; the key JSON is written
# out of band (a rotation there needs no apply here).
resource "aws_secretsmanager_secret" "dex_directory" {
  count = var.sso.enabled ? 1 : 0

  name        = local.dex_directory_secret_name
  description = "Google Workspace directory-reader credentials for dex (${var.name}) — value supplied out of band"

  # No recovery window anywhere in this file: deleted secrets vanish
  # immediately rather than lingering in a 30-day scheduled-deletion state
  # that would block recreating the cluster under the same names.
  recovery_window_in_days = 0

  tags = var.tags
}

# The generated client secrets. Ephemeral: re-opened every run, persisted
# nowhere; the write-only versions below only consume a fresh result when their
# rotation number (sso.client_rotation) moves.
ephemeral "random_password" "dex_client" {
  for_each = local.dex_client_readers

  length  = 48
  special = false
}

resource "aws_secretsmanager_secret" "dex_client" {
  for_each = local.dex_client_readers

  name                    = "${local.secret_prefix}dex-client-${each.key}"
  description             = "dex OAuth2 client secret for ${each.key} (${var.name})"
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
  secret_string_wo_version = lookup(var.sso.client_rotation, each.key, 1)
}

# The Flux status web UI's Web Config API document, client secret embedded.
# Synced to flux-system/flux-web-auth (the manifests contract's fixed name,
# wired to the operator in flux.tf) by the manifests' flux-web component and
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
      baseURL = "https://flux.${local.patchy_domain}"
      authentication = {
        type = "OAuth2"
        oauth2 = {
          provider     = "OIDC"
          issuerURL    = "https://dex.${local.patchy_domain}"
          clientID     = "flux-web"
          clientSecret = ephemeral.random_password.dex_client["flux-web"].result

          # The groups claim drives the UI's Kubernetes impersonation, which
          # the RBAC_GROUP_* bindings (flux-manifests rbac component)
          # authorize against -- dex resolves transitive Workspace membership,
          # so the same group names work here and in kubectl. Scopes and
          # expressions mirror the operator's own defaults, pinned so the RBAC
          # contract survives upstream default drift.
          scopes = ["openid", "offline_access", "profile", "email", "groups"]
          impersonation = {
            username = "has(claims.email) ? claims.email : ''"
            groups   = "has(claims.groups) ? claims.groups : []"
          }
        }
      }
    }
  })
  secret_string_wo_version = lookup(var.sso.client_rotation, "flux-web", 1)
}

# The patchy status server's auth config document: secretless (clientSecretFile
# points at the client-secret key the SecretSync places beside it), so a plain
# version keeps it visible in plan.
resource "aws_secretsmanager_secret" "patchy_status_auth_config" {
  count = contains(keys(local.dex_client_readers), "patchy-status") ? 1 : 0

  name                    = "${local.secret_prefix}patchy-status-auth-config"
  description             = "patchy status server OIDC configuration (${var.name})"
  recovery_window_in_days = 0

  tags = var.tags
}

resource "aws_secretsmanager_secret_version" "patchy_status_auth_config" {
  count = length(aws_secretsmanager_secret.patchy_status_auth_config)

  secret_id = aws_secretsmanager_secret.patchy_status_auth_config[0].id

  secret_string = yamlencode({
    mode = "oidc"
    oidc = {
      issuerURL        = "https://dex.${local.patchy_domain}"
      clientID         = "patchy-status"
      clientSecretFile = "/etc/patchy/auth/client-secret"
    }
  })
}

# Read access for the syncing KSAs, as a resource policy per secret naming its
# exact readers. The identity side (iam.tf) already scopes each reader role to
# ${SECRET_PREFIX}*; this narrows the other direction, so a secret and the
# audience allowed to read it are declared — and deleted — together.
locals {
  # Which secret-reader identities the SSO surface implies. Derived rather than
  # caller-listed: the pairs are fixed by the manifests contract, and an
  # unelected relying party must not get a role. iam.tf turns each into a
  # workload role + Pod Identity association, keyed secrets-<ns>-<sa>.
  sso_secret_readers = var.sso.enabled ? concat(
    [{ namespace = "dex", service_account = "dex-secrets" }],
    contains(var.stack_components, "patchy") ? [{ namespace = "patchy", service_account = "patchy-secrets" }] : [],
    contains(var.stack_components, "flux-web") ? [{ namespace = "flux-system", service_account = "flux-web-secrets" }] : [],
  ) : []

  # A STATIC key per secret -> its (apply-time) ARN and the workload role keys
  # allowed to read it. Keying on the secret's own id would make for_each
  # unknown at plan time — every key here is derived from the election alone,
  # so the instance set is fixed before anything is created.
  secret_reader_roles = merge(
    {
      for client, readers in local.dex_client_readers :
      "dex-client-${client}" => {
        arn   = aws_secretsmanager_secret.dex_client[client].arn
        roles = [for reader in readers : "secrets-${replace(reader, "/", "-")}"]
      }
    },
    var.sso.enabled ? {
      dex-directory = {
        arn   = aws_secretsmanager_secret.dex_directory[0].arn
        roles = ["secrets-dex-dex-secrets"]
      }
    } : {},
    contains(keys(local.dex_client_readers), "flux-web") ? {
      flux-web-auth-config = {
        arn   = aws_secretsmanager_secret.flux_web_auth_config[0].arn
        roles = ["secrets-flux-system-flux-web-secrets"]
      }
    } : {},
    contains(keys(local.dex_client_readers), "patchy-status") ? {
      patchy-status-auth-config = {
        arn   = aws_secretsmanager_secret.patchy_status_auth_config[0].arn
        roles = ["secrets-patchy-patchy-secrets"]
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
