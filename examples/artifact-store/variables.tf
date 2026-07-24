# Copyright 2026 BitWise Media Group Ltd
# SPDX-License-Identifier: MIT

variable "region" {
  description = "Region the store lives in. Consuming clusters cache from it into their own region, so this is not their latency path."
  type        = string
  default     = "eu-west-2"
}

variable "organization_id" {
  description = "AWS Organizations id (o-xxxxxxxxxx) whose accounts may pull through an ECR pull-through cache."
  type        = string
}

variable "github_manifests_id" {
  description = "Numeric repository id of flux-manifests (GET /repos/<org>/flux-manifests). Null until the repo exists; the manifest publisher's OIDC subject cannot match without it."
  type        = number
  default     = null
}

variable "oidc_provider_arn" {
  description = "Existing GitHub Actions OIDC provider ARN; null creates one here."
  type        = string
  default     = null
}

variable "tags" {
  description = "Tags applied to the roles and to every repository the creation template makes."
  type        = map(string)
  default = {
    app = "patchy"
  }
}
