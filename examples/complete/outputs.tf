# Copyright 2026 BitWise Media Group Ltd
# SPDX-License-Identifier: MIT

output "cluster" {
  description = "Cluster identity and the control-plane endpoint."
  value = {
    name     = module.cluster.name
    endpoint = module.cluster.endpoint
    version  = module.cluster.kubernetes_version
  }
}

output "platform_registry" {
  description = "The registry this cluster consumes from — the cache in this account, not the central store."
  value       = module.cluster.platform_registry
}

output "gateway" {
  description = "The Gateway's reserved addresses; point the delegated zone's records here once the Gateway is up."
  value       = module.cluster.gateway
}

output "dns" {
  description = "Delegated zone wiring, including the name servers the parent domain must delegate to."
  value       = module.cluster.dns
}

output "cluster_vars" {
  description = "The exact terraform -> flux contract this cluster publishes."
  value       = module.cluster.flux.cluster_vars
}

output "sso" {
  description = "SSO secrets this cluster owns — note directory_secret, whose value must be written out of band."
  value       = module.cluster.sso
}
