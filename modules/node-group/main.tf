# Copyright 2026 BitWise Media Group Ltd
# SPDX-License-Identifier: MIT

# One EKS managed node group behind a module-owned launch template. The launch
# template exists for what the managed-node-group API alone cannot express:
# extra security groups on the nodes (attached alongside the EKS-managed
# cluster group, which must always ride along for control-plane reachability)
# and the root volume's size/type. Everything the API can express directly
# (instance types, capacity type, scaling, labels, taints) stays on the node
# group resource.

locals {
  windows = var.ami_type != null && startswith(var.ami_type, "WINDOWS_")

  # EKS picks the AMI for the ami_type, so the block-device mapping must name
  # that family's root device rather than discovering it.
  root_device_name = local.windows ? "/dev/sda1" : "/dev/xvda"
}

resource "aws_launch_template" "main" {
  name_prefix = "${var.cluster_name}-${var.name}-"

  vpc_security_group_ids = setunion([var.cluster_security_group_id], var.security_group_ids)

  block_device_mappings {
    device_name = local.root_device_name

    ebs {
      volume_size           = var.disk_size_gib
      volume_type           = "gp3"
      delete_on_termination = true
    }
  }

  # IMDSv2 only; the hop limit of 2 matches the EKS default so containerised
  # callers (one hop through the bridge) can still reach the node's metadata.
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 2
  }

  dynamic "tag_specifications" {
    for_each = toset(["instance", "volume"])

    content {
      resource_type = tag_specifications.value
      tags          = merge({ Name = "${var.cluster_name}-${var.name}" }, var.tags)
    }
  }

  tags = var.tags

  # No create_before_destroy here or on the node group below: see the node
  # group's lifecycle block for why.
}

resource "aws_eks_node_group" "main" {
  cluster_name           = var.cluster_name
  node_group_name_prefix = "${var.name}-"
  node_role_arn          = var.node_role_arn
  subnet_ids             = var.subnet_ids

  instance_types = var.instance_types
  capacity_type  = var.capacity_type
  ami_type       = var.ami_type

  launch_template {
    id      = aws_launch_template.main.id
    version = aws_launch_template.main.latest_version
  }

  scaling_config {
    # Cluster-wide totals, not per-zone counts.
    min_size     = var.min_size
    max_size     = var.max_size
    desired_size = var.desired_size
  }

  labels = var.labels

  dynamic "taint" {
    for_each = var.taints

    content {
      key    = taint.value.key
      value  = taint.value.value
      effect = taint.value.effect
    }
  }

  # Node auto-repair; the health signals come from the
  # eks-node-monitoring-agent add-on.
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

    # Deliberately NOT create_before_destroy, here or on the launch template.
    # Terraform forces create_before_destroy onto every dependency of a
    # resource that sets it, and this group depends on the cluster, whose name
    # is fixed - a cluster replacement would then try to create the successor
    # before destroying the original and fail with "Cluster already exists
    # with name". A node group replacement is therefore destroy-then-create
    # (a capacity gap for the rare forced replacement). name_prefix stays:
    # moving to a fixed name would itself replace every existing group.
  }
}
