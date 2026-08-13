# Copyright 2026 BitWise Media Group Ltd
# SPDX-License-Identifier: MIT

# EKS Pod Identity associations for the flux-deployed platform workloads. The
# namespace/service-account pairs are the terraform <-> flux-manifests contract
# (overridable via var.workload_identity so this repo can track a manifests
# change without a schema change) — the pairs themselves are cloud-neutral, so
# every cluster consumes the same manifests.
#
# flux-system's own associations (source-controller, flux-operator) live in
# modules/flux-operator/iam.tf next to the workloads they serve. Karpenter's
# lives in karpenter.tf, and Cilium's in cilium.tf, each beside the rest of
# their wiring.

data "aws_iam_policy_document" "pod_identity_assume_role" {
  statement {
    actions = ["sts:AssumeRole", "sts:TagSession"]

    principals {
      type        = "Service"
      identifiers = ["pods.eks.amazonaws.com"]
    }
  }
}

locals {
  route53_zone_arn = var.dns.zone_name != null ? "arn:${local.partition}:route53:::hostedzone/${local.dns_zone_id}" : null

  secret_arn_pattern = "arn:${local.partition}:secretsmanager:${data.aws_region.current.region}:${local.account_id}:secret:${local.secret_prefix}*"

  # name -> { namespace, service_account, policy }. Every entry becomes one IAM
  # role, one inline policy and one Pod Identity association.
  workload_grants = merge(
    # DNS-01 challenges and record publication both need the same write on the
    # delegated zone; absent entirely when the DNS surface is off.
    var.dns.zone_name == null ? {} : {
      external-dns = {
        namespace       = var.workload_identity.external_dns.namespace
        service_account = var.workload_identity.external_dns.service_account
        policy          = data.aws_iam_policy_document.route53[0].json
      }
      cert-manager = {
        namespace       = var.workload_identity.cert_manager.namespace
        service_account = var.workload_identity.cert_manager.service_account
        policy          = data.aws_iam_policy_document.route53[0].json
      }
    },
    {
      otel-collector = {
        namespace       = var.workload_identity.otel_collector.namespace
        service_account = var.workload_identity.otel_collector.service_account
        policy          = data.aws_iam_policy_document.otel_collector.json
      }
      aws-load-balancer-controller = {
        namespace       = var.workload_identity.load_balancer.namespace
        service_account = var.workload_identity.load_balancer.service_account
        policy          = data.aws_iam_policy_document.load_balancer_controller.json
      }
    },
    # kyverno fetches image signatures from the registry at admission time, so
    # its controllers read the platform registry like the flux controllers do
    # (plus the KMS verify grant when that is the signing mode).
    {
      for service_account in var.workload_identity.kyverno.service_accounts :
      "kyverno-${service_account}" => {
        namespace       = var.workload_identity.kyverno.namespace
        service_account = service_account
        policy          = data.aws_iam_policy_document.kyverno.json
      }
    },
    # The KSAs the secrets-store-sync-controller runs as, one per consuming
    # namespace: the pairs the SSO surface implies (derived in sso.tf from the
    # election) plus any extras the caller names. Scoped to this cluster's
    # SECRET_PREFIX so clusters sharing an account cannot read each other's
    # secrets; each secret's own policy (sso.tf) narrows it further.
    {
      for reader in concat(local.sso_secret_readers, var.workload_identity.secret_readers) :
      "secrets-${reader.namespace}-${reader.service_account}" => {
        namespace       = reader.namespace
        service_account = reader.service_account
        policy          = data.aws_iam_policy_document.secret_read.json
      }
    },
  )
}

data "aws_iam_policy_document" "route53" {
  count = var.dns.zone_name != null ? 1 : 0

  statement {
    sid       = "ChangeRecords"
    effect    = "Allow"
    actions   = ["route53:ChangeResourceRecordSets"]
    resources = [local.route53_zone_arn]
  }

  statement {
    sid    = "ReadZones"
    effect = "Allow"

    actions = [
      "route53:ListHostedZones",
      "route53:ListHostedZonesByName",
      "route53:ListResourceRecordSets",
      "route53:GetChange",
    ]

    resources = ["*"]
  }
}

data "aws_iam_policy_document" "otel_collector" {
  statement {
    sid    = "WriteTelemetry"
    effect = "Allow"

    actions = [
      "logs:CreateLogGroup",
      "logs:CreateLogStream",
      "logs:PutLogEvents",
      "logs:DescribeLogGroups",
      "logs:DescribeLogStreams",
      "cloudwatch:PutMetricData",
      "xray:PutTraceSegments",
      "xray:PutTelemetryRecords",
      "xray:GetSamplingRules",
      "xray:GetSamplingTargets",
    ]

    resources = ["*"]
  }

  # Only when a Managed Prometheus workspace is the metrics target.
  dynamic "statement" {
    for_each = var.observability.amp_endpoint != null ? ["this"] : []

    content {
      sid       = "RemoteWrite"
      effect    = "Allow"
      actions   = ["aps:RemoteWrite"]
      resources = ["*"]
    }
  }
}

# The controller exists to provision the NLB behind the Cilium Gateway (and to
# bind the reserved EIPs to it); it is not an ingress path of its own.
data "aws_iam_policy_document" "load_balancer_controller" {
  statement {
    sid    = "Describe"
    effect = "Allow"

    actions = [
      "ec2:DescribeAccountAttributes",
      "ec2:DescribeAddresses",
      "ec2:DescribeAvailabilityZones",
      "ec2:DescribeInstances",
      "ec2:DescribeInternetGateways",
      "ec2:DescribeNetworkInterfaces",
      "ec2:DescribeSecurityGroups",
      "ec2:DescribeSubnets",
      "ec2:DescribeTags",
      "ec2:DescribeVpcs",
      "elasticloadbalancing:Describe*",
      "acm:DescribeCertificate",
      "acm:ListCertificates",
    ]

    resources = ["*"]
  }

  statement {
    sid    = "ManageLoadBalancers"
    effect = "Allow"

    actions = [
      "elasticloadbalancing:AddTags",
      "elasticloadbalancing:RemoveTags",
      "elasticloadbalancing:CreateLoadBalancer",
      "elasticloadbalancing:DeleteLoadBalancer",
      "elasticloadbalancing:ModifyLoadBalancerAttributes",
      "elasticloadbalancing:SetSubnets",
      "elasticloadbalancing:SetSecurityGroups",
      "elasticloadbalancing:CreateTargetGroup",
      "elasticloadbalancing:DeleteTargetGroup",
      "elasticloadbalancing:ModifyTargetGroup",
      "elasticloadbalancing:ModifyTargetGroupAttributes",
      "elasticloadbalancing:RegisterTargets",
      "elasticloadbalancing:DeregisterTargets",
      "elasticloadbalancing:CreateListener",
      "elasticloadbalancing:DeleteListener",
      "elasticloadbalancing:ModifyListener",
      "ec2:CreateSecurityGroup",
      "ec2:DeleteSecurityGroup",
      "ec2:AuthorizeSecurityGroupIngress",
      "ec2:RevokeSecurityGroupIngress",
      "ec2:CreateTags",
      "ec2:DeleteTags",
    ]

    resources = ["*"]
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

    resources = [local.registry_arn]
  }

  # A pull-through cache materialises a repository on the FIRST pull of each
  # image, so every puller needs create/import as well as read.
  dynamic "statement" {
    for_each = var.platform_registry.is_pull_through_cache ? ["this"] : []

    content {
      sid    = "CacheFill"
      effect = "Allow"

      actions = [
        "ecr:CreateRepository",
        "ecr:BatchImportUpstreamImage",
        "ecr:GetImageCopyStatus",
      ]

      resources = [local.registry_arn]
    }
  }
}

# kyverno's image policy verifies signatures at admission/report time: always
# a registry reader, and in KMS signing mode also allowed to resolve the
# signing key (cosign's awskms:///<arn> path fetches the public key and may
# verify remotely).
data "aws_iam_policy_document" "kyverno" {
  source_policy_documents = [data.aws_iam_policy_document.registry_read.json]

  dynamic "statement" {
    for_each = local.signing_kms ? ["this"] : []

    content {
      sid       = "VerifySignatures"
      effect    = "Allow"
      actions   = ["kms:GetPublicKey", "kms:Verify"]
      resources = [var.signed_identity.kms_key_arn]
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

resource "aws_iam_role" "workload" {
  for_each = local.workload_grants

  name               = "${var.name}-${each.key}"
  description        = "Platform workload ${each.value.namespace}/${each.value.service_account} (${var.name})"
  assume_role_policy = data.aws_iam_policy_document.pod_identity_assume_role.json

  tags = var.tags
}

resource "aws_iam_role_policy" "workload" {
  for_each = local.workload_grants

  name   = "workload"
  role   = aws_iam_role.workload[each.key].id
  policy = each.value.policy
}

resource "aws_eks_pod_identity_association" "workload" {
  for_each = local.workload_grants

  cluster_name    = aws_eks_cluster.main.name
  namespace       = each.value.namespace
  service_account = each.value.service_account
  role_arn        = aws_iam_role.workload[each.key].arn

  tags = var.tags

  # Associations are accepted before the agent exists, but nothing can resolve
  # credentials until it does — ordering them keeps a fresh apply honest.
  depends_on = [aws_eks_addon.pod_identity_agent]
}

locals {
  # Every identity that reads the platform registry. When platform_registry is
  # a pull-through cache in this account the grants above are sufficient;
  # when it points straight at a central store, these are the principals the
  # store's direct_pull_principals must admit.
  registry_reader_principals = concat(
    [
      aws_iam_role.nodes.arn,
      aws_iam_role.karpenter_node.arn,
    ],
    [for role in module.flux_operator.registry_reader_roles : role],
    [
      for service_account in var.workload_identity.kyverno.service_accounts :
      aws_iam_role.workload["kyverno-${service_account}"].arn
    ],
  )
}
