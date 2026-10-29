# Copyright 2026 BitWise Media Group Ltd
# SPDX-License-Identifier: MIT

output "platform_registries" {
  description = "Every region's registry, keyed by region - pass a cluster the entry for its own region as its platform_registry."
  value       = module.store.platform_registries
}

output "replication_backfill_commands" {
  description = "Per replica region, the command that copies what the store already holds to it - run once after adding a region."
  value       = module.store.replication_backfill_commands
}

output "registry_id" {
  description = "The store account id - the store.registry_id of the cluster examples."
  value       = module.store.registry_id
}

output "publishers" {
  description = "Role ARNs for aws-actions/configure-aws-credentials in the publishing repos: the chart publisher, and one manifest publisher per repo."
  value = {
    chart     = module.store.chart_publisher.arn
    manifests = { for repo, publisher in module.store.manifest_publishers : repo => publisher.arn }
  }
}

output "manifests_prefix" {
  description = "The OCI prefix every manifest-publishing repo pushes beneath (its AWS_PLATFORM_REGISTRY variable is the registry half of it)."
  value       = module.store.manifests_prefix
}

output "signed_identity_subjects" {
  description = "Cosign keyless subjects to feed the cluster module's signed_identity."
  value       = module.store.signed_identity_subjects
}
