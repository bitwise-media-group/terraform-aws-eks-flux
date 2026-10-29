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
    <prefix>/images/<original-path>, and the manifest images at <prefix>/manifests/platform (the platform
    entrypoint), <prefix>/manifests/<component> and <prefix>/manifests/<application>. The creation template is
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
    AWS Organizations id (o-xxxxxxxxxx). Every account in the organization may read the store and its replicas,
    matched by aws:PrincipalOrgID rather than an account list - so onboarding a new cluster account needs no change
    here. Narrow it with organization_paths or account_ids if the whole org is too broad.
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
    Optional aws:PrincipalOrgPaths patterns narrowing the read grant to particular organizational units, e.g.
    ["o-abc123/r-root/ou-workloads/*"]. Empty admits the whole organization.
  EOT
  type        = list(string)
  nullable    = false
  default     = []
}

variable "account_ids" {
  description = <<-EOT
    Optional aws:PrincipalAccount ids narrowing the read grant to particular member accounts, for a store only a known
    set of accounts should read - onboarding another one then means adding it here. Empty admits the whole
    organization (or organization_paths).
  EOT
  type        = set(string)
  nullable    = false
  default     = []

  validation {
    condition     = alltrue([for account_id in var.account_ids : can(regex("^[0-9]{12}$", account_id))])
    error_message = "account_ids must be 12-digit AWS account ids."
  }
}

variable "replica_regions" {
  description = <<-EOT
    Regions, in this same account, the store is replicated to - one per region clusters run in outside the primary
    (the region this module is applied in). Every push, channel-tag moves included, is copied to each, and a cluster
    reads the replica in its own region (the platform_registries output), so it keeps reconciling while the primary
    region is down. Each replica gets the same creation templates (as REPLICATION templates), registry policy and
    scanning. Only pushes made after a region is added replicate: run that region's
    replication_backfill_commands entry once to copy what is already in the store.
  EOT
  type        = set(string)
  nullable    = false
  default     = []

  validation {
    condition     = length(var.replica_regions) <= 25
    error_message = "ECR replication supports at most 25 destinations."
  }

  validation {
    condition     = alltrue([for region in var.replica_regions : can(regex("^[a-z]{2}(-[a-z]+)+-[0-9]$", region))])
    error_message = "replica_regions must be AWS region names (e.g. eu-west-2)."
  }
}

variable "additional_registry_statements" {
  description = <<-EOT
    Extra IAM statements merged into the ECR registry policy of every region (the primary and each replica). ECR
    allows exactly one registry policy per account per region and this module owns it, so an account using registry
    policies for anything else must pass those statements here rather than declaring a second resource.
  EOT
  type        = list(any)
  nullable    = false
  default     = []
}

variable "github" {
  description = <<-EOT
    GitHub org and repository names the publisher trust is pinned to, plus the immutable numeric ids GitHub embeds in
    the OIDC subjects of post-2026-07-15 repos (org_id from GET /orgs/<org>, repo ids from GET /repos/<org>/<repo>).
    containers is the chart/image mirror (flux-containers). manifest_publishers is every repo that publishes manifest
    images, keyed by repo name: the platform's (paths ["manifests/*"], the platform authority) and one per application
    repo (paths ["manifests/<app>"], so an application can never overwrite the platform). Each gets its own role,
    trusted from main, release tags and the promotion environment, with push scoped to exactly its paths;
    repository_id may stay null until that repo exists on GitHub. platform names the key that publishes the
    platform entrypoint - its workflow identities are what signed_identity_subjects exports for the cluster
    module.
  EOT
  type = object({
    org           = optional(string, "bitwise-media-group")
    org_id        = optional(number, 282673588)
    containers    = optional(string, "flux-containers")
    containers_id = optional(number, 1303643498)
    platform      = optional(string, "flux-manifests")
    manifest_publishers = optional(map(object({
      repository_id = optional(number)
      paths         = list(string)
    })), { flux-manifests = { paths = ["manifests/*"] } })
  })
  nullable = false
  default  = {}

  validation {
    condition     = contains(keys(var.github.manifest_publishers), var.github.platform)
    error_message = "github.platform must name a key of github.manifest_publishers - the platform entrypoint's publisher is what the clusters' signed_identity_subjects pin."
  }

  validation {
    condition = alltrue([
      for repo in keys(var.github.manifest_publishers) : can(regex("^[A-Za-z0-9._-]+$", repo))
    ])
    error_message = "github.manifest_publishers keys must be GitHub repository names (they also suffix the publisher role names)."
  }

  validation {
    condition = alltrue(flatten([
      for publisher in values(var.github.manifest_publishers) : concat(
        [length(publisher.paths) > 0],
        [for path in publisher.paths : can(regex("^[a-z0-9._-]+(/[a-z0-9._-]+)*(/\\*)?$", path))],
      )
    ]))
    error_message = "Each github.manifest_publishers entry needs at least one path beneath the prefix (e.g. manifests/* or manifests/<app>): path segments of ECR name characters, with at most a trailing /* wildcard."
  }
}

variable "promotion_environment" {
  description = "GitHub environment (protected, reviewer-gated) whose jobs may move the stable channel tag."
  type        = string
  nullable    = false
  default     = "production"
}

variable "oidc_provider_arn" {
  description = <<-EOT
    ARN of an existing GitHub Actions OIDC provider in this account. Null creates one here - convenient for a
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

variable "kms_key_arns" {
  description = <<-EOT
    Customer-managed KMS keys for repository encryption, keyed by region. KMS keys are regional, so when set this must
    hold one for the primary region and one for every replica region (the replicas of a multi-region key work). Empty
    uses ECR's AES256 default everywhere.
  EOT
  type        = map(string)
  nullable    = false
  default     = {}

  validation {
    condition     = alltrue([for arn in values(var.kms_key_arns) : can(regex("^arn:aws[a-z-]*:kms:", arn))])
    error_message = "kms_key_arns values must be KMS key ARNs."
  }
}

variable "signing_kms_key_arn" {
  description = <<-EOT
    Asymmetric SIGN_VERIFY KMS key the publish workflows sign artifacts with (cosign sign --key awskms:///<arn>),
    instead of keyless Fulcio identities. When set, every publisher role gets kms:Sign / kms:GetPublicKey /
    kms:DescribeKey on the key; feed the same ARN to the cluster module's signed_identity.kms_key_arn so verification
    matches. Null keeps signing keyless (the signed_identity_subjects output). The key itself lives outside this
    module - signing identity should outlive any one store.
  EOT
  type        = string
  nullable    = true
  default     = null

  validation {
    condition     = var.signing_kms_key_arn == null || can(regex("^arn:aws[a-z-]*:kms:", var.signing_kms_key_arn))
    error_message = "signing_kms_key_arn must be a KMS key ARN."
  }
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
