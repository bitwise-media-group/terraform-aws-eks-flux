# Copyright 2026 BitWise Media Group Ltd
# SPDX-License-Identifier: MIT

# Registry read for the flux controllers, as EKS Pod Identity associations (no
# OIDC trust policies, no annotations):
#
#   - source-controller pulls the sync artifact and every chart OCIRepository
#     (spec.provider: aws resolves credentials from the Pod Identity agent)
#   - flux-operator lists chart tags for ECRArtifactTag
#     ResourceSetInputProviders, so it needs the same read access
#
# Both roles are scoped to the platform registry prefix, never the whole
# registry.

data "aws_iam_policy_document" "assume_role" {
  statement {
    actions = ["sts:AssumeRole", "sts:TagSession"]

    principals {
      type        = "Service"
      identifiers = ["pods.eks.amazonaws.com"]
    }
  }
}

data "aws_iam_policy_document" "registry_read" {
  statement {
    sid       = "Authorize"
    effect    = "Allow"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }

  statement {
    sid    = "Pull"
    effect = "Allow"

    actions = [
      "ecr:BatchGetImage",
      "ecr:GetDownloadUrlForLayer",
      "ecr:BatchCheckLayerAvailability",
      "ecr:DescribeImages",
      "ecr:ListImages",
    ]

    resources = [var.registry_arn]
  }

  # A pull-through cache materialises a repository on the FIRST pull, so the
  # controllers need create/import as well as read when the registry is a
  # cache rather than the store itself.
  dynamic "statement" {
    for_each = var.registry_is_pull_through_cache ? ["this"] : []

    content {
      sid    = "CacheFill"
      effect = "Allow"

      actions = [
        "ecr:CreateRepository",
        "ecr:BatchImportUpstreamImage",
        "ecr:GetImageCopyStatus",
      ]

      resources = [var.registry_arn]
    }
  }
}

resource "aws_iam_role" "flux" {
  for_each = toset(["source-controller", "flux-operator"])

  name               = "${var.cluster_name}-${each.value}"
  description        = "Flux ${each.value} (${var.cluster_name}) — platform registry read"
  assume_role_policy = data.aws_iam_policy_document.assume_role.json

  tags = var.tags
}

resource "aws_iam_role_policy" "flux" {
  for_each = aws_iam_role.flux

  name   = "registry-read"
  role   = each.value.id
  policy = data.aws_iam_policy_document.registry_read.json
}

resource "aws_eks_pod_identity_association" "flux" {
  for_each = aws_iam_role.flux

  cluster_name    = var.cluster_name
  namespace       = var.namespace
  service_account = each.key
  role_arn        = each.value.arn

  tags = var.tags
}
