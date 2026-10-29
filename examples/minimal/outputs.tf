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
