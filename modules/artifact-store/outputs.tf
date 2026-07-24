# Copyright 2026 BitWise Media Group Ltd
# SPDX-License-Identifier: MIT

output "platform_registry" {
  description = <<-EOT
    Feed straight into the cluster module's platform_registry. is_pull_through_cache is false because this IS the store
    — a cluster wired here reads it directly, which additionally requires its registry_reader_principals to appear in
    this module's direct_pull_principals. Most clusters should point at a registry-cache module's output instead.
  EOT
  value = {
    url                   = "${local.registry_host}/${var.repository_prefix}"
    is_pull_through_cache = false
  }
}

output "registry_host" {
  description = "Registry hostname for docker/helm/crane login (AWS/ecr get-login-password)."
  value       = local.registry_host
}

output "registry_id" {
  description = "Account id owning the registry — the upstream_registry_id a registry-cache module points at."
  value       = local.account_id
}

output "repository_prefix" {
  description = "The repository name prefix everything lands beneath, and the prefix the creation template is keyed on."
  value       = var.repository_prefix
}

output "chart_repository_prefix" {
  description = "OCI prefix mirrored charts are published under (charts/<name> appended per chart)."
  value       = "oci://${local.registry_host}/${var.repository_prefix}/charts"
}

output "image_repository_prefix" {
  description = "Registry prefix mirrored images are published under (images/<original-path> appended per image)."
  value       = "${local.registry_host}/${var.repository_prefix}/images"
}

output "manifest_artifact_url" {
  description = "OCI url of the flux-manifests artifact the clusters sync."
  value       = "oci://${local.registry_host}/${var.repository_prefix}/flux-manifests"
}

output "chart_publisher" {
  description = "Chart publisher role (the role-to-assume input of aws-actions/configure-aws-credentials in flux-containers, set as the AWS_CHART_PUBLISHER_ROLE org variable)."
  value = {
    name = aws_iam_role.publisher["chart"].name
    arn  = aws_iam_role.publisher["chart"].arn
  }
}

output "manifest_publisher" {
  description = "Manifest publisher role (the role-to-assume input of aws-actions/configure-aws-credentials in flux-manifests, set as the AWS_MANIFEST_PUBLISHER_ROLE org variable)."
  value = {
    name = aws_iam_role.publisher["manifest"].name
    arn  = aws_iam_role.publisher["manifest"].arn
  }
}

output "oidc_provider_arn" {
  description = "The GitHub Actions OIDC provider the publishers federate through — created here or passed in."
  value       = local.oidc_provider_arn
}

output "signed_identity_subjects" {
  description = "Fulcio certificate-subject regexps for the publishing workflows — feed these to the cluster module's signed_identity variable. Cloud-agnostic: the signer is GitHub, so these are identical to the GKE store's."
  value = {
    containers = "^https://github\\.com/${var.github.org}/${var.github.containers}/\\.github/workflows/publish\\.yaml@refs/heads/main$"
    manifests  = "^https://github\\.com/${var.github.org}/${var.github.manifests}/\\.github/workflows/publish\\.yaml@refs/tags/v.+$"
    # edge channel: dev/sandbox clusters tracking trunk pass this as
    # signed_identity.manifests_subject instead of the release identity above
    manifests_edge = "^https://github\\.com/${var.github.org}/${var.github.manifests}/\\.github/workflows/publish-edge\\.yaml@refs/heads/main$"
  }
}
