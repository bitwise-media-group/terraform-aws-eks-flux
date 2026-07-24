# Copyright 2026 BitWise Media Group Ltd
# SPDX-License-Identifier: MIT

# A minimum-viable EKS cluster for the flux-operator platform: Cilium in ENI
# mode with the AWS VPC CNI never installed, kube-proxy replaced by Cilium's
# eBPF datapath, EKS Pod Identity for workload IAM, a small always-on system
# node group for platform controllers (label role=system) and Karpenter for
# everything else.
#
# Where GKE manages DNS, metrics, CSI and the metadata server itself, EKS
# delegates them to add-ons — so everything AWS offers managed is taken managed
# (see var.addons) and only the rest reaches the cluster through flux.
#
# BOOTSTRAP ORDER is the load-bearing constraint in this file. A node cannot
# report Ready without a CNI, and in ENI mode the Cilium agent cannot report
# ready until the operator has attached ENIs. So:
#
#   cluster -> access entries -> cilium (helm, wait=false, no nodes yet)
#           -> system node group -> add-ons -> pod identity -> flux
#
# Every depends_on below exists to hold that line.

data "aws_caller_identity" "current" {}

data "aws_partition" "current" {}

data "aws_region" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id
  partition  = data.aws_partition.current.partition

  system_node_selector = { role = "system" }

  # Karpenter and the AWS Load Balancer Controller both discover subnets and
  # security groups by this tag; it is also what NodePools select on.
  discovery_tag = "karpenter.sh/discovery"

  # Cilium allocates pod ENIs from these; defaults to the node subnets, which
  # is the single-subnet-pool posture most clusters want.
  pod_subnet_ids = length(var.network.pod_subnet_ids) > 0 ? var.network.pod_subnet_ids : var.network.node_subnet_ids

  # <account>.dkr.ecr.<region>.amazonaws.com/<prefix> split into the registry
  # host (for the ECR resource ARNs the pull grants are scoped to) and the
  # repository prefix beneath it.
  registry_host   = split("/", var.platform_registry.url)[0]
  registry_prefix = join("/", slice(split("/", var.platform_registry.url), 1, length(split("/", var.platform_registry.url))))
  registry_region = split(".", local.registry_host)[3]
  registry_owner  = split(".", local.registry_host)[0]

  # Every repository beneath the platform prefix, in the registry's own account
  # — which is the cluster's account when platform_registry is a pull-through
  # cache, and the store's account when it is read directly.
  registry_arn = "arn:${local.partition}:ecr:${local.registry_region}:${local.registry_owner}:repository/${local.registry_prefix}/*"

  addons = { for name, addon in var.addons : name => addon if addon.enabled }
}

# ---------------------------------------------------------------------------
# The node IAM role. Shared by the system node group and (via karpenter.tf's
# own role) the shape Karpenter nodes take.
# ---------------------------------------------------------------------------

data "aws_iam_policy_document" "node_assume_role" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "nodes" {
  name               = "${var.name}-nodes"
  description        = "EKS nodes (${var.name}) — kubelet, ECR pulls and the Cilium ENI datapath"
  assume_role_policy = data.aws_iam_policy_document.node_assume_role.json

  tags = var.tags
}

resource "aws_iam_role_policy_attachment" "nodes" {
  for_each = toset([
    "arn:${local.partition}:iam::aws:policy/AmazonEKSWorkerNodePolicy",
    # PullOnly, not the older ReadOnly: nodes never write to the registry.
    "arn:${local.partition}:iam::aws:policy/AmazonEC2ContainerRegistryPullOnly",
    # Session Manager access for break-glass, without opening SSH anywhere.
    "arn:${local.partition}:iam::aws:policy/AmazonSSMManagedInstanceCore",
  ])

  role       = aws_iam_role.nodes.name
  policy_arn = each.value
}

# Deliberately NOT AmazonEKS_CNI_Policy: that is the AWS VPC CNI's grant, and
# the VPC CNI is never installed here. Cilium's equivalent lives in cilium.tf.

resource "aws_iam_instance_profile" "nodes" {
  name = "${var.name}-nodes"
  role = aws_iam_role.nodes.name

  tags = var.tags
}

# ---------------------------------------------------------------------------
# The cluster
# ---------------------------------------------------------------------------

data "aws_iam_policy_document" "cluster_assume_role" {
  statement {
    actions = ["sts:AssumeRole", "sts:TagSession"]

    principals {
      type        = "Service"
      identifiers = ["eks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "cluster" {
  name               = "${var.name}-cluster"
  description        = "EKS control plane (${var.name})"
  assume_role_policy = data.aws_iam_policy_document.cluster_assume_role.json

  tags = var.tags
}

resource "aws_iam_role_policy_attachment" "cluster" {
  for_each = toset([
    "arn:${local.partition}:iam::aws:policy/AmazonEKSClusterPolicy",
    # Lets EKS manage the ENIs and security-group rules the control plane needs
    # to reach nodes; unrelated to pod networking.
    "arn:${local.partition}:iam::aws:policy/AmazonEKSVPCResourceController",
  ])

  role       = aws_iam_role.cluster.name
  policy_arn = each.value
}

resource "aws_eks_cluster" "main" {
  name     = var.name
  role_arn = aws_iam_role.cluster.arn
  version  = var.kubernetes_version

  # The whole design in one argument: EKS installs no default networking
  # add-ons, so vpc-cni and kube-proxy never exist and Cilium owns the
  # datapath from the first node onward. Changing it forces a new cluster.
  bootstrap_self_managed_addons = false

  vpc_config {
    subnet_ids = var.network.node_subnet_ids

    # The private endpoint is always on so in-VPC clients (and the nodes) never
    # traverse the public one; the public endpoint stays reachable so terraform
    # and helm bootstrap works from CI and workstations without a VPN path.
    endpoint_private_access = true
    endpoint_public_access  = true
    public_access_cidrs     = length(var.public_access_cidrs) > 0 ? var.public_access_cidrs : ["0.0.0.0/0"]
  }

  access_config {
    # API, never the aws-auth ConfigMap: access entries are the only
    # authorization surface, and var.rbac drives them.
    authentication_mode                         = "API"
    bootstrap_cluster_creator_admin_permissions = true
  }

  upgrade_policy {
    support_type = var.upgrade_policy
  }

  enabled_cluster_log_types = var.cluster_log_types

  dynamic "encryption_config" {
    for_each = var.encryption_kms_key_arn != null ? ["this"] : []

    content {
      resources = ["secrets"]

      provider {
        key_arn = var.encryption_kms_key_arn
      }
    }
  }

  tags = var.tags

  depends_on = [aws_iam_role_policy_attachment.cluster]
}

# ---------------------------------------------------------------------------
# Access entries. The node roles must be admitted before their instances can
# register; the RBAC principals map onto the Kubernetes groups flux-manifests'
# rbac component binds.
# ---------------------------------------------------------------------------

resource "aws_eks_access_entry" "nodes" {
  cluster_name  = aws_eks_cluster.main.name
  principal_arn = aws_iam_role.nodes.arn
  type          = "EC2_LINUX"

  tags = var.tags
}

resource "aws_eks_access_entry" "cluster_admins" {
  for_each = var.cluster_admin_principals

  cluster_name  = aws_eks_cluster.main.name
  principal_arn = each.value
  type          = "STANDARD"

  tags = var.tags
}

resource "aws_eks_access_policy_association" "cluster_admins" {
  for_each = aws_eks_access_entry.cluster_admins

  cluster_name  = aws_eks_cluster.main.name
  principal_arn = each.value.principal_arn
  policy_arn    = "arn:${local.partition}:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"

  access_scope {
    type = "cluster"
  }
}

locals {
  # role key -> { principal_arn, group }, empty unless rbac.enabled. The group
  # names (not the ARNs) are what reach flux-manifests as RBAC_GROUP_*, so the
  # manifests contract is identical to the GKE clusters' — only the subject
  # type behind it differs.
  rbac_roles = var.rbac.enabled ? {
    for role, subject in var.rbac.groups : role => subject if subject != null
  } : {}
}

resource "aws_eks_access_entry" "rbac" {
  for_each = local.rbac_roles

  cluster_name      = aws_eks_cluster.main.name
  principal_arn     = each.value.principal_arn
  kubernetes_groups = [each.value.group]
  type              = "STANDARD"

  tags = var.tags
}

# ---------------------------------------------------------------------------
# The always-on system node group: flux controllers, kyverno, cert-manager,
# karpenter and the other platform components pin here via nodeSelector
# role=system, away from Karpenter's workload capacity.
# ---------------------------------------------------------------------------

resource "aws_eks_node_group" "system" {
  cluster_name    = aws_eks_cluster.main.name
  node_group_name = "system"
  node_role_arn   = aws_iam_role.nodes.arn
  subnet_ids      = var.network.node_subnet_ids

  instance_types = var.system_node_pool.instance_types
  capacity_type  = var.system_node_pool.capacity_type
  disk_size      = var.system_node_pool.disk_size_gib

  scaling_config {
    # Cluster-wide totals, unlike GKE's per-zone regional pool counts.
    min_size     = var.system_node_pool.min_size
    max_size     = var.system_node_pool.max_size
    desired_size = var.system_node_pool.desired_size
  }

  labels = local.system_node_selector

  # Nothing schedules here until Cilium can give it an address. The Cilium
  # agent and operator tolerate all taints, and the operator removes this one
  # once the agent is ready (operator.removeNodeTaints, on by default), so it
  # gates workloads without gating the CNI that clears it.
  taint {
    key    = "node.cilium.io/agent-not-ready"
    value  = "true"
    effect = "NO_EXECUTE"
  }

  # The analogue of GKE's management { auto_repair = true }; the health signals
  # come from the eks-node-monitoring-agent add-on.
  node_repair_config {
    enabled = true
  }

  update_config {
    max_unavailable = 1
  }

  tags = var.tags

  lifecycle {
    # The desired count is Kubernetes' to move once the cluster is live;
    # terraform sets the initial size and then stops arguing about it.
    ignore_changes = [scaling_config[0].desired_size]
  }

  # Cilium must be installed BEFORE the first node registers: otherwise nodes
  # sit NotReady with an uninitialized CNI and the node group create fails with
  # NodeCreationFailure.
  depends_on = [
    helm_release.cilium,
    aws_eks_access_entry.nodes,
    aws_iam_role_policy_attachment.nodes,
    aws_iam_role_policy.cilium_eni,
  ]
}

# ---------------------------------------------------------------------------
# Add-ons. Everything AWS manages, taken managed. Ordered after the node group
# because an add-on reports ACTIVE only once its pods are healthy, and the
# pod-identity-agent goes first because every other IAM-bearing add-on and
# workload resolves credentials through it.
# ---------------------------------------------------------------------------

resource "aws_eks_addon" "pod_identity_agent" {
  count = contains(keys(local.addons), "eks-pod-identity-agent") ? 1 : 0

  cluster_name  = aws_eks_cluster.main.name
  addon_name    = "eks-pod-identity-agent"
  addon_version = local.addons["eks-pod-identity-agent"].version

  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "PRESERVE"

  configuration_values = local.addons["eks-pod-identity-agent"].configuration_values

  tags = var.tags

  depends_on = [aws_eks_node_group.system]
}

resource "aws_eks_addon" "main" {
  for_each = { for name, addon in local.addons : name => addon if name != "eks-pod-identity-agent" }

  cluster_name  = aws_eks_cluster.main.name
  addon_name    = each.key
  addon_version = each.value.version

  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "PRESERVE"

  # coredns is pinned to the system pool the same way every other platform
  # component is; anything else takes the add-on's own defaults unless the
  # caller overrides them.
  configuration_values = (
    each.value.configuration_values != null
    ? each.value.configuration_values
    : (each.key == "coredns" ? jsonencode({ nodeSelector = local.system_node_selector }) : null)
  )

  tags = var.tags

  depends_on = [
    aws_eks_node_group.system,
    aws_eks_addon.pod_identity_agent,
  ]
}
