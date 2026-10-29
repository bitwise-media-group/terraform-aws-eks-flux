# Copyright 2026 BitWise Media Group Ltd
# SPDX-License-Identifier: MIT

# The central platform artifact store, applied once in the platform account.
# Feed its outputs to the publishing repos as the AWS_CHART_PUBLISHER_ROLE /
# AWS_MANIFEST_PUBLISHER_ROLE (one per manifest-publishing repo) /
# AWS_PLATFORM_REGISTRY Actions variables, and each cluster the
# platform_registries entry for its own region.
#
# Reads are org-wide by construction, matched on aws:PrincipalOrgID in every
# region, so onboarding a new cluster account needs no change here; a cluster
# in a new region needs that region added to replica_regions.

provider "aws" {
  region = var.region
}

module "store" {
  source = "../../modules/artifact-store"

  name              = "platform"
  repository_prefix = "platform"

  organization_id = var.organization_id

  # One replica per region clusters run in outside this one. After adding a
  # region, run its replication_backfill_commands entry once.
  replica_regions = var.replica_regions

  github = {
    # One publisher per manifest-publishing repo, scoped to its own paths:
    # the platform repo keeps manifests/*, each application repo gets exactly
    # manifests/<app>. A repository_id stays null until the repo exists on
    # GitHub; set it and re-apply, or that publisher's subject never matches.
    manifest_publishers = var.manifest_publishers
  }

  # Pass an existing provider once a cloud-accounts aws environment owns it - 
  # IAM permits only one per issuer URL per account.
  oidc_provider_arn = var.oidc_provider_arn

  tags = var.tags
}
