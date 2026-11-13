# Copyright 2026 BitWise Media Group Ltd
# SPDX-License-Identifier: MIT

output "namespace" {
  description = "The flux namespace, once the flux-operator release has created it."
  # Through the release, not var.namespace: a consumer of this value (the
  # root's application_target, and through it every modules/application
  # release) then waits for the namespace to exist.
  value = helm_release.flux_operator.namespace
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
