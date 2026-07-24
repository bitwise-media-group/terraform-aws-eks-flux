# Copyright 2026 BitWise Media Group Ltd
# SPDX-License-Identifier: MIT

output "platform_registry" {
  description = "Pass to a cluster module only when it reads the store DIRECTLY (is_pull_through_cache = false); most clusters take a registry-cache module's output instead."
  value       = module.store.platform_registry
}

output "registry_id" {
  description = "The store account id — the upstream.registry_id every consuming account's registry-cache points at."
  value       = module.store.registry_id
}

output "publishers" {
  description = "Role ARNs for aws-actions/configure-aws-credentials in the publishing repos."
  value = {
    chart    = module.store.chart_publisher.arn
    manifest = module.store.manifest_publisher.arn
  }
}

output "signed_identity_subjects" {
  description = "Cosign keyless subjects to feed the cluster module's signed_identity."
  value       = module.store.signed_identity_subjects
}
