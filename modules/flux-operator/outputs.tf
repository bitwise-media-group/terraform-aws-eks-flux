# Copyright 2026 BitWise Media Group Ltd
# SPDX-License-Identifier: MIT

output "namespace" {
  description = "Namespace the flux-operator and Flux controllers run in."
  value       = var.namespace
}

output "registry_reader_roles" {
  description = "IAM role ARNs the flux controllers assume through Pod Identity - the identities that read the platform registry."
  value       = [for role in aws_iam_role.flux : role.arn]
}

output "applications" {
  description = <<-EOT
    The application seeds, keyed as var.applications: the bootstrap-only helm release name, the namespace the seed
    objects (<key>-manifests) live in, and the tag-listing provider the registry selected (ECRArtifactTag under the
    platform prefix, OCIArtifactTag elsewhere).
  EOT
  value = {
    for key, app in local.applications : key => {
      release      = helm_release.application[key].name
      namespace    = helm_release.application[key].namespace
      tag_provider = app.tag_provider
      oci_provider = app.oci_provider
    }
  }
}
