# Copyright 2026 BitWise Media Group Ltd
# SPDX-License-Identifier: MIT

# The platform artifact store: every artifact the clusters consume, under path
# namespaces beneath one ECR prefix —
#
#   <prefix>/charts/<name>            helm charts mirrored by flux-containers
#   <prefix>/images/<original-path>   digest-pinned images mirrored by flux-containers
#   <prefix>/flux-manifests           the signed OCI manifests artifact synced by FluxInstance
#
# ECR has no arbitrary-path model: every one of those is a real repository that
# must exist before a push. A REPOSITORY CREATION TEMPLATE with CREATE_ON_PUSH
# is what restores Artifact Registry's ergonomics — publishers simply push, and
# ECR creates each repository with this template's lifecycle policy, tag
# mutability, encryption and tags. Without a matching template ECR refuses to
# create on push at all, so the template is load-bearing, not a nicety.
#
# There is no signing key anywhere in this module: artifacts are cosign-signed
# KEYLESSLY by the publishing GitHub Actions workflows (OIDC -> Fulcio/Rekor),
# and consumers verify against the workflows' certificate identities. The only
# infrastructure signing needs is the GitHub OIDC trust below, which controls
# who may PUSH.

data "aws_caller_identity" "current" {}

data "aws_partition" "current" {}

data "aws_region" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id
  partition  = data.aws_partition.current.partition
  region     = data.aws_region.current.region

  registry_host = "${local.account_id}.dkr.ecr.${local.region}.amazonaws.com"

  # Every repository beneath the platform prefix.
  repository_arn_pattern = "arn:${local.partition}:ecr:${local.region}:${local.account_id}:repository/${var.repository_prefix}/*"

  # Untagged manifests are what failed and superseded pushes leave behind.
  lifecycle_policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Expire untagged manifests after ${var.untagged_expiry_days} days"
        selection = {
          tagStatus   = "untagged"
          countType   = "sinceImagePushed"
          countUnit   = "days"
          countNumber = var.untagged_expiry_days
        }
        action = { type = "expire" }
      }
    ]
  })
}

# ECR assumes this role when it creates a repository on your behalf. It is
# REQUIRED whenever the template sets resource tags or KMS encryption (both
# here), and creation fails outright without it. All three ECR creation
# principals are trusted so the same template can later serve pull-through
# cache and replication without a trust-policy change.
data "aws_iam_policy_document" "creation_assume_role" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type = "Service"
      identifiers = [
        "ecr.amazonaws.com",
        "pullthroughcache.ecr.amazonaws.com",
        "replication.ecr.amazonaws.com",
      ]
    }
  }
}

data "aws_iam_policy_document" "creation" {
  statement {
    sid    = "CreateAndConfigure"
    effect = "Allow"

    actions = [
      "ecr:CreateRepository",
      "ecr:PutLifecyclePolicy",
      "ecr:SetRepositoryPolicy",
      "ecr:TagResource",
      "ecr:ReplicateImage",
    ]

    resources = [local.repository_arn_pattern]
  }
}

resource "aws_iam_role" "creation" {
  name               = "${var.name}-ecr-repository-creation"
  description        = "Assumed by ECR to create ${var.repository_prefix}/* repositories from the creation template"
  assume_role_policy = data.aws_iam_policy_document.creation_assume_role.json

  tags = var.tags
}

resource "aws_iam_role_policy" "creation" {
  name   = "create-repositories"
  role   = aws_iam_role.creation.id
  policy = data.aws_iam_policy_document.creation.json
}

resource "aws_ecr_repository_creation_template" "platform" {
  prefix      = var.repository_prefix
  description = "Platform artifact store: mirrored charts + images and the signed flux-manifests artifact"

  # Publishers push straight to <prefix>/<path> and the repository appears.
  applied_for = ["CREATE_ON_PUSH"]

  custom_role_arn = aws_iam_role.creation.arn

  # Channel tags (staging/stable) on the manifests artifact must move between
  # releases, and tag immutability is per repository, so it stays off. Version
  # tags are protected from reuse by the publish workflows refusing to
  # overwrite an existing digest, not by the registry.
  image_tag_mutability = "MUTABLE"

  encryption_configuration {
    encryption_type = var.kms_key_arn != null ? "KMS" : "AES256"
    kms_key         = var.kms_key_arn
  }

  lifecycle_policy = local.lifecycle_policy

  resource_tags = var.tags
}

# Enhanced scanning across the platform prefix. Registry-wide by construction
# (ECR scanning configuration is a registry singleton), filtered to the prefix.
resource "aws_ecr_registry_scanning_configuration" "platform" {
  count = var.enhanced_scanning ? 1 : 0

  scan_type = "ENHANCED"

  rule {
    scan_frequency = "CONTINUOUS_SCAN"

    repository_filter {
      filter      = "${var.repository_prefix}/*"
      filter_type = "WILDCARD"
    }
  }
}
