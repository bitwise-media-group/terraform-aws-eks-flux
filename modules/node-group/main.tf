# Copyright 2026 BitWise Media Group Ltd
# SPDX-License-Identifier: MIT

# One EKS managed node group behind a module-owned launch template. The launch
# template exists for what the managed-node-group API alone cannot express:
# extra security groups on the nodes (attached alongside the EKS-managed
# cluster group, which must always ride along for control-plane reachability)
# and the root volume's size/type. Everything the API can express directly
# (instance types, capacity type, scaling, labels, taints) stays on the node
# group resource. The one exception is a custom AMI (var.ami): the launch
# template then names the image and carries the bootstrap user data EKS no
# longer merges in.

locals {
  windows    = var.ami_type != null && startswith(var.ami_type, "WINDOWS_")
  custom_ami = var.ami != null

  # Nothing schedules on a new Linux node until Cilium can give it an address.
  # The Cilium agent and operator tolerate all taints, and the operator removes
  # this one once the agent is ready (operator.removeNodeTaints, on by
  # default), so it gates workloads without gating the CNI that clears it.
  # Windows nodes never carry it: Cilium has no Windows datapath, so the taint
  # would sit unremoved and the group would never schedule a pod.
  taints = concat(
    var.cilium_agent_taint && !local.windows ? [{
      key    = "node.cilium.io/agent-not-ready"
      value  = "true"
      effect = "NO_EXECUTE"
    }] : [],
    var.taints,
  )

  # EKS picks the AMI for the ami_type, so the block-device mapping must name
  # that family's root device rather than discovering it. A custom image is
  # resolved here, so its own root device is read off the image instead.
  root_device_name = local.custom_ami ? data.aws_ami.custom[0].root_device_name : (local.windows ? "/dev/sda1" : "/dev/xvda")

  # The kubelet registers the group's labels and taints itself on a custom
  # image: EKS's own bootstrap (which does this for its AMIs) is not merged in,
  # and the Cilium agent-not-ready taint must be on the node from the moment it
  # registers, not applied after pods have already landed.
  kubelet_taint_effects = {
    NO_SCHEDULE        = "NoSchedule"
    NO_EXECUTE         = "NoExecute"
    PREFER_NO_SCHEDULE = "PreferNoSchedule"
  }

  kubelet_flags = concat(
    length(var.labels) > 0 ? ["--node-labels=${join(",", [for key, value in var.labels : "${key}=${value}"])}"] : [],
    length(local.taints) > 0 ? ["--register-with-taints=${join(",", [
      for taint in local.taints : "${taint.key}${taint.value == null ? "" : "=${taint.value}"}:${local.kubelet_taint_effects[taint.effect]}"
    ])}"] : [],
  )

  node_config = {
    apiVersion = "node.eks.aws/v1alpha1"
    kind       = "NodeConfig"
    spec = merge(
      {
        cluster = {
          name                 = var.cluster_name
          apiServerEndpoint    = var.cluster_endpoint
          certificateAuthority = var.cluster_certificate_authority
          cidr                 = var.cluster_service_cidr
        }
      },
      length(local.kubelet_flags) > 0 ? { kubelet = { flags = local.kubelet_flags } } : {},
    )
  }

  user_data = local.custom_ami ? base64encode(templatefile("${path.module}/user-data.tftpl", {
    node_config = yamlencode(local.node_config)
    parts       = var.ami.user_data_parts
  })) : null
}

# The custom image, resolved at plan time. owners applies to an explicit id
# too, so an id from an unexpected account matches nothing and fails the plan
# rather than launching an untrusted image.
data "aws_ami" "custom" {
  count = local.custom_ami ? 1 : 0

  owners      = var.ami.owners
  most_recent = true

  filter {
    name   = "state"
    values = ["available"]
  }

  dynamic "filter" {
    for_each = var.ami.id != null ? [var.ami.id] : []

    content {
      name   = "image-id"
      values = [filter.value]
    }
  }

  dynamic "filter" {
    for_each = var.ami.name != null ? [replace(var.ami.name, "{kubernetes_version}", coalesce(var.kubernetes_version, "{kubernetes_version}"))] : []

    content {
      name   = "name"
      values = [filter.value]
    }
  }
}

# Which kind of image the group runs. EKS cannot move a node group between an
# EKS AMI and a custom one in place, and ami_type going null (it is
# optional+computed) produces no diff of its own - so the node group is
# replaced whenever this flips.
resource "terraform_data" "ami_mode" {
  input = local.custom_ami ? "custom" : "eks"
}

resource "aws_launch_template" "main" {
  name_prefix = "${var.cluster_name}-${var.name}-"

  image_id  = local.custom_ami ? data.aws_ami.custom[0].id : null
  user_data = local.user_data

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

  # EKS refuses an AMI type alongside a launch template that names its own
  # image (the group then reports CUSTOM).
  ami_type = local.custom_ami ? null : var.ami_type

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
    for_each = local.taints

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

    # Moving between an EKS AMI and a custom one cannot happen in place; see
    # terraform_data.ami_mode.
    replace_triggered_by = [terraform_data.ami_mode]

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
