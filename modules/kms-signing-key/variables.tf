# Copyright 2026 BitWise Media Group Ltd
# SPDX-License-Identifier: MIT

variable "name" {
  description = "Name for the key's alias (alias/<name>) and description (keep it short)."
  type        = string
  nullable    = false
  default     = "platform-artifact-signing"

  validation {
    condition     = can(regex("^[a-zA-Z0-9_-]{1,250}$", var.name))
    error_message = "name must contain only alphanumerics, hyphens and underscores (it becomes the KMS alias)."
  }
}

variable "key_spec" {
  description = <<-EOT
    Asymmetric key spec, immutable after creation. The default matches cosign's own default algorithm (ECDSA P-256 /
    SHA-256); the allowed set is the intersection of KMS signing specs and what cosign's AWS KMS provider supports —
    notably excluding ECC_SECG_P256K1, which sigstore does not accept.
  EOT
  type        = string
  nullable    = false
  default     = "ECC_NIST_P256"

  validation {
    condition = contains([
      "ECC_NIST_P256",
      "ECC_NIST_P384",
      "ECC_NIST_P521",
      "RSA_2048",
      "RSA_3072",
      "RSA_4096",
    ], var.key_spec)
    error_message = "key_spec must be a cosign-supported signing spec: ECC_NIST_P256/P384/P521 or RSA_2048/3072/4096."
  }
}

variable "deletion_window_in_days" {
  description = <<-EOT
    Days a scheduled deletion waits before the key is destroyed. Defaults to the KMS maximum: deleting this key
    permanently breaks cosign verification of every artifact ever signed with it, so the window should stay as long as
    possible.
  EOT
  type        = number
  nullable    = false
  default     = 30

  validation {
    condition     = var.deletion_window_in_days >= 7 && var.deletion_window_in_days <= 30
    error_message = "deletion_window_in_days must be between 7 and 30 (KMS limits)."
  }
}

variable "multi_region" {
  description = <<-EOT
    Create the key as a multi-region PRIMARY, allowing replicas in other regions later (same key material, so
    signatures verify against any replica). Immutable after creation — a single-region key can never be converted —
    so turn it on up front if regional isolation of the verification path may ever matter. The default stays
    single-region: the ARN works from any region, and verification is a rare, tiny, read-only call.
  EOT
  type        = bool
  nullable    = false
  default     = false
}

variable "organization_id" {
  description = <<-EOT
    AWS Organizations id (o-xxxxxxxxxx). When set, every principal in the organization may VERIFY against this key
    (kms:GetPublicKey / kms:DescribeKey / kms:Verify), matched by aws:PrincipalOrgID rather than an account list — so
    onboarding a new cluster account needs no change here. Verification is not a privilege (the public key is public);
    signing stays restricted. Null grants nothing beyond the owning account.
  EOT
  type        = string
  nullable    = true
  default     = null

  validation {
    condition     = var.organization_id == null || can(regex("^o-[a-z0-9]{10,32}$", var.organization_id))
    error_message = "organization_id must be an AWS Organizations id (o-xxxxxxxxxx)."
  }
}

variable "organization_paths" {
  description = <<-EOT
    Optional aws:PrincipalOrgPaths patterns narrowing the organization-wide verify grant to particular organizational
    units, e.g. ["o-abc123/r-root/ou-workloads/*"]. Empty admits the whole organization.
  EOT
  type        = list(string)
  nullable    = false
  default     = []
}

variable "signer_principals" {
  description = <<-EOT
    IAM principals in OTHER accounts allowed to sign with this key (kms:Sign plus the reads cosign needs) — e.g. an
    artifact-store module's publisher role ARNs when the store lives in a different account from the key. Cross-account
    KMS needs both this key-policy grant and an identity policy on the caller (artifact-store attaches the latter when
    given this key's ARN via signing_kms_key_arn). Same-account signers need only their identity policy and can leave
    this empty.
  EOT
  type        = list(string)
  nullable    = false
  default     = []
}

variable "additional_key_policy_statements" {
  description = <<-EOT
    Extra IAM statements merged into the key policy. A KMS key has exactly one policy and this module owns it, so any
    further resource-level grants (auditors, external verifiers outside the organization) must be passed here rather
    than managed elsewhere.
  EOT
  type        = list(any)
  nullable    = false
  default     = []
}

variable "tags" {
  description = "Tags applied to the key."
  type        = map(string)
  nullable    = false
  default     = {}
}
