# Copyright 2026 BitWise Media Group Ltd
# SPDX-License-Identifier: MIT

variable "name" {
  description = "Cluster name."
  type        = string
  default     = "patchy-min"
}

variable "region" {
  description = "Region the cluster runs in."
  type        = string
  default     = "eu-west-2"
}

variable "network" {
  description = "Existing VPC and the private subnets nodes launch into."
  type = object({
    vpc_id          = string
    node_subnet_ids = set(string)
  })
}

variable "platform_registry" {
  description = "Where charts, images and the manifests artifact come from — pass a registry-cache or artifact-store module's platform_registry output rather than composing it by hand."
  type = object({
    url                   = string
    is_pull_through_cache = bool
  })
}

variable "signed_identity_subjects" {
  description = "Cosign keyless subjects from the artifact-store module's signed_identity_subjects output."
  type = object({
    manifests  = string
    containers = string
  })
}

variable "tags" {
  description = "Tags applied to every resource."
  type        = map(string)
  default     = {}
}
