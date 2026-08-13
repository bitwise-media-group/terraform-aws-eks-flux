# Copyright 2026 BitWise Media Group Ltd
# SPDX-License-Identifier: MIT

# An asymmetric KMS key for cosign signing of platform artifacts.
#
# This is the key the artifact-store module's signing_kms_key_arn and the
# cluster module's signed_identity.kms_key_arn both point at when signing is
# KMS-based rather than keyless. It lives in its own module because the signing
# identity must outlive any one store or cluster: artifacts already published
# verify against THIS key forever, so its lifecycle is deliberately decoupled
# from the infrastructure that signs with or verifies against it.
#
# Two properties make a KMS key cosign-appropriate, and both are immutable
# after creation:
#
#   - key_usage SIGN_VERIFY — an ENCRYPT_DECRYPT key (the KMS default) cannot
#     sign at all.
#   - an asymmetric signing spec cosign supports — ECC_NIST_P256 by default,
#     matching cosign's own default algorithm (ECDSA P-256 / SHA-256).
#
# Publishers sign with `cosign sign --key awskms:///<key-arn>`; verifiers need
# only the public half (kms:GetPublicKey, or the exported PEM), never the
# private key, which never leaves KMS.
#
# There is deliberately no enable_key_rotation here: KMS cannot auto-rotate
# asymmetric keys, and rotating a signing key is not an operational nicety but
# an identity change — every consumer must be re-pointed and existing
# signatures no longer match. Rotation, when needed, is a new key plus
# re-signing, coordinated by humans. For the same reason the deletion window
# defaults to the maximum: deleting this key permanently breaks verification
# of everything ever signed with it.

data "aws_caller_identity" "current" {}

data "aws_partition" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id
  partition  = data.aws_partition.current.partition

  # Owning-account root: keeps the account in control (no lockout) and — the
  # load-bearing part — delegates to IAM identity policies, which is how the
  # artifact-store module grants its publisher roles kms:Sign without touching
  # this key policy.
  root_statement = {
    Sid       = "EnableIAMPolicies"
    Effect    = "Allow"
    Action    = "kms:*"
    Resource  = "*"
    Principal = { AWS = "arn:${local.partition}:iam::${local.account_id}:root" }
  }

  # Cross-account signers (e.g. an artifact store in another account). Cross-
  # account KMS access needs BOTH sides: this key-policy grant and an identity
  # policy in the caller's account (which artifact-store attaches when handed
  # this key's ARN). Same-account signers need only the IAM delegation above.
  signer_statements = length(var.signer_principals) > 0 ? [
    {
      Sid       = "Sign"
      Effect    = "Allow"
      Action    = ["kms:Sign", "kms:GetPublicKey", "kms:DescribeKey"]
      Resource  = "*"
      Principal = { AWS = var.signer_principals }
    }
  ] : []

  # Verification is not a privilege — the public key is public. Granting it
  # org-wide (wildcard principal, aws:PrincipalOrgID condition) means a new
  # cluster account onboards without editing this module: the cluster module's
  # plan-time aws_kms_public_key read, the bootstrap public-key Secret, and
  # kyverno's admission-time kms:Verify calls all just work.
  verify_statements = var.organization_id != null ? [
    {
      Sid       = "OrganizationVerify"
      Effect    = "Allow"
      Action    = ["kms:GetPublicKey", "kms:DescribeKey", "kms:Verify"]
      Resource  = "*"
      Principal = { AWS = "*" }
      Condition = merge(
        { StringEquals = { "aws:PrincipalOrgID" = var.organization_id } },
        # Optional narrowing to specific organizational units.
        length(var.organization_paths) > 0 ? {
          "ForAnyValue:StringLike" = { "aws:PrincipalOrgPaths" = var.organization_paths }
        } : {},
      )
    }
  ] : []

  key_policy_statements = concat(
    [local.root_statement],
    local.signer_statements,
    local.verify_statements,
    var.additional_key_policy_statements,
  )
}

resource "aws_kms_key" "signing" {
  description = "Cosign signing key for ${var.name} artifacts"

  key_usage                = "SIGN_VERIFY"
  customer_master_key_spec = var.key_spec

  deletion_window_in_days = var.deletion_window_in_days
  multi_region            = var.multi_region

  policy = jsonencode({
    Version   = "2012-10-17"
    Statement = local.key_policy_statements
  })

  tags = var.tags
}

# Stable human-readable handle. Signing and verification should still reference
# the ARN (it encodes account and region, so it works from anywhere); the alias
# exists for consoles, CLIs and same-account convenience — and re-pointing it
# is NOT rotation, since everything is wired by ARN.
resource "aws_kms_alias" "signing" {
  name          = "alias/${var.name}"
  target_key_id = aws_kms_key.signing.key_id
}

# The public half, exported for offline distribution (committing a cosign.pub,
# verifying without AWS credentials). Consumers inside the org can equally
# fetch it themselves via kms:GetPublicKey.
data "aws_kms_public_key" "signing" {
  key_id = aws_kms_key.signing.arn
}
