# Copyright 2026 BitWise Media Group Ltd
# SPDX-License-Identifier: MIT

variable "region" {
  description = "Region the cache lives in — the cluster's own region, so pulls stay local."
  type        = string
  default     = "eu-west-2"
}

variable "store" {
  description = "The artifact store to cache: its account id and region, plus the repository prefix everything lives beneath."
  type = object({
    registry_id       = string
    region            = string
    repository_prefix = optional(string, "platform")
  })
}

variable "tags" {
  description = "Tags applied to the role, the consumer policy and every cached repository."
  type        = map(string)
  default = {
    app = "patchy"
  }
}
