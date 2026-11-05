# Copyright 2026 BitWise Media Group Ltd
# SPDX-License-Identifier: MIT

output "application" {
  description = "The seed release, where it lives, and how the image is listed, pulled and applied."
  value = {
    release      = module.demo.release
    namespace    = module.demo.namespace
    tag_provider = module.demo.tag_provider
    oci_provider = module.demo.oci_provider
    path         = module.demo.path
  }
}

output "secret_reader_roles" {
  description = "The secret-sync reader role ARNs, keyed <namespace>/<service_account>."
  value       = module.demo.secret_reader_roles
}

output "node_group" {
  description = "The application's own node group: its actual name (with the generated suffix) and ARN."
  value = {
    name = module.node_group.name
    arn  = module.node_group.arn
  }
}
