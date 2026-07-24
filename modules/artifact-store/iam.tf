# Copyright 2026 BitWise Media Group Ltd
# SPDX-License-Identifier: MIT

# Who may push, and who may pull.
#
# PUSH: the two GitHub Actions publishers, through the account's GitHub OIDC
# provider. These are the only long-lived identities the platform has — every
# in-cluster workload uses EKS Pod Identity instead.
#
# PULL: nothing by default except the ECR pull-through cache service, and that
# ORG-WIDE rather than per-account, so a new cluster account onboards without
# touching this module. Clusters read the store through a cache in their own
# account (modules/registry-cache); direct_pull_principals is the escape hatch
# for the ones the platform team lets read it straight.

locals {
  # GitHub mints immutable subjects for repos created (or renamed/transferred)
  # after 2026-07-15: repo:<org>@<org id>/<repo>@<repo id>:<context>. Both
  # publishing repos are post-cutoff, so the subject conditions must pin the
  # numeric ids — the name-only form never matches and AssumeRoleWithWebIdentity
  # fails.
  containers_subject_repo = "${var.github.org}@${var.github.org_id}/${var.github.containers}@${var.github.containers_id}"

  # flux-manifests may not exist on GitHub yet when the store is first applied.
  # Until manifests_id is set, its subject falls back to the name-only form —
  # which a post-cutoff repo will never present — so set the id and re-apply as
  # soon as the repo is created.
  manifests_subject_repo = (
    var.github.manifests_id != null
    ? "${var.github.org}@${var.github.org_id}/${var.github.manifests}@${var.github.manifests_id}"
    : "${var.github.org}/${var.github.manifests}"
  )

  oidc_provider_arn = coalesce(
    var.oidc_provider_arn,
    one(aws_iam_openid_connect_provider.github[*].arn),
  )

  # flux-containers publishes (and keyless-signs) charts + images from its
  # default branch only — PR validation never gets push credentials.
  chart_publisher_subjects = ["repo:${local.containers_subject_repo}:ref:refs/heads/main"]

  # Release tags publish versioned artifacts and move `staging`; merges to main
  # publish the `edge` channel; the protected promotion environment moves
  # `stable`.
  manifest_publisher_subjects = [
    "repo:${local.manifests_subject_repo}:ref:refs/heads/main",
    "repo:${local.manifests_subject_repo}:ref:refs/tags/v*",
    "repo:${local.manifests_subject_repo}:environment:${var.promotion_environment}",
  ]
}

# Created here only when the account has no GitHub OIDC provider yet; pass
# oidc_provider_arn to reuse an existing one (the usual case once a
# cloud-accounts aws environment owns it).
resource "aws_iam_openid_connect_provider" "github" {
  count = var.oidc_provider_arn == null ? 1 : 0

  url             = "https://token.actions.githubusercontent.com"
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = var.github_oidc_thumbprints

  tags = var.tags
}

data "aws_iam_policy_document" "publisher_assume_role" {
  for_each = {
    chart    = local.chart_publisher_subjects
    manifest = local.manifest_publisher_subjects
  }

  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [local.oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    # StringLike, not StringEquals: the release-tag subject carries a glob
    # (refs/tags/v*). Every other subject in the list is literal, so the
    # weaker operator costs nothing.
    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values   = each.value
    }
  }
}

data "aws_iam_policy_document" "publisher" {
  statement {
    sid       = "Authorize"
    effect    = "Allow"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }

  # CreateRepository is what makes the creation template fire: a publisher
  # pushing <prefix>/charts/kyverno for the first time creates that repository
  # with the template's settings. Scoped to the prefix, so a publisher cannot
  # create repositories anywhere else in the registry.
  statement {
    sid    = "PushAndCreate"
    effect = "Allow"

    actions = [
      "ecr:CreateRepository",
      "ecr:DescribeRepositories",
      "ecr:BatchCheckLayerAvailability",
      "ecr:InitiateLayerUpload",
      "ecr:UploadLayerPart",
      "ecr:CompleteLayerUpload",
      "ecr:PutImage",
      "ecr:BatchGetImage",
      "ecr:GetDownloadUrlForLayer",
      "ecr:DescribeImages",
      "ecr:ListImages",
      "ecr:TagResource",
    ]

    resources = [local.repository_arn_pattern]
  }
}

# Both publishers hold push on the whole platform prefix — per-namespace push
# separation has no ECR equivalent. The effective control is consumer-side
# verification: every OCIRepository and the Kyverno policy pin the exact signer
# workflow identity, so a compromised chart publisher pushing a fake manifests
# artifact still fails verification on the cluster.
resource "aws_iam_role" "publisher" {
  for_each = {
    chart    = var.github.containers
    manifest = var.github.manifests
  }

  name               = "${var.name}-${each.key}-publisher"
  description        = "Pushes to ${var.repository_prefix}/* from ${var.github.org}/${each.value} via GitHub OIDC"
  assume_role_policy = data.aws_iam_policy_document.publisher_assume_role[each.key].json

  tags = var.tags
}

resource "aws_iam_role_policy" "publisher" {
  for_each = aws_iam_role.publisher

  name   = "publish"
  role   = each.value.id
  policy = data.aws_iam_policy_document.publisher.json
}

# ---------------------------------------------------------------------------
# Read access. A registry policy rather than per-repository policies, so it
# covers every repository the creation template will ever make — including the
# ones that do not exist yet.
#
# NOTE: ECR allows exactly one registry policy per account per region. This
# module owns it; an account using registry policies for anything else must
# merge those statements in via additional_registry_statements.
# ---------------------------------------------------------------------------

# Built as plain structures rather than through aws_iam_policy_document: this
# policy is the store's central access control, callers can merge statements
# into it, and writing it directly keeps it readable and assertable instead of
# round-tripping a rendered document back through jsondecode.
locals {
  # The cross-account ECR -> ECR pull-through cache grant. AWS documents this
  # as one <account>:root principal per downstream account; the actual caller
  # is that account's PTC role (assumed by pullthroughcache.ecr.amazonaws.com),
  # so aws:PrincipalOrgID matches it and covers every current AND future member
  # account — no list to maintain as clusters come online.
  pull_through_cache_statement = {
    Sid    = "OrganizationPullThroughCache"
    Effect = "Allow"

    Action = [
      "ecr:BatchGetImage",
      "ecr:GetDownloadUrlForLayer",
      "ecr:BatchImportUpstreamImage",
      "ecr:GetImageCopyStatus",
    ]

    Resource  = local.repository_arn_pattern
    Principal = { AWS = "*" }

    Condition = merge(
      { StringEquals = { "aws:PrincipalOrgID" = var.organization_id } },
      # Optional narrowing to specific organizational units.
      length(var.organization_paths) > 0 ? {
        "ForAnyValue:StringLike" = { "aws:PrincipalOrgPaths" = var.organization_paths }
      } : {},
    )
  }

  # Named principals allowed to read the store DIRECTLY rather than through a
  # cache — feed a cluster's registry_reader_principals output through here.
  direct_pull_statements = length(var.direct_pull_principals) > 0 ? [
    {
      Sid       = "DirectPull"
      Effect    = "Allow"
      Action    = ["ecr:BatchGetImage", "ecr:GetDownloadUrlForLayer"]
      Resource  = local.repository_arn_pattern
      Principal = { AWS = var.direct_pull_principals }
    }
  ] : []

  registry_statements = concat(
    [local.pull_through_cache_statement],
    local.direct_pull_statements,
    var.additional_registry_statements,
  )
}

resource "aws_ecr_registry_policy" "platform" {
  policy = jsonencode({
    Version   = "2012-10-17"
    Statement = local.registry_statements
  })
}
