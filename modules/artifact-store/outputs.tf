# Copyright 2026 BitWise Media Group Ltd
# SPDX-License-Identifier: MIT

output "platform_registry" {
  description = "The primary region's registry, in the cluster module's platform_registry shape - for clusters in the primary region. Clusters elsewhere take theirs from platform_registries."
  value = {
    url = "${local.registry_host}/${var.repository_prefix}"
  }
}

output "platform_registries" {
  description = "Every region's registry (the primary and each replica), keyed by region, in the cluster module's platform_registry shape - a cluster takes the entry for its own region."
  value = {
    for region, host in local.registry_hosts : region => {
      url = "${host}/${var.repository_prefix}"
    }
  }
}

output "replication_backfill_commands" {
  description = "Per replica region, the AWS CLI command that copies everything already in the store to it. Replication only carries pushes made after a region is added, so run a region's command once after adding it (the job runs asynchronously; aws ecr list-replication-backfills shows its progress)."
  value = {
    for region in sort(tolist(var.replica_regions)) : region => join(" ", [
      "aws ecr start-replication-backfill",
      "--region ${local.region}",
      "--registry-id ${local.account_id}",
      "--destination region=${region},registryId=${local.account_id}",
    ])
  }
}

output "registry_host" {
  description = "The primary region's registry hostname - where publishers push (docker/helm/crane login via aws ecr get-login-password)."
  value       = local.registry_host
}

output "registry_id" {
  description = "Account id owning the registry in every region."
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
    push, and the Fulcio certificate-subject regexp of its release workflow on main (which signs edge builds and
    the releases promoted from them) - what the cluster module's applications[*].verify.subject pins for that repo
    alone.
  EOT
  value = {
    for repo, role in aws_iam_role.manifest_publisher : repo => {
      name    = role.name
      arn     = role.arn
      paths   = var.github.manifest_publishers[repo].paths
      subject = "^https://github\\.com/${var.github.org}/${replace(repo, ".", "\\.")}/\\.github/workflows/release\\.yaml@refs/heads/main$"
    }
  }
}

output "oidc_provider_arn" {
  description = "The GitHub Actions OIDC provider the publishers federate through - created here or passed in."
  value       = local.oidc_provider_arn
}

output "signed_identity_subjects" {
  description = "Fulcio certificate-subject regexps for the chart mirror and the manifests publishers (keyless mode) - feed these to the cluster module's signed_identity variable. manifests admits the release workflow on main of every repo github.manifest_signers matches, whichever channel (edge or stable) a cluster follows. Cloud-agnostic: the signer is GitHub, not the hosting cloud. Irrelevant when signing_kms_key_arn selects KMS signing. Each publisher's own subject rides in manifest_publishers."
  value = {
    containers = "^https://github\\.com/${var.github.org}/${var.github.containers}/\\.github/workflows/publish\\.yaml@refs/heads/main$"
    manifests  = "^https://github\\.com/${var.github.org}/${var.github.manifest_signers}/\\.github/workflows/release\\.yaml@refs/heads/main$"
  }
}

output "signing_kms_key_arn" {
  description = "The KMS signing key the publishers sign with (null in keyless mode) - feed it to the cluster module's signed_identity.kms_key_arn so verification matches."
  value       = var.signing_kms_key_arn
}
