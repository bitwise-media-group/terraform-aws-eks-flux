# Copyright 2026 BitWise Media Group Ltd
# SPDX-License-Identifier: MIT

variable "region" {
  description = "Region the cluster runs in."
  type        = string
  default     = "eu-west-2"
}

variable "cluster" {
  description = "The cluster root's application_target output, verbatim."
  type = object({
    name              = string
    namespace         = string
    platform_registry = string
    tree              = string
    issuer            = optional(string)
    keyed             = bool
    oidc_provider_arn = string
    oidc_issuer       = string
    secret_prefix     = string

    # The node facts module.node_group joins with.
    node_role_arn             = string
    node_subnet_ids           = set(string)
    cluster_security_group_id = string

    version               = string
    endpoint              = string
    certificate_authority = optional(string)
    service_cidr          = optional(string)
  })
}

variable "domain" {
  description = "The domain the application serves, handed to it as DEMO_DOMAIN."
  type        = string
}

variable "tags" {
  description = "Tags applied to every resource."
  type        = map(string)
  default     = {}
}
