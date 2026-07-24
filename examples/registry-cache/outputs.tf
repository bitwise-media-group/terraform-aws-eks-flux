# Copyright 2026 BitWise Media Group Ltd
# SPDX-License-Identifier: MIT

output "platform_registry" {
  description = "Feed straight into the cluster module's platform_registry — url plus is_pull_through_cache = true."
  value       = module.cache.platform_registry
}

output "consumer_policy_arn" {
  description = "Attach to pullers outside the cluster module (CI runners, bastions); the cluster composes its own equivalent grant."
  value       = module.cache.consumer_policy_arn
}
