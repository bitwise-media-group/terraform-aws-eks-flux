# Copyright 2026 BitWise Media Group Ltd
# SPDX-License-Identifier: MIT

# An ECR pull-through cache of the platform artifact store, deployed in a
# consuming team's own account and region.
#
# This is the default way a cluster reaches the store. The store itself admits
# only the ECR pull-through cache service, org-wide (aws:PrincipalOrgID), so a
# new account onboards by applying this module rather than by editing the
# store's principal list. Images are then pulled from a registry in the same
# account and region as the nodes: no cross-account data path at pull time, no
# cross-region egress, and the store stays closed to direct reads.
#
# The cache materialises each repository on its FIRST pull, which is why every
# puller (kubelet, the flux controllers, kyverno) needs ecr:CreateRepository and
# ecr:BatchImportUpstreamImage as well as read — see the consumer_policy output.
#
# Digests are preserved end to end, so cosign verification works through the
# cache exactly as it does against the store: signatures are ordinary tagged
# manifests (sha256-<digest>.sig) that pull through with everything else.

data "aws_caller_identity" "current" {}

data "aws_partition" "current" {}

data "aws_region" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id
  partition  = data.aws_partition.current.partition
  region     = data.aws_region.current.region

  registry_host = "${local.account_id}.dkr.ecr.${local.region}.amazonaws.com"

  upstream_registry_url = "${var.upstream.registry_id}.dkr.ecr.${var.upstream.region}.amazonaws.com"

  # Local prefix defaults to the upstream one, so image paths are identical on
  # both sides and a cluster can be moved between them by swapping one variable.
  repository_prefix = coalesce(var.repository_prefix, var.upstream.repository_prefix)

  repository_arn_pattern = "arn:${local.partition}:ecr:${local.region}:${local.account_id}:repository/${local.repository_prefix}/*"

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

# ECR assumes this role to fetch from the upstream registry on your behalf.
# Required for a cross-account ECR upstream (same-account cross-region works
# without one, but keeping it unconditional means the module behaves the same
# either way).
data "aws_iam_policy_document" "cache_assume_role" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["pullthroughcache.ecr.amazonaws.com"]
    }
  }
}

data "aws_iam_policy_document" "cache" {
  statement {
    sid    = "FetchUpstream"
    effect = "Allow"

    actions = [
      "ecr:GetAuthorizationToken",
      "ecr:GetDownloadUrlForLayer",
      "ecr:BatchGetImage",
      "ecr:BatchImportUpstreamImage",
      "ecr:GetImageCopyStatus",
      "ecr:InitiateLayerUpload",
      "ecr:UploadLayerPart",
      "ecr:CompleteLayerUpload",
      "ecr:PutImage",
    ]

    resources = ["*"]
  }
}

resource "aws_iam_role" "cache" {
  name               = "${var.name}-ecr-pull-through-cache"
  description        = "Assumed by ECR to fill the ${local.repository_prefix} cache from ${local.upstream_registry_url}"
  assume_role_policy = data.aws_iam_policy_document.cache_assume_role.json

  tags = var.tags
}

resource "aws_iam_role_policy" "cache" {
  name   = "fetch-upstream"
  role   = aws_iam_role.cache.id
  policy = data.aws_iam_policy_document.cache.json
}

# Settings for the repositories ECR creates as the cache fills. Tag mutability
# MUST stay MUTABLE: channel tags (staging, stable, edge) move upstream, and an
# immutable cache repository could never take the updated tag.
resource "aws_ecr_repository_creation_template" "cache" {
  prefix      = local.repository_prefix
  description = "Pull-through cache of ${local.upstream_registry_url}/${var.upstream.repository_prefix}"

  applied_for = ["PULL_THROUGH_CACHE"]

  custom_role_arn      = aws_iam_role.cache.arn
  image_tag_mutability = "MUTABLE"

  encryption_configuration {
    encryption_type = var.kms_key_arn != null ? "KMS" : "AES256"
    kms_key         = var.kms_key_arn
  }

  lifecycle_policy = local.lifecycle_policy

  resource_tags = var.tags
}

resource "aws_ecr_pull_through_cache_rule" "platform" {
  ecr_repository_prefix      = local.repository_prefix
  upstream_registry_url      = local.upstream_registry_url
  upstream_repository_prefix = var.upstream.repository_prefix
  custom_role_arn            = aws_iam_role.cache.arn
}

# Attachable by the consuming cluster's node and controller roles. The cluster
# module composes an equivalent grant inline from platform_registry, so this is
# for anything outside it that also pulls (CI runners, bastions).
locals {
  consumer_actions = [
    "ecr:BatchGetImage",
    "ecr:GetDownloadUrlForLayer",
    "ecr:BatchCheckLayerAvailability",
    "ecr:DescribeImages",
    "ecr:ListImages",
    # The first pull of any artifact is what creates its repository here, so
    # these are not optional extras — without them a fresh cluster fails on its
    # very first image.
    "ecr:CreateRepository",
    "ecr:BatchImportUpstreamImage",
    "ecr:GetImageCopyStatus",
  ]
}

data "aws_iam_policy_document" "consumer" {
  statement {
    sid       = "Authorize"
    effect    = "Allow"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }

  statement {
    sid       = "PullAndFill"
    effect    = "Allow"
    actions   = local.consumer_actions
    resources = [local.repository_arn_pattern]
  }
}

resource "aws_iam_policy" "consumer" {
  name        = "${var.name}-ecr-cache-consumer"
  description = "Pull from (and fill) the ${local.repository_prefix} pull-through cache"
  policy      = data.aws_iam_policy_document.consumer.json

  tags = var.tags
}
