# Copyright 2026 BitWise Media Group Ltd
# SPDX-License-Identifier: MIT

# Karpenter - node auto-provisioning for workload capacity. Karpenter is not
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
  karpenter_ami       = local.karpenter_node_pool.ami

  karpenter_ami_name = try(replace(local.karpenter_ami.name, "{kubernetes_version}", aws_eks_cluster.main.version), null)

  # The EC2NodeClass amiSelectorTerms, published whole as JSON (each branch
  # is encoded on its own: the term shapes differ). Karpenter forbids
  # combining id with any other field in a term, so an id's owner is checked
  # through data.aws_ami.karpenter instead; a name becomes one name+owner term
  # per owner (terms OR together), resolved by Karpenter at runtime.
  karpenter_ami_selector_terms = (
    local.karpenter_ami == null ? jsonencode([{ alias = local.karpenter_node_pool.ami_alias }]) :
    local.karpenter_ami.id != null ? jsonencode([{ id = data.aws_ami.karpenter[0].id }]) :
    jsonencode([for owner in local.karpenter_ami.owners : { name = local.karpenter_ami_name, owner = owner }])
  )

  # An alias implies its family; any other selector needs spec.amiFamily, and
  # custom images are AL2023 only.
  karpenter_ami_family = local.karpenter_ami == null ? "" : "AL2023"

  # The subnets Karpenter discovers by tag: the node subnets only, since
  # EC2NodeClass default selects subnets by this tag alone and a tagged
  # subnet is one it may launch nodes into. The public and internal subnets
  # stay untagged - the Gateway's NLB names its subnets explicitly
  # (GATEWAY_SUBNETS) and the load-balancer controller never reads this tag.
  # The VPC is owned upstream, so tagging is opt-out.
  discovery_targets = var.network.manage_discovery_tags ? var.network.node_subnet_ids : []
}

# Fails the plan early when the custom image is unowned by owners or matches
# nothing - otherwise the first sign would be Karpenter refusing to launch.
data "aws_ami" "karpenter" {
  count = local.karpenter_ami != null ? 1 : 0

  owners      = local.karpenter_ami.owners
  most_recent = true

  filter {
    name   = "state"
    values = ["available"]
  }

  dynamic "filter" {
    for_each = local.karpenter_ami.id != null ? [local.karpenter_ami.id] : []

    content {
      name   = "image-id"
      values = [filter.value]
    }
  }

  dynamic "filter" {
    for_each = local.karpenter_ami_name != null ? [local.karpenter_ami_name] : []

    content {
      name   = "name"
      values = [filter.value]
    }
  }
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
  name_prefix        = "${var.name}-karpenter-node-"
  description        = "Karpenter-provisioned nodes (${var.name})"
  assume_role_policy = data.aws_iam_policy_document.node_assume_role.json

  tags = var.tags

  # Create-before-destroy (here and on every name_prefix identity): the
  # controller policy document reads this role's ARN, so a plain
  # destroy-then-create replacement wedges that deferred read between the
  # destroys and cycles the graph. Creating the successor first keeps
  # replacement applies (a cluster recreation, a rename) a single pass.
  lifecycle {
    create_before_destroy = true
  }
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
  name_prefix               = "${var.name}-karpenter-interruption-"
  message_retention_seconds = 300
  sqs_managed_sse_enabled   = true

  tags = var.tags

  lifecycle {
    create_before_destroy = true
  }
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

  # A fixed name, not name_prefix: rule names cap at 64 chars and the
  # generated suffix is 26, which a max-length cluster name would overflow.
  # Collisions need two same-named clusters in one account, which the
  # discovery tags already forbid.
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
# workload - the bootstrap-cycle argument that keeps Cilium on the node role
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

  # Only the node role, and only onto EC2 - so a compromised controller cannot
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

  # An encrypted custom image's snapshots are under a customer-managed key,
  # and the fleet launch runs as this role - so it needs the key to create the
  # nodes' volumes. Grants are for AWS resources (EBS) only.
  dynamic "statement" {
    for_each = length(try(local.karpenter_ami.kms_key_arns, [])) > 0 ? [local.karpenter_ami.kms_key_arns] : []

    content {
      sid    = "EncryptedAMIKeys"
      effect = "Allow"

      actions = [
        "kms:Decrypt",
        "kms:DescribeKey",
        "kms:GenerateDataKeyWithoutPlaintext",
        "kms:ReEncryptFrom",
        "kms:ReEncryptTo",
      ]

      resources = statement.value
    }
  }

  dynamic "statement" {
    for_each = length(try(local.karpenter_ami.kms_key_arns, [])) > 0 ? [local.karpenter_ami.kms_key_arns] : []

    content {
      sid       = "EncryptedAMIKeyGrants"
      effect    = "Allow"
      actions   = ["kms:CreateGrant"]
      resources = statement.value

      condition {
        test     = "Bool"
        variable = "kms:GrantIsForAWSResource"
        values   = ["true"]
      }
    }
  }
}

resource "aws_iam_role" "karpenter_controller" {
  name_prefix        = "${var.name}-karpenter-"
  description        = "Karpenter controller (${var.name})"
  assume_role_policy = data.aws_iam_policy_document.pod_identity_assume_role.json

  tags = var.tags

  lifecycle {
    create_before_destroy = true
  }
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
