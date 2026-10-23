# Copyright 2026 BitWise Media Group Ltd
# SPDX-License-Identifier: MIT

# The application's cloud identities, minted exactly as the cluster root mints
# them (iam.tf there): a Pod Identity-bound role per workload grant, and a
# podless IRSA reader role per secret-sync KSA. The secrets-store-sync-
# controller materialises each SecretSync WITHOUT a pod, so its token lacks
# the kubernetes.io/pod claim Pod Identity requires; AssumeRoleWithWebIdentity
# needs only the SA-scoped OIDC token, so the readers trust the cluster's IRSA
# provider instead. Role names are a published contract: the manifests compose
# ${SECRETS_ROLE_PREFIX}<ns>-<sa> into each sync KSA's role-arn annotation.

data "aws_caller_identity" "current" {}

data "aws_partition" "current" {}

data "aws_region" "current" {}

locals {
  # Every secret this cluster's prefix covers - the same scope the cluster
  # root grants its own readers, so clusters sharing an account cannot read
  # each other's secrets.
  secret_arn_pattern = join(":", [
    "arn",
    data.aws_partition.current.partition,
    "secretsmanager",
    data.aws_region.current.region,
    data.aws_caller_identity.current.account_id,
    "secret",
    "${var.cluster.secret_prefix}*",
  ])

  secret_readers = {
    for reader in var.secret_readers : "secrets-${reader.namespace}-${reader.service_account}" => reader
  }
}

data "aws_iam_policy_document" "pod_identity_assume_role" {
  statement {
    actions = ["sts:AssumeRole", "sts:TagSession"]

    principals {
      type        = "Service"
      identifiers = ["pods.eks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "workload" {
  for_each = var.workload_grants

  # A fixed name, never name_prefix: the same deterministic <cluster>-<key> the
  # cluster root uses, so a duplicate grant fails rather than shadows.
  name               = "${var.cluster.name}-${each.key}"
  description        = "Workload ${each.value.namespace}/${each.value.service_account} (${var.cluster.name}, application ${var.name})"
  assume_role_policy = data.aws_iam_policy_document.pod_identity_assume_role.json

  tags = var.tags
}

resource "aws_iam_role_policy" "workload" {
  for_each = var.workload_grants

  name   = "workload"
  role   = aws_iam_role.workload[each.key].id
  policy = each.value.policy
}

resource "aws_eks_pod_identity_association" "workload" {
  for_each = var.workload_grants

  cluster_name    = var.cluster.name
  namespace       = each.value.namespace
  service_account = each.value.service_account
  role_arn        = aws_iam_role.workload[each.key].arn

  tags = var.tags
}

data "aws_iam_policy_document" "irsa_assume_role" {
  for_each = local.secret_readers

  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [var.cluster.oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${var.cluster.oidc_issuer}:sub"
      values   = ["system:serviceaccount:${each.value.namespace}:${each.value.service_account}"]
    }

    condition {
      test     = "StringEquals"
      variable = "${var.cluster.oidc_issuer}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

data "aws_iam_policy_document" "secret_read" {
  statement {
    sid    = "ReadSecrets"
    effect = "Allow"

    actions = [
      "secretsmanager:GetSecretValue",
      "secretsmanager:DescribeSecret",
    ]

    resources = [local.secret_arn_pattern]
  }
}

resource "aws_iam_role" "secret_reader" {
  for_each = local.secret_readers

  # <cluster>-secrets-<ns>-<sa>: what ${SECRETS_ROLE_PREFIX}<ns>-<sa> resolves
  # to in the manifests.
  name               = "${var.cluster.name}-${each.key}"
  description        = "Workload ${each.value.namespace}/${each.value.service_account} (${var.cluster.name}, application ${var.name})"
  assume_role_policy = data.aws_iam_policy_document.irsa_assume_role[each.key].json

  tags = var.tags
}

resource "aws_iam_role_policy" "secret_reader" {
  for_each = local.secret_readers

  name   = "workload"
  role   = aws_iam_role.secret_reader[each.key].id
  policy = data.aws_iam_policy_document.secret_read.json
}
