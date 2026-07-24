# Copyright 2026 BitWise Media Group Ltd
# SPDX-License-Identifier: MIT

# Karpenter — the replacement for GKE node auto-provisioning. Karpenter is not
# an EKS add-on (it is in neither the AWS nor the community catalogue); the only
# AWS-managed Karpenter is EKS Auto Mode, which owns networking with the VPC CNI
# and so cannot run Cilium in ENI mode.
#
# The split: terraform owns the IAM roles, the interruption queue, the discovery
# tags and the NodePool SHAPE (var.karpenter, published as KARPENTER_* cluster
# vars); flux-manifests owns the chart and renders the EC2NodeClass/NodePool
# from those vars. That keeps capacity policy where the rest of the cluster
# shape lives without terraform ever having to apply a CR whose CRD flux has not
# installed yet.

locals {
  karpenter_node_pool = var.karpenter.node_pool

  # Subnets and security groups Karpenter (and the load-balancer controller)
  # discover by tag. The VPC is owned upstream, so tagging is opt-out.
  discovery_targets = var.network.manage_discovery_tags ? setunion(
    var.network.node_subnet_ids,
    var.network.public_subnet_ids,
  ) : []
}

resource "aws_ec2_tag" "discovery" {
  for_each = local.discovery_targets

  resource_id = each.value
  key         = local.discovery_tag
  value       = var.name
}

resource "aws_ec2_tag" "cluster_security_group_discovery" {
  count = var.network.manage_discovery_tags ? 1 : 0

  resource_id = aws_eks_cluster.main.vpc_config[0].cluster_security_group_id
  key         = local.discovery_tag
  value       = var.name
}

# ---------------------------------------------------------------------------
# The role Karpenter-launched nodes run as. Separate from the system node
# group's role so workload capacity can be scoped differently later, but
# identical today apart from the Cilium ENI grant, which every node needs.
# ---------------------------------------------------------------------------

resource "aws_iam_role" "karpenter_node" {
  name               = "${var.name}-karpenter-node"
  description        = "Karpenter-provisioned nodes (${var.name})"
  assume_role_policy = data.aws_iam_policy_document.node_assume_role.json

  tags = var.tags
}

resource "aws_iam_role_policy_attachment" "karpenter_node" {
  for_each = toset([
    "arn:${local.partition}:iam::aws:policy/AmazonEKSWorkerNodePolicy",
    "arn:${local.partition}:iam::aws:policy/AmazonEC2ContainerRegistryPullOnly",
    "arn:${local.partition}:iam::aws:policy/AmazonSSMManagedInstanceCore",
  ])

  role       = aws_iam_role.karpenter_node.name
  policy_arn = each.value
}

resource "aws_iam_role_policy" "karpenter_node_cilium_eni" {
  count = var.cilium.operator_pod_identity ? 0 : 1

  name   = "${var.name}-cilium-eni"
  role   = aws_iam_role.karpenter_node.id
  policy = data.aws_iam_policy_document.cilium_eni.json
}

# Karpenter nodes join through their own access entry, exactly as the system
# node group's role does.
resource "aws_eks_access_entry" "karpenter_node" {
  cluster_name  = aws_eks_cluster.main.name
  principal_arn = aws_iam_role.karpenter_node.arn
  type          = "EC2_LINUX"

  tags = var.tags
}

# ---------------------------------------------------------------------------
# Spot interruption / rebalance / health events. Karpenter drains a node when
# one of these arrives rather than losing it mid-flight.
# ---------------------------------------------------------------------------

resource "aws_sqs_queue" "karpenter_interruption" {
  name                      = "${var.name}-karpenter-interruption"
  message_retention_seconds = 300
  sqs_managed_sse_enabled   = true

  tags = var.tags
}

data "aws_iam_policy_document" "karpenter_interruption" {
  statement {
    sid       = "EventBridgeWrite"
    effect    = "Allow"
    actions   = ["sqs:SendMessage"]
    resources = [aws_sqs_queue.karpenter_interruption.arn]

    principals {
      type        = "Service"
      identifiers = ["events.amazonaws.com", "sqs.amazonaws.com"]
    }
  }

  # Only this account's rules may write, so a queue name guess from elsewhere
  # cannot inject drain events.
  statement {
    sid       = "DenyOffAccount"
    effect    = "Deny"
    actions   = ["sqs:*"]
    resources = [aws_sqs_queue.karpenter_interruption.arn]

    principals {
      type        = "AWS"
      identifiers = ["*"]
    }

    condition {
      test     = "StringNotEquals"
      variable = "aws:SourceAccount"
      values   = [local.account_id]
    }

    condition {
      test     = "Bool"
      variable = "aws:PrincipalIsAWSService"
      values   = ["true"]
    }
  }
}

resource "aws_sqs_queue_policy" "karpenter_interruption" {
  queue_url = aws_sqs_queue.karpenter_interruption.id
  policy    = data.aws_iam_policy_document.karpenter_interruption.json
}

locals {
  karpenter_events = {
    spot_interruption = {
      source      = ["aws.ec2"]
      detail_type = ["EC2 Spot Instance Interruption Warning"]
    }
    rebalance = {
      source      = ["aws.ec2"]
      detail_type = ["EC2 Instance Rebalance Recommendation"]
    }
    state_change = {
      source      = ["aws.ec2"]
      detail_type = ["EC2 Instance State-change Notification"]
    }
    scheduled_change = {
      source      = ["aws.health"]
      detail_type = ["AWS Health Event"]
    }
  }
}

resource "aws_cloudwatch_event_rule" "karpenter" {
  for_each = local.karpenter_events

  name        = "${var.name}-karpenter-${replace(each.key, "_", "-")}"
  description = "Karpenter interruption handling (${var.name}): ${each.value.detail_type[0]}"

  event_pattern = jsonencode({
    source        = each.value.source
    "detail-type" = each.value.detail_type
  })

  tags = var.tags
}

resource "aws_cloudwatch_event_target" "karpenter" {
  for_each = aws_cloudwatch_event_rule.karpenter

  rule      = each.value.name
  target_id = "karpenter-interruption-queue"
  arn       = aws_sqs_queue.karpenter_interruption.arn
}

# ---------------------------------------------------------------------------
# The controller's own identity (Pod Identity, like every other platform
# workload — the bootstrap-cycle argument that keeps Cilium on the node role
# does not apply here: Karpenter deploys through flux, long after the
# pod-identity-agent exists).
# ---------------------------------------------------------------------------

data "aws_iam_policy_document" "karpenter_controller" {
  statement {
    sid    = "LaunchAndTerminate"
    effect = "Allow"

    actions = [
      "ec2:CreateLaunchTemplate",
      "ec2:CreateFleet",
      "ec2:RunInstances",
      "ec2:CreateTags",
      "ec2:TerminateInstances",
      "ec2:DeleteLaunchTemplate",
    ]

    resources = ["*"]

    # Karpenter may only touch resources belonging to THIS cluster; everything
    # it creates carries the tag, and the launch/terminate calls are scoped to
    # it. Instance types and images are read-only lookups (next statement).
    condition {
      test     = "StringEquals"
      variable = "aws:RequestTag/kubernetes.io/cluster/${var.name}"
      values   = ["owned"]
    }
  }

  statement {
    sid    = "Discovery"
    effect = "Allow"

    actions = [
      "ec2:DescribeAvailabilityZones",
      "ec2:DescribeImages",
      "ec2:DescribeInstances",
      "ec2:DescribeInstanceTypeOfferings",
      "ec2:DescribeInstanceTypes",
      "ec2:DescribeLaunchTemplates",
      "ec2:DescribeSecurityGroups",
      "ec2:DescribeSpotPriceHistory",
      "ec2:DescribeSubnets",
      "pricing:GetProducts",
    ]

    resources = ["*"]
  }

  # Karpenter reads the EKS-published AMI ids for the alias in the
  # EC2NodeClass (al2023@latest and friends).
  statement {
    sid       = "ReadAMIParameters"
    effect    = "Allow"
    actions   = ["ssm:GetParameter"]
    resources = ["arn:${local.partition}:ssm:*::parameter/aws/service/*"]
  }

  statement {
    sid       = "ReadCluster"
    effect    = "Allow"
    actions   = ["eks:DescribeCluster"]
    resources = [aws_eks_cluster.main.arn]
  }

  # Only the node role, and only onto EC2 — so a compromised controller cannot
  # mint instances carrying a more privileged identity.
  statement {
    sid       = "PassNodeRole"
    effect    = "Allow"
    actions   = ["iam:PassRole"]
    resources = [aws_iam_role.karpenter_node.arn]

    condition {
      test     = "StringEquals"
      variable = "iam:PassedToService"
      values   = ["ec2.amazonaws.com"]
    }
  }

  # Karpenter manages the instance profile for its EC2NodeClass itself.
  statement {
    sid    = "ManageInstanceProfiles"
    effect = "Allow"

    actions = [
      "iam:AddRoleToInstanceProfile",
      "iam:CreateInstanceProfile",
      "iam:DeleteInstanceProfile",
      "iam:GetInstanceProfile",
      "iam:RemoveRoleFromInstanceProfile",
      "iam:TagInstanceProfile",
    ]

    resources = ["*"]
  }

  statement {
    sid    = "InterruptionQueue"
    effect = "Allow"

    actions = [
      "sqs:DeleteMessage",
      "sqs:GetQueueUrl",
      "sqs:ReceiveMessage",
    ]

    resources = [aws_sqs_queue.karpenter_interruption.arn]
  }
}

resource "aws_iam_role" "karpenter_controller" {
  name               = "${var.name}-karpenter"
  description        = "Karpenter controller (${var.name})"
  assume_role_policy = data.aws_iam_policy_document.pod_identity_assume_role.json

  tags = var.tags
}

resource "aws_iam_role_policy" "karpenter_controller" {
  name   = "controller"
  role   = aws_iam_role.karpenter_controller.id
  policy = data.aws_iam_policy_document.karpenter_controller.json
}

resource "aws_eks_pod_identity_association" "karpenter_controller" {
  cluster_name    = aws_eks_cluster.main.name
  namespace       = var.workload_identity.karpenter.namespace
  service_account = var.workload_identity.karpenter.service_account
  role_arn        = aws_iam_role.karpenter_controller.arn

  tags = var.tags

  depends_on = [aws_eks_addon.pod_identity_agent]
}
