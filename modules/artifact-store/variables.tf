# Copyright 2026 BitWise Media Group Ltd
# SPDX-License-Identifier: MIT

variable "name" {
  description = "Base name for the publisher and repository-creation IAM roles (keep it short)."
  type        = string
  nullable    = false
  default     = "platform"

  validation {
    condition     = can(regex("^[a-z]([a-z0-9-]{0,20})$", var.name))
    error_message = "name must be a lowercase label of at most 21 characters (it prefixes IAM role names)."
  }
}

variable "repository_prefix" {
  description = <<-EOT
    ECR repository name prefix everything lands beneath: charts at <prefix>/charts/<name>, images at
    <prefix>/images/<original-path>, and the manifests artifact at <prefix>/flux-manifests. The creation template is
    keyed on this prefix, so it is also what makes create-on-push work.
  EOT
  type        = string
  nullable    = false
  default     = "platform"

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9._-]*$", var.repository_prefix))
    error_message = "repository_prefix must be a valid ECR repository name component."
  }
}

variable "organization_id" {
  description = <<-EOT
    AWS Organizations id (o-xxxxxxxxxx). Every account in the organization may pull through an ECR pull-through cache,
    matched by aws:PrincipalOrgID rather than an account list — so onboarding a new cluster account needs no change
    here. Narrow it with organization_paths if the whole org is too broad.
  EOT
  type        = string
  nullable    = false

  validation {
    condition     = can(regex("^o-[a-z0-9]{10,32}$", var.organization_id))
    error_message = "organization_id must be an AWS Organizations id (o-xxxxxxxxxx)."
  }
}

variable "organization_paths" {
  description = <<-EOT
    Optional aws:PrincipalOrgPaths patterns narrowing the pull-through grant to particular organizational units, e.g.
    ["o-abc123/r-root/ou-workloads/*"]. Empty admits the whole organization.
  EOT
  type        = list(string)
  nullable    = false
  default     = []
}

variable "direct_pull_principals" {
  description = <<-EOT
    IAM principals allowed to pull from the store DIRECTLY rather than through a pull-through cache — the escape hatch
    for clusters the platform team lets read it straight. Feed a cluster module's registry_reader_principals output
    through here. Content security is cosign verification, not read denial, so coarse principals are acceptable.
  EOT
  type        = list(string)
  nullable    = false
  default     = []
}

variable "additional_registry_statements" {
  description = <<-EOT
    Extra IAM statements merged into the ECR registry policy. ECR allows exactly one registry policy per account per
    region and this module owns it, so an account using registry policies for anything else must pass those statements
    here rather than declaring a second resource.
  EOT
  type        = list(any)
  nullable    = false
  default     = []
}

variable "github" {
  description = <<-EOT
    GitHub org and repository names the publisher trust is pinned to, plus the immutable numeric ids GitHub embeds in
    the OIDC subjects of post-2026-07-15 repos (org_id from GET /orgs/<org>, repo ids from GET /repos/<org>/<repo>).
    manifests_id may stay null until that repo exists on GitHub.
  EOT
  type = object({
    org           = optional(string, "bitwise-media-group")
    org_id        = optional(number, 282673588)
    containers    = optional(string, "flux-containers")
    containers_id = optional(number, 1303643498)
    manifests     = optional(string, "flux-manifests")
    manifests_id  = optional(number)
  })
  nullable = false
  default  = {}
}

variable "promotion_environment" {
  description = "GitHub environment (protected, reviewer-gated) whose jobs may move the stable channel tag."
  type        = string
  nullable    = false
  default     = "production"
}

variable "oidc_provider_arn" {
  description = <<-EOT
    ARN of an existing GitHub Actions OIDC provider in this account. Null creates one here — convenient for a
    standalone store, but an account that already has one (or gets one from a cloud-accounts aws environment) must pass
    it, since IAM permits only a single provider per issuer URL.
  EOT
  type        = string
  nullable    = true
  default     = null
}

variable "github_oidc_thumbprints" {
  description = <<-EOT
    Certificate thumbprints for the GitHub Actions OIDC provider, used only when this module creates it. IAM no longer
    validates these for well-known issuers, so the value is a formality kept explicit rather than implicit.
  EOT
  type        = list(string)
  nullable    = false
  default     = ["6938fd4d98bab03faadb97b34396831e3780aea1"]
}

variable "kms_key_arn" {
  description = "Customer-managed KMS key for repository encryption; null uses ECR's AES256 default."
  type        = string
  nullable    = true
  default     = null
}

variable "enhanced_scanning" {
  description = <<-EOT
    Turn on ECR enhanced (Inspector) continuous scanning for the platform prefix. Registry-scoped by construction, so
    leave it off where another owner manages the registry's scanning configuration.
  EOT
  type        = bool
  nullable    = false
  default     = true
}

variable "untagged_expiry_days" {
  description = "Days after which untagged manifests (failed/superseded pushes) are deleted."
  type        = number
  nullable    = false
  default     = 14
}

variable "tags" {
  description = "Tags applied to the IAM roles and to every repository the creation template makes."
  type        = map(string)
  nullable    = false
  default     = {}
}
