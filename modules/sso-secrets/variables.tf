# Copyright 2026 BitWise Media Group Ltd
# SPDX-License-Identifier: MIT

variable "secret_prefix" {
  description = <<-EOT
    Prefix for every secret name, matching the cluster module's secret_prefix input (the manifests sync
    <prefix><name>, so the two must move together - and the cluster module's reader roles scope their read grant to
    the same prefix). Lets multiple clusters share one account with distinct secrets -- each cluster then needs its
    own prefixed set and fresh out-of-band versions. Include the trailing separator (e.g. 'platform-x-'); null keeps
    the unprefixed names.
  EOT
  type        = string
  default     = null

  validation {
    condition     = var.secret_prefix == null || can(regex("^[A-Za-z0-9/_+=.@-]*$", var.secret_prefix))
    error_message = "secret_prefix must use Secrets Manager name characters only ([A-Za-z0-9/_+=.@-])."
  }
}

variable "sso" {
  description = <<-EOT
    Platform SSO election -- pass the cluster module's sso value verbatim (its attributes beyond enabled and the
    connector's id/type/secrets are dropped by type conversion). enabled mirrors the cluster's dex toggle and gates
    the connector containers; the connector's secrets names its out-of-band credential fields, creating one
    dex-<id>-<field> Secrets Manager container per field (id defaulting to type, matching the cluster module) --
    populate versions out of band (an OAuth client cannot be terraformed). On its own enabled creates nothing: no
    connector is declared by default.
  EOT
  type = object({
    enabled = optional(bool, false)
    connector = optional(object({
      id      = optional(string)
      type    = string
      secrets = optional(set(string), ["client-id", "client-secret"])
    }))
  })
  nullable = false
  default  = {}

  validation {
    condition = var.sso.connector == null || (
      can(regex("^[a-z0-9-]+$", coalesce(var.sso.connector.id, var.sso.connector.type))) &&
      coalesce(var.sso.connector.id, var.sso.connector.type) != "client"
    )
    error_message = "sso.connector.id (defaulting to type) must match ^[a-z0-9-]+$ and must not be \"client\" (reserved -- relying-party secrets are already named dex-client-<id>)."
  }

  validation {
    condition = var.sso.connector == null || alltrue([
      for field in var.sso.connector.secrets : can(regex("^[a-z0-9-]+$", field))
    ])
    error_message = "sso.connector.secrets entries must match ^[a-z0-9-]+$."
  }
}

variable "tags" {
  description = "Tags applied to every secret."
  type        = map(string)
  nullable    = false
  default     = {}
}
