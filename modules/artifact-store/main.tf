# Copyright 2026 BitWise Media Group Ltd
# SPDX-License-Identifier: MIT

# The platform artifact store: every artifact the clusters consume, under path
# namespaces beneath one ECR prefix - 
#
#   <prefix>/charts/<name>            helm charts mirrored by flux-containers
#   <prefix>/images/<original-path>   digest-pinned images mirrored by flux-containers
#   <prefix>/manifests/platform       the platform entrypoint image the FluxInstance syncs
#   <prefix>/manifests/<component>    one signed image per platform component
#   <prefix>/manifests/<application>  one signed image per application (its own repo publishes it)
#
# ECR has no arbitrary-path model: every one of those is a real repository that
# must exist before a push. A REPOSITORY CREATION TEMPLATE with CREATE_ON_PUSH
# is what restores Artifact Registry's ergonomics - publishers simply push, and
# ECR creates each repository with the matching template's lifecycle policy,
# tag mutability, encryption and tags. Without a matching template ECR refuses
# to create on push at all, so the templates are essential, not a nicety.
#
# Every tag is IMMUTABLE except the channel tags on the manifest images: ECR
# applies the template with the longest matching prefix, so <prefix>/manifests
# gets its own template that exempts exactly those tags.
#
# REPLICAS: publishers push to this (the primary) region only, and ECR
# replication copies every push - channel-tag moves included - to each of
# replica_regions in this same account. Clusters read the replica in their own
# region, so none of them depends on the primary region being up. Repository
# settings are not replicated: a replica repository gets its tag mutability,
# encryption and lifecycle only from a REPLICATION creation template in its own
# region, which is why every template exists once per region. Deletes and
# lifecycle expiry do not replicate either; each region ages out its own
# untagged images under the same rules.
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

  # The primary first, then the replicas. distinct() lets a primary listed as a
  # replica reach the replication precondition's clearer error.
  regions = distinct(concat([local.region], sort(tolist(var.replica_regions))))

  registry_hosts = { for region in local.regions : region => "${local.account_id}.dkr.ecr.${region}.amazonaws.com" }

  # Every repository beneath the platform prefix, per region.
  repository_arn_patterns = {
    for region in local.regions :
    region => "arn:${local.partition}:ecr:${region}:${local.account_id}:repository/${var.repository_prefix}/*"
  }

  repository_arn_pattern = local.repository_arn_patterns[local.region]

  # Release tags move staging, merges to main move edge, the promotion
  # environment moves stable.
  manifest_channel_tags = ["edge", "stable", "staging"]

  # The settings every region's templates share; only the encryption key and
  # the trigger (CREATE_ON_PUSH in the primary, REPLICATION in a replica)
  # differ between regions.
  templates = {
    platform = {
      prefix               = var.repository_prefix
      description          = "Platform artifact store: mirrored charts + images, every tag immutable"
      image_tag_mutability = "IMMUTABLE"
      exclusion_tags       = []
    }

    # Wins over the platform template for <prefix>/manifests/* (longest prefix).
    manifests = {
      prefix               = "${var.repository_prefix}/manifests"
      description          = "Platform artifact store manifest images: immutable version tags, movable channel tags"
      image_tag_mutability = "IMMUTABLE_WITH_EXCLUSION"
      exclusion_tags       = local.manifest_channel_tags
    }
  }

  replica_templates = {
    for pair in setproduct(sort(tolist(var.replica_regions)), keys(local.templates)) :
    "${pair[0]}/${pair[1]}" => merge(local.templates[pair[1]], { region = pair[0] })
  }

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
# here), and creation fails outright without it. It serves both the primary's
# CREATE_ON_PUSH templates and the replicas' REPLICATION templates (IAM is
# global, so one role covers every region).
data "aws_iam_policy_document" "creation_assume_role" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type = "Service"
      identifiers = [
        "ecr.amazonaws.com",
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

    resources = values(local.repository_arn_patterns)
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

# Publishers push straight to <prefix>/<path> and the repository appears.
resource "aws_ecr_repository_creation_template" "primary" {
  for_each = local.templates

  prefix      = each.value.prefix
  description = each.value.description

  applied_for = ["CREATE_ON_PUSH"]

  custom_role_arn = aws_iam_role.creation.arn

  image_tag_mutability = each.value.image_tag_mutability

  dynamic "image_tag_mutability_exclusion_filter" {
    for_each = each.value.exclusion_tags

    content {
      filter      = image_tag_mutability_exclusion_filter.value
      filter_type = "WILDCARD"
    }
  }

  encryption_configuration {
    encryption_type = length(var.kms_key_arns) > 0 ? "KMS" : "AES256"
    kms_key         = lookup(var.kms_key_arns, local.region, null)
  }

  lifecycle_policy = local.lifecycle_policy

  resource_tags = var.tags

  lifecycle {
    precondition {
      condition     = length(var.kms_key_arns) == 0 || alltrue([for region in local.regions : contains(keys(var.kms_key_arns), region)])
      error_message = "kms_key_arns must hold a key for the primary region and every replica region (KMS keys are regional), or be empty."
    }
  }
}

moved {
  from = aws_ecr_repository_creation_template.platform
  to   = aws_ecr_repository_creation_template.primary["platform"]
}

moved {
  from = aws_ecr_repository_creation_template.manifests
  to   = aws_ecr_repository_creation_template.primary["manifests"]
}

# The same settings in every replica region, applied as replication creates
# each repository there.
resource "aws_ecr_repository_creation_template" "replica" {
  for_each = local.replica_templates

  region = each.value.region

  prefix      = each.value.prefix
  description = each.value.description

  applied_for = ["REPLICATION"]

  custom_role_arn = aws_iam_role.creation.arn

  image_tag_mutability = each.value.image_tag_mutability

  dynamic "image_tag_mutability_exclusion_filter" {
    for_each = each.value.exclusion_tags

    content {
      filter      = image_tag_mutability_exclusion_filter.value
      filter_type = "WILDCARD"
    }
  }

  encryption_configuration {
    encryption_type = length(var.kms_key_arns) > 0 ? "KMS" : "AES256"
    kms_key         = lookup(var.kms_key_arns, each.value.region, null)
  }

  lifecycle_policy = local.lifecycle_policy

  resource_tags = var.tags
}

# Registry-wide by construction (ECR has one replication configuration per
# registry), so this module owns it, as it does the scanning configuration.
resource "aws_ecr_replication_configuration" "platform" {
  count = length(var.replica_regions) > 0 ? 1 : 0

  replication_configuration {
    rule {
      dynamic "destination" {
        for_each = sort(tolist(var.replica_regions))

        content {
          region      = destination.value
          registry_id = local.account_id
        }
      }

      # A plain string prefix: the trailing slash keeps a sibling such as
      # <prefix>-tools out of the replicas.
      repository_filter {
        filter      = "${var.repository_prefix}/"
        filter_type = "PREFIX_MATCH"
      }
    }
  }

  lifecycle {
    precondition {
      condition     = !contains(var.replica_regions, local.region)
      error_message = "replica_regions must not include the primary region (${local.region}) the store is applied in."
    }
  }

  depends_on = [aws_ecr_repository_creation_template.replica]
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

resource "aws_ecr_registry_scanning_configuration" "replica" {
  for_each = var.enhanced_scanning ? var.replica_regions : toset([])

  region = each.key

  scan_type = "ENHANCED"

  rule {
    scan_frequency = "CONTINUOUS_SCAN"

    repository_filter {
      filter      = "${var.repository_prefix}/*"
      filter_type = "WILDCARD"
    }
  }
}
