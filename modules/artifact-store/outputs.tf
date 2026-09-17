# Copyright 2026 BitWise Media Group Ltd
# SPDX-License-Identifier: MIT

output "platform_registry" {
  description = <<-EOT
    Feed straight into the cluster module's platform_registry. is_pull_through_cache is false because this IS the
    store - a cluster wired here reads it directly, which additionally requires its registry_reader_principals to
    appear in this module's direct_pull_principals. Most clusters should point at a registry-cache module's output
    instead.
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
  description = "Account id owning the registry - the upstream_registry_id a registry-cache module points at."
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

output "manifests_prefix" {
  description = "OCI prefix every manifest image is published under: manifests/platform, manifests/<component> and manifests/<application> beneath it. The AWS_PLATFORM_REGISTRY-derived base the publish workflows push to."
  value       = "oci://${local.registry_host}/${var.repository_prefix}/manifests"
}

output "platform_manifests_url" {
  description = "OCI url of the platform entrypoint image the clusters sync (the cluster module's flux.sync.url default)."
  value       = "oci://${local.registry_host}/${var.repository_prefix}/manifests/platform"
}

output "chart_publisher" {
  description = "Chart publisher role (the role-to-assume input of aws-actions/configure-aws-credentials in flux-containers, set as the AWS_CHART_PUBLISHER_ROLE org variable)."
  value = {
    name = aws_iam_role.chart_publisher.name
    arn  = aws_iam_role.chart_publisher.arn
  }
}

output "manifest_publishers" {
  description = <<-EOT
    One manifest publisher role per github.manifest_publishers key: the role-to-assume input of
    aws-actions/configure-aws-credentials in that repo (its AWS_MANIFEST_PUBLISHER_ROLE variable), the paths it may
    push, and the Fulcio certificate-subject regexps of its publish workflows (release tags and the edge channel) -
    an application repo's release subject is what the cluster module's applications[*].verify.subject pins.
  EOT
  value = {
    for repo, role in aws_iam_role.manifest_publisher : repo => {
      name  = role.name
      arn   = role.arn
      paths = var.github.manifest_publishers[repo].paths
      subjects = {
        release = "^https://github\\.com/${var.github.org}/${repo}/\\.github/workflows/publish\\.yaml@refs/tags/v.+$"
        edge    = "^https://github\\.com/${var.github.org}/${repo}/\\.github/workflows/publish-edge\\.yaml@refs/heads/main$"
      }
    }
  }
}

output "oidc_provider_arn" {
  description = "The GitHub Actions OIDC provider the publishers federate through - created here or passed in."
  value       = local.oidc_provider_arn
}

output "signed_identity_subjects" {
  description = "Fulcio certificate-subject regexps for the chart mirror and the platform manifests publisher (keyless mode) - feed these to the cluster module's signed_identity variable. Cloud-agnostic: the signer is GitHub, not the hosting cloud. Irrelevant when signing_kms_key_arn selects KMS signing. Application publishers' subjects ride in manifest_publishers."
  value = {
    containers = "^https://github\\.com/${var.github.org}/${var.github.containers}/\\.github/workflows/publish\\.yaml@refs/heads/main$"
    manifests  = "^https://github\\.com/${var.github.org}/${var.github.platform}/\\.github/workflows/publish\\.yaml@refs/tags/v.+$"
    # edge channel: dev/sandbox clusters tracking trunk pass this as
    # signed_identity.manifests_subject instead of the release identity above
    manifests_edge = "^https://github\\.com/${var.github.org}/${var.github.platform}/\\.github/workflows/publish-edge\\.yaml@refs/heads/main$"
  }
}

output "signing_kms_key_arn" {
  description = "The KMS signing key the publishers sign with (null in keyless mode) - feed it to the cluster module's signed_identity.kms_key_arn so verification matches."
  value       = var.signing_kms_key_arn
}
