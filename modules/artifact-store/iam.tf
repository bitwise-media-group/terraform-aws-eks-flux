# Copyright 2026 BitWise Media Group Ltd
# SPDX-License-Identifier: MIT

# Who may push, and who may pull.
#
# PUSH: the GitHub Actions publishers, through the account's GitHub OIDC
# provider - the chart publisher (flux-containers) and one manifest publisher
# per manifest-publishing repo (the platform's, and each application's), each
# scoped to its own paths beneath the prefix. These are the only long-lived
# identities the platform has - every in-cluster workload uses EKS Pod
# Identity instead.
#
# PULL: nothing by default except the ECR pull-through cache service, and that
# ORG-WIDE rather than per-account, so a new cluster account onboards without
# touching this module. Clusters read the store through a cache in their own
# account (modules/registry-cache); direct_pull_principals is the escape hatch
# for the ones the platform team lets read it straight.

locals {
  # GitHub mints immutable subjects for repos created (or renamed/transferred)
  # after 2026-07-15: repo:<org>@<org id>/<repo>@<repo id>:<context>. Every
  # publishing repo is post-cutoff, so the subject conditions must pin the
  # numeric ids - the name-only form never matches and AssumeRoleWithWebIdentity
  # fails.
  containers_subject_repo = "${var.github.org}@${var.github.org_id}/${var.github.containers}@${var.github.containers_id}"

  # A manifest-publishing repo may not exist on GitHub yet when the store is
  # first applied. Until its repository_id is set, the subject falls back to
  # the name-only form - which a post-cutoff repo will never present - so set
  # the id and re-apply as soon as the repo is created.
  manifest_subject_repos = {
    for repo, publisher in var.github.manifest_publishers : repo => (
      publisher.repository_id != null
      ? "${var.github.org}@${var.github.org_id}/${repo}@${publisher.repository_id}"
      : "${var.github.org}/${repo}"
    )
  }

  oidc_provider_arn = coalesce(
    var.oidc_provider_arn,
    one(aws_iam_openid_connect_provider.github[*].arn),
  )

  # flux-containers publishes (and keyless-signs) charts + images from its
  # default branch only - PR validation never gets push credentials.
  chart_publisher_subjects = ["repo:${local.containers_subject_repo}:ref:refs/heads/main"]

  # Every manifest publisher is trusted from the same three contexts: release
  # tags publish versioned artifacts and move `staging`; merges to main
  # publish the `edge` channel; the protected promotion environment moves
  # `stable`.
  manifest_publisher_subjects = {
    for repo, subject_repo in local.manifest_subject_repos : repo => [
      "repo:${subject_repo}:ref:refs/heads/main",
      "repo:${subject_repo}:ref:refs/tags/v*",
      "repo:${subject_repo}:environment:${var.promotion_environment}",
    ]
  }

  # Every trust, keyed as the roles are: "chart" plus one key per manifest
  # publisher.
  publisher_subjects = merge(
    { chart = local.chart_publisher_subjects },
    local.manifest_publisher_subjects,
  )

  # What each publisher may push, as repository ARN patterns beneath the
  # prefix. The chart publisher owns the mirror namespaces; each manifest
  # publisher owns exactly the paths it declares - the platform's own repo
  # keeps the wide manifests/* because it is the platform authority, an
  # application repo gets manifests/<app> alone, so it can never overwrite
  # the platform (or another application).
  publisher_paths = merge(
    { chart = ["charts/*", "images/*", "artifacts/*"] },
    { for repo, publisher in var.github.manifest_publishers : repo => publisher.paths },
  )
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
  for_each = local.publisher_subjects

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
  for_each = local.publisher_paths

  statement {
    sid       = "Authorize"
    effect    = "Allow"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }

  # CreateRepository is what makes the creation template fire: a publisher
  # pushing <prefix>/charts/kyverno for the first time creates that repository
  # with the template's settings. Scoped to the publisher's own paths beneath
  # the prefix, so a publisher cannot create or overwrite repositories
  # anywhere else in the registry.
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

    resources = [
      for path in each.value :
      "arn:${local.partition}:ecr:${local.region}:${local.account_id}:repository/${var.repository_prefix}/${path}"
    ]
  }

  # KMS signing mode: cosign signs with awskms:///<key> from the publish
  # workflows, which needs Sign plus the public-key/metadata reads cosign
  # performs around it. Absent entirely in keyless mode.
  dynamic "statement" {
    for_each = var.signing_kms_key_arn != null ? ["true"] : []

    content {
      sid    = "CosignSign"
      effect = "Allow"

      actions = [
        "kms:Sign",
        "kms:GetPublicKey",
        "kms:DescribeKey",
      ]

      resources = [var.signing_kms_key_arn]
    }
  }
}

# Push separation is per path: every publisher pushes only beneath the paths
# it is granted, so a compromised application publisher cannot replace the
# platform entrypoint. Content security is still consumer-side verification -
# every OCIRepository and the Kyverno policy pin the exact signer workflow
# identity, so a fake artifact from any publisher fails verification on the
# cluster.
resource "aws_iam_role" "chart_publisher" {
  name               = "${var.name}-chart-publisher"
  description        = "Pushes charts and images to ${var.repository_prefix}/* from ${var.github.org}/${var.github.containers} via GitHub OIDC"
  assume_role_policy = data.aws_iam_policy_document.publisher_assume_role["chart"].json

  tags = var.tags
}

resource "aws_iam_role_policy" "chart_publisher" {
  name   = "publish"
  role   = aws_iam_role.chart_publisher.id
  policy = data.aws_iam_policy_document.publisher["chart"].json
}

# One role per manifest-publishing repo (the platform's, and each
# application's), each the role-to-assume of its repo's publish workflows.
resource "aws_iam_role" "manifest_publisher" {
  for_each = var.github.manifest_publishers

  name               = "${var.name}-${each.key}-publisher"
  description        = "Pushes ${join(", ", [for path in each.value.paths : "${var.repository_prefix}/${path}"])} from ${var.github.org}/${each.key} via GitHub OIDC"
  assume_role_policy = data.aws_iam_policy_document.publisher_assume_role[each.key].json

  tags = var.tags
}

resource "aws_iam_role_policy" "manifest_publisher" {
  for_each = aws_iam_role.manifest_publisher

  name   = "publish"
  role   = each.value.id
  policy = data.aws_iam_policy_document.publisher[each.key].json
}

# 3.x addressed the two publishers as aws_iam_role.publisher["chart"] and
# aws_iam_role.publisher["manifest"]; the platform publisher now lives under
# its repo name. The chart publisher keeps its name; the platform publisher's
# name changes (platform-manifest-publisher -> platform-<repo>-publisher), so
# it is replaced on the first apply - update the repo's
# AWS_MANIFEST_PUBLISHER_ROLE variable from the manifest_publishers output.
moved {
  from = aws_iam_role.publisher["chart"]
  to   = aws_iam_role.chart_publisher
}

moved {
  from = aws_iam_role_policy.publisher["chart"]
  to   = aws_iam_role_policy.chart_publisher
}

moved {
  from = aws_iam_role.publisher["manifest"]
  to   = aws_iam_role.manifest_publisher["flux-manifests"]
}

moved {
  from = aws_iam_role_policy.publisher["manifest"]
  to   = aws_iam_role_policy.manifest_publisher["flux-manifests"]
}

# ---------------------------------------------------------------------------
# Read access. A registry policy rather than per-repository policies, so it
# covers every repository the creation template will ever make - including the
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
  # account - no list to maintain as clusters come online.
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
  # cache - feed a cluster's registry_reader_principals output through here.
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
