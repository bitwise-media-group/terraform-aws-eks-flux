# Copyright 2026 BitWise Media Group Ltd
# SPDX-License-Identifier: MIT

variable "name" {
  description = "Cluster name."
  type        = string
  default     = "patchy-x"
}

variable "region" {
  description = "Region the cluster runs in."
  type        = string
  default     = "eu-west-2"
}

variable "network" {
  description = "Existing VPC wiring created upstream: the VPC, the private node subnets and the public subnets carrying the Gateway's NLB."
  type = object({
    vpc_id            = string
    node_subnet_ids   = set(string)
    public_subnet_ids = set(string)
  })
}

variable "store" {
  description = "The central artifact store this cluster's pull-through cache fills from (the artifact-store module's registry_id / repository_prefix outputs, plus its region)."
  type = object({
    registry_id       = string
    region            = string
    repository_prefix = optional(string, "platform")
  })
}

variable "signed_identity_subjects" {
  description = "Cosign keyless subjects from the artifact-store module's signed_identity_subjects output (use manifests_edge instead of manifests on a cluster tracking the edge channel)."
  type = object({
    manifests  = string
    containers = string
  })
}

variable "dns_zone_name" {
  description = "The delegated Route53 hosted zone, e.g. patchy.bitwisemedia.co.uk."
  type        = string
}

variable "acme_email" {
  description = "Let's Encrypt registration address for the cert-manager issuers."
  type        = string
}

variable "public_access" {
  description = "Public control-plane endpoint. Enabled here because terraform and helm bootstrap run from outside the VPC; set cidrs to constrain who may reach it, or enable = false when applying from inside the VPC."
  type = object({
    enable = optional(bool, false)
    cidrs  = optional(set(string), [])
  })
  default = { enable = true }
}

variable "rbac" {
  description = "IAM principals (typically IAM Identity Center permission-set roles) mapped onto the Kubernetes groups flux-manifests binds."
  type = object({
    enabled = optional(bool, false)
    groups = optional(object({
      viewers    = optional(object({ principal_arn = string, group = optional(string, "platform:viewers") }))
      developers = optional(object({ principal_arn = string, group = optional(string, "platform:developers") }))
      devops     = optional(object({ principal_arn = string, group = optional(string, "platform:devops") }))
      admins     = optional(object({ principal_arn = string, group = optional(string, "platform:admins") }))
    }), {})
  })
  default = {}
}

variable "cluster_admin_principals" {
  description = "IAM principals granted cluster-admin through an access entry (break-glass and CI identities)."
  type        = set(string)
  default     = []
}

variable "amp_endpoint" {
  description = "Optional Amazon Managed Prometheus remote-write endpoint for the otel-collector."
  type        = string
  default     = null
}

variable "secret_prefix" {
  description = "Prefix for every Secrets Manager name the stack syncs, so clusters sharing an account keep distinct secrets."
  type        = string
  default     = null
}

variable "stack_components" {
  description = "The flux-manifests optional-tier components this cluster elects."
  type        = set(string)
  default     = ["flux-web", "patchy"]
}

variable "sso" {
  description = "Platform SSO. When enabled the module creates the dex client pairs and the out-of-band container dex's upstream-connector credentials must be written to."
  type = object({
    enabled          = optional(bool, false)
    directory_secret = optional(bool, true)
    client_rotation  = optional(map(number), {})
  })
  default = {}
}

variable "patchy" {
  description = "Patchy platform knobs: the model provider its egress-broker proxies claude-runner traffic to, published as the CLAUDE_* cluster vars."
  type = object({
    claude = optional(object({
      provider = optional(object({
        name                  = optional(string, "anthropic")
        anthropic_auth        = optional(string, "token")
        bedrock_region        = optional(string)
        bedrock_region_prefix = optional(string)
        model_map             = optional(map(string), {})
      }), {})
    }), {})
  })
  default = {}
}

variable "tags" {
  description = "Tags applied to every resource."
  type        = map(string)
  default = {
    env = "x"
    app = "patchy"
  }
}
