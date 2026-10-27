# Copyright 2026 BitWise Media Group Ltd
# SPDX-License-Identifier: MIT

output "release" {
  description = "The bootstrap-only seed release (application-<name>) in the flux namespace."
  value       = helm_release.seed.name
}

output "namespace" {
  description = "The flux namespace the seed objects (<name>-manifests) and the <name>-vars ConfigMap live in."
  value       = helm_release.seed.namespace
}

output "tag_provider" {
  description = "The tag-listing provider the registry selected: ECRArtifactTag under the platform prefix, OCIArtifactTag elsewhere."
  value       = local.tag_provider
}

output "oci_provider" {
  description = "The OCIRepository provider the registry selected: aws under the platform prefix, generic elsewhere."
  value       = local.oci_provider
}

output "path" {
  description = "The resolved Kustomization path inside the image."
  value       = local.path
}

output "workload_roles" {
  description = "The Pod Identity-bound IAM role ARNs, keyed as workload_grants - for roots that grant these identities further access."
  value       = { for key, role in aws_iam_role.workload : key => role.arn }
}

output "secret_reader_roles" {
  description = "The podless secret-sync reader role ARNs, keyed <namespace>/<service_account>."
  value       = { for key, role in aws_iam_role.secret_reader : "${local.secret_readers[key].namespace}/${local.secret_readers[key].service_account}" => role.arn }
}

output "node_groups" {
  description = "Each node_groups entry's actual node group name and ARN (the names carry generated suffixes)."
  value = {
    for key, group in module.node_group : key => {
      name = group.name
      arn  = group.arn
    }
  }
}
