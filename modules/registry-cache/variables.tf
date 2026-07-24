# Copyright 2026 BitWise Media Group Ltd
# SPDX-License-Identifier: MIT

variable "name" {
  description = "Base name for the cache's IAM role and consumer policy (keep it short)."
  type        = string
  nullable    = false
  default     = "platform"

  validation {
    condition     = can(regex("^[a-z]([a-z0-9-]{0,20})$", var.name))
    error_message = "name must be a lowercase label of at most 21 characters (it prefixes IAM role names)."
  }
}

variable "upstream" {
  description = <<-EOT
    The artifact store this caches. registry_id and repository_prefix come straight from the artifact-store module's
    registry_id / repository_prefix outputs; region is the store's region. The store must admit this account — which it
    does org-wide by default (aws:PrincipalOrgID), so no change there is needed to onboard.
  EOT
  type = object({
    registry_id       = string
    region            = string
    repository_prefix = optional(string, "platform")
  })
  nullable = false

  validation {
    condition     = can(regex("^[0-9]{12}$", var.upstream.registry_id))
    error_message = "upstream.registry_id must be a 12-digit AWS account id."
  }
}

variable "repository_prefix" {
  description = <<-EOT
    Local repository prefix the cached artifacts appear under. Null mirrors the upstream prefix, so image paths are
    identical on both sides and a cluster moves between store and cache by swapping one variable — keep it that way
    unless the prefix is already taken in this registry.
  EOT
  type        = string
  nullable    = true
  default     = null

  validation {
    condition     = var.repository_prefix == null || can(regex("^[a-z0-9][a-z0-9._-]*$", var.repository_prefix))
    error_message = "repository_prefix must be a valid ECR repository name component."
  }
}

variable "kms_key_arn" {
  description = "Customer-managed KMS key for the cached repositories; null uses ECR's AES256 default."
  type        = string
  nullable    = true
  default     = null
}

variable "untagged_expiry_days" {
  description = "Days after which untagged cached manifests are deleted. They re-cache on the next pull, so this is a cost control rather than a retention policy."
  type        = number
  nullable    = false
  default     = 14
}

variable "tags" {
  description = "Tags applied to the IAM role, the consumer policy and every cached repository."
  type        = map(string)
  nullable    = false
  default     = {}
}
