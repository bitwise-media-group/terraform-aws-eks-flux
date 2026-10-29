# Copyright 2026 BitWise Media Group Ltd
# SPDX-License-Identifier: MIT

variable "region" {
  description = "The store's primary region, where publishers push. Clusters elsewhere read a replica in their own region, so this is not their latency (or availability) path."
  type        = string
  default     = "eu-west-2"
}

variable "replica_regions" {
  description = "Regions the store is replicated to, one per region clusters run in outside the primary."
  type        = set(string)
  default     = []
}

variable "organization_id" {
  description = "AWS Organizations id (o-xxxxxxxxxx) whose accounts may read the store and its replicas."
  type        = string
}

variable "manifest_publishers" {
  description = "Manifest-publishing repos, keyed by name: the paths each may push beneath the prefix and its numeric repository id (GET /repos/<org>/<repo>; null until the repo exists, and its OIDC subject cannot match without it)."
  type = map(object({
    repository_id = optional(number)
    paths         = list(string)
  }))
  default = {
    flux-manifests       = { paths = ["manifests/*"] }
    patchy-app-manifests = { paths = ["manifests/patchy"] }
  }
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
    app = "platform"
  }
}
