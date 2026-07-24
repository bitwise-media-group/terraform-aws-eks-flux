# Copyright 2026 BitWise Media Group Ltd
# SPDX-License-Identifier: MIT

output "platform_registry" {
  description = <<-EOT
    Feed straight into the cluster module's platform_registry. is_pull_through_cache is true, which is what adds
    ecr:CreateRepository and ecr:BatchImportUpstreamImage to every puller's grant — a cache materialises each
    repository on its first pull, so a cluster wired here without those permissions fails on its first image.
  EOT
  value = {
    url                   = "${local.registry_host}/${local.repository_prefix}"
    is_pull_through_cache = true
  }
}

output "registry_host" {
  description = "Registry hostname for docker/helm/crane login in this account."
  value       = local.registry_host
}

output "repository_prefix" {
  description = "Local repository prefix the cached artifacts appear under."
  value       = local.repository_prefix
}

output "upstream_registry_url" {
  description = "The store registry this cache fills from."
  value       = local.upstream_registry_url
}

output "consumer_policy_arn" {
  description = "IAM policy granting pull (and first-pull cache fill) on the cached prefix. The cluster module composes its own equivalent grant, so attach this only to pullers outside it — CI runners, bastions."
  value       = aws_iam_policy.consumer.arn
}

output "cache_role_arn" {
  description = "The role ECR assumes to fetch from the upstream store."
  value       = aws_iam_role.cache.arn
}
