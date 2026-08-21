# Copyright 2026 BitWise Media Group Ltd
# SPDX-License-Identifier: MIT

# The out-of-band credential secrets the flux-manifests stack syncs into the
# cluster (Secrets Store CSI driver + secrets-store-sync-controller). This is
# the terraform half of the secret-sync contract whose other half lives in
# flux-manifests: the secret names and the election gating are mirrored here,
# versioned with the module release that tracks those manifests -- when a
# sync moves, both halves move in one release instead of drifting apart in a
# caller's hand-rolled copy.
#
# Instantiate this from a DURABLE root, not beside the cluster: the secret
# VERSIONS are added out of band (aws secretsmanager put-secret-value --
# never terraform state) and must survive cluster destroy/recreate with no
# manual re-entry.
#
# Containers only, deliberately no grants -- the inverse of the GKE sibling.
# On EKS the read grant is identity-side: the cluster module creates the
# sync KSAs' IRSA reader roles with GetSecretValue/DescribeSecret
# scoped to ${SECRET_PREFIX}*, so these secrets are readable the moment the
# cluster exists. A durable-root resource policy naming those per-cluster
# role principals would invert the lifecycle -- PutResourcePolicy validates
# AWS principals, so the policy cannot land before the cluster and breaks
# (principals reduce to orphaned unique ids) every time it churns.
#
# The dex connector credentials ride the same sso declarations the cluster
# module publishes as DEX_CONNECTORS: pass the cluster module's sso value
# verbatim and each connector's secrets fields become dex-<id>-<field>
# containers here, in the durable root -- an upstream OAuth client outlives
# any one cluster, so its credentials must too.

locals {
  prefix = var.secret_prefix != null ? var.secret_prefix : ""

  patchy = contains(var.stack_components, "patchy")

  # secret name -> description. The gating mirrors the manifests exactly: a
  # secret no sync references is never created, and every referenced secret
  # exists (a SecretProviderClass naming an absent secret syncs nothing but
  # errors forever).
  containers = merge(
    # The patchy GitHub App credential (webhook validation, issue projection,
    # repository clone/push), synced unconditionally with the patchy
    # component.
    local.patchy ? {
      patchy-github-app-id          = "The patchy GitHub App's numeric id"
      patchy-github-app-private-key = "The patchy GitHub App's private key (PEM)"
      patchy-webhook-secret         = "The patchy GitHub App's webhook secret"
    } : {},

    # The Anthropic credential, consumed by the egress broker in the patchy
    # namespace and only when the claude runner's provider is anthropic: a
    # bedrock cluster authenticates with the broker's Pod Identity and needs
    # no secret at all.
    local.patchy && contains(var.agent_harnesses, "claude") && var.claude_provider == "anthropic" ? {
      patchy-anthropic-token = "The Anthropic credential the egress broker injects (claude setup-token OAuth token or API key)"
    } : {},

    # The non-brokered runners' model credentials, mounted into the agent
    # pods themselves.
    local.patchy && contains(var.agent_harnesses, "codex") ? {
      patchy-openai-token = "The OpenAI platform API key the codex CLI authenticates with"
    } : {},
    local.patchy && contains(var.agent_harnesses, "copilot") ? {
      patchy-copilot-token = "The Copilot CLI's fine-grained GitHub token (no repository permissions)"
    } : {},

    # The connector's out-of-band credentials (arbitrary SSO federation):
    # one container per field declared in sso.connector.secrets, named by
    # the effective id (defaulting to type, matching the cluster module's
    # sso.tf).
    var.sso.enabled && var.sso.connector != null ? {
      for field in var.sso.connector.secrets :
      "dex-${coalesce(var.sso.connector.id, var.sso.connector.type)}-${field}" => "The ${field} credential for dex's ${coalesce(var.sso.connector.id, var.sso.connector.type)} connector"
    } : {},
  )
}

resource "aws_secretsmanager_secret" "main" {
  for_each = local.containers

  name        = "${local.prefix}${each.key}"
  description = "${each.value}. Versions arrive out of band; readable by the cluster's secret-sync reader roles."

  tags = var.tags
}
