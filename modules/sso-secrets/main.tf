# Copyright 2026 BitWise Media Group Ltd
# SPDX-License-Identifier: MIT

# The out-of-band SSO credential containers the platform's dex component
# syncs into the cluster (Secrets Store CSI driver + secrets-store-sync
# controller). This is the terraform half of the platform's dex secret-sync
# contract whose other half lives in platform-manifests: the container names
# are mirrored here, versioned with the module release that tracks those
# manifests -- when a sync moves, both halves move in one release instead of
# drifting apart in a caller's hand-rolled copy.
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
# The dex connector credentials ride the same sso declaration the cluster
# module publishes as DEX_CONNECTORS: pass the cluster module's sso value
# verbatim and each connector's secrets fields become dex-<id>-<field>
# containers here, in the durable root -- an upstream OAuth client outlives
# any one cluster, so its credentials must too. Application credentials are
# not this module's business: each application's own module (composed in
# the root beside the cluster module) creates its containers under the same
# secret_prefix.

locals {
  prefix = var.secret_prefix != null ? var.secret_prefix : ""

  # secret name -> description. The gating mirrors the manifests exactly: a
  # secret no sync references is never created, and every referenced secret
  # exists (a SecretProviderClass naming an absent secret syncs nothing but
  # errors forever). One container per field declared in
  # sso.connector.secrets, named by the effective id (defaulting to type,
  # matching the cluster module's sso.tf).
  containers = var.sso.enabled && var.sso.connector != null ? {
    for field in var.sso.connector.secrets :
    "dex-${coalesce(var.sso.connector.id, var.sso.connector.type)}-${field}" => "The ${field} credential for dex's ${coalesce(var.sso.connector.id, var.sso.connector.type)} connector"
  } : {}
}

resource "aws_secretsmanager_secret" "main" {
  for_each = local.containers

  name        = "${local.prefix}${each.key}"
  description = "${each.value}. Versions arrive out of band; readable by the cluster's secret-sync reader roles."

  tags = var.tags
}
