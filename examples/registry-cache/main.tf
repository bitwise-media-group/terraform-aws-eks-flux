# Copyright 2026 BitWise Media Group Ltd
# SPDX-License-Identifier: MIT

# A pull-through cache of the platform artifact store, applied in a consuming
# team's own account and region. This is how a cluster is meant to reach the
# store: images come from a registry beside the nodes, and the store stays
# closed to direct reads.
#
# Nothing needs to change in the store to onboard this account — its registry
# policy admits the whole organization's pull-through caches by
# aws:PrincipalOrgID.
#
# Its platform_registry output goes straight into the cluster module, carrying
# is_pull_through_cache = true so the cluster's pullers get the create/import
# permissions a cache needs on first pull.

provider "aws" {
  region = var.region
}

module "cache" {
  source = "../../modules/registry-cache"

  name     = "platform"
  upstream = var.store

  tags = var.tags
}
