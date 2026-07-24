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

output "cluster_vars" {
  description = "The exact terraform -> flux contract this cluster publishes."
  value       = module.cluster.flux.cluster_vars
}

output "registry_reader_principals" {
  description = "Feed these to the artifact-store module's direct_pull_principals when this cluster reads a central store directly rather than through a cache."
  value       = module.cluster.registry_reader_principals
}
