# Copyright 2026 BitWise Media Group Ltd
# SPDX-License-Identifier: MIT

# Plan-time contract tests with a mocked provider: the launch-template wiring
# (cluster security group always attached, root device per OS family, IMDSv2),
# the node-group shape (scaling, labels, taints, auto-repair) and custom AMIs
# (owner-pinned lookup, the rendered nodeadm bootstrap, no EKS AMI type).

mock_provider "aws" {}

variables {
  cluster_name              = "patchy-x"
  name                      = "workers"
  node_role_arn             = "arn:aws:iam::123456789012:role/patchy-x-nodes"
  subnet_ids                = ["subnet-0aaa", "subnet-0bbb"]
  cluster_security_group_id = "sg-0cluster"
}

run "launch_template_wiring" {
  command = plan

  variables {
    security_group_ids = ["sg-0extra"]
  }

  assert {
    condition     = aws_launch_template.main.vpc_security_group_ids == toset(["sg-0cluster", "sg-0extra"])
    error_message = "extra security groups must attach alongside the cluster security group, never instead of it"
  }

  assert {
    condition     = aws_launch_template.main.block_device_mappings[0].device_name == "/dev/xvda"
    error_message = "Linux AMI families root on /dev/xvda; the disk size must land on that device"
  }

  assert {
    condition     = aws_launch_template.main.block_device_mappings[0].ebs[0].volume_size == 50 && aws_launch_template.main.block_device_mappings[0].ebs[0].volume_type == "gp3"
    error_message = "the root volume must be gp3 at the configured size"
  }

  assert {
    condition     = aws_launch_template.main.metadata_options[0].http_tokens == "required"
    error_message = "IMDSv2 must be enforced on every node"
  }

  assert {
    condition     = aws_eks_node_group.main.node_group_name_prefix == "workers-"
    error_message = "the node group name must be a prefix so a replacement never collides with the group it supersedes"
  }

  assert {
    condition     = aws_launch_template.main.image_id == null && aws_launch_template.main.user_data == null
    error_message = "an EKS AMI group must leave the image and the bootstrap to EKS"
  }

  assert {
    condition     = length(data.aws_ami.custom) == 0 && terraform_data.ami_mode.input == "eks"
    error_message = "no custom image is looked up unless ami is set"
  }
}

run "windows_node_group" {
  command = plan

  variables {
    ami_type = "WINDOWS_CORE_2022_x86_64"
  }

  assert {
    condition     = aws_eks_node_group.main.ami_type == "WINDOWS_CORE_2022_x86_64"
    error_message = "the ami_type must pass through to the node group"
  }

  assert {
    condition     = aws_launch_template.main.block_device_mappings[0].device_name == "/dev/sda1"
    error_message = "Windows AMIs root on /dev/sda1; sizing /dev/xvda would add a second, unused volume"
  }
}

run "node_group_shape" {
  command = plan

  variables {
    min_size     = 1
    max_size     = 6
    desired_size = 3
    labels       = { role = "workers" }
    taints = [
      { key = "node.cilium.io/agent-not-ready", value = "true", effect = "NO_EXECUTE" },
    ]
  }

  assert {
    condition     = aws_eks_node_group.main.scaling_config[0].min_size == 1 && aws_eks_node_group.main.scaling_config[0].max_size == 6 && aws_eks_node_group.main.scaling_config[0].desired_size == 3
    error_message = "the scaling config must carry the configured cluster-wide totals"
  }

  assert {
    condition     = aws_eks_node_group.main.labels["role"] == "workers"
    error_message = "labels must pass through to the nodes"
  }

  assert {
    condition = one([
      for taint in aws_eks_node_group.main.taint :
      taint if taint.key == "node.cilium.io/agent-not-ready" && taint.effect == "NO_EXECUTE"
    ]) != null
    error_message = "taints must pass through to the nodes"
  }

  assert {
    condition     = aws_eks_node_group.main.node_repair_config[0].enabled == true
    error_message = "node auto-repair must be on"
  }

  assert {
    condition     = aws_eks_node_group.main.update_config[0].max_unavailable == 1
    error_message = "rolling updates must take nodes one at a time"
  }
}

run "bottlerocket_is_rejected" {
  command = plan

  variables {
    ami_type = "BOTTLEROCKET_x86_64"
  }

  expect_failures = [var.ami_type]
}

run "invalid_taint_effect_is_rejected" {
  command = plan

  variables {
    taints = [
      { key = "dedicated", value = "gpu", effect = "NoSchedule" },
    ]
  }

  expect_failures = [var.taints]
}

# --- Custom AMIs --------------------------------------------------------------

run "custom_ami_by_id" {
  command = plan

  override_data {
    target = data.aws_ami.custom[0]
    values = {
      id               = "ami-0golden"
      root_device_name = "/dev/nvme0n1"
    }
  }

  variables {
    ami = {
      owners = ["111122223333"]
      id     = "ami-0golden"
    }
    cluster_endpoint              = "https://ABC.gr7.eu-west-2.eks.amazonaws.com"
    cluster_certificate_authority = "Q0EtREFUQQ=="
    cluster_service_cidr          = "172.20.0.0/16"
    labels                        = { role = "system" }
    taints = [
      { key = "node.cilium.io/agent-not-ready", value = "true", effect = "NO_EXECUTE" },
      { key = "dedicated", effect = "NO_SCHEDULE" },
    ]
  }

  assert {
    condition     = data.aws_ami.custom[0].owners == tolist(["111122223333"]) && contains([for f in data.aws_ami.custom[0].filter : f.name if f.values == toset(["ami-0golden"])], "image-id")
    error_message = "an explicit id must still be looked up against the pinned owners"
  }

  assert {
    condition     = aws_launch_template.main.image_id == "ami-0golden"
    error_message = "the launch template must name the custom image"
  }

  assert {
    condition     = aws_launch_template.main.block_device_mappings[0].device_name == "/dev/nvme0n1"
    error_message = "a custom image's root device must be read off the image, not assumed"
  }

  assert {
    condition     = terraform_data.ami_mode.input == "custom"
    error_message = "the AMI mode must flip to custom so switching image kinds replaces the group"
  }

  assert {
    condition     = strcontains(base64decode(aws_launch_template.main.user_data), "\"kind\": \"NodeConfig\"") && strcontains(base64decode(aws_launch_template.main.user_data), "\"apiServerEndpoint\": \"https://ABC.gr7.eu-west-2.eks.amazonaws.com\"") && strcontains(base64decode(aws_launch_template.main.user_data), "\"cidr\": \"172.20.0.0/16\"")
    error_message = "the user data must carry the nodeadm NodeConfig with the cluster's bootstrap facts"
  }

  assert {
    condition     = strcontains(base64decode(aws_launch_template.main.user_data), "--register-with-taints=node.cilium.io/agent-not-ready=true:NoExecute,dedicated:NoSchedule")
    error_message = "the kubelet must register the group's taints itself, in kubelet effect syntax"
  }

  assert {
    condition     = strcontains(base64decode(aws_launch_template.main.user_data), "--node-labels=role=system")
    error_message = "the kubelet must register the group's labels itself"
  }

  assert {
    condition     = output.ami_id == "ami-0golden"
    error_message = "the resolved image id must be published"
  }
}

run "custom_ami_by_name" {
  command = plan

  variables {
    ami = {
      owners = ["111122223333", "self"]
      name   = "acme-eks-{kubernetes_version}-*"
      user_data_parts = [
        { content = "apiVersion: node.eks.aws/v1alpha1\nkind: NodeConfig\nspec:\n  kubelet:\n    config:\n      maxPods: 110\n" },
        { content_type = "text/x-shellscript", content = "#!/bin/sh\necho hello\n" },
      ]
    }
    kubernetes_version            = "1.33"
    cluster_endpoint              = "https://ABC.gr7.eu-west-2.eks.amazonaws.com"
    cluster_certificate_authority = "Q0EtREFUQQ=="
    cluster_service_cidr          = "172.20.0.0/16"
  }

  assert {
    condition     = contains([for f in data.aws_ami.custom[0].filter : f.name if f.values == toset(["acme-eks-1.33-*"])], "name")
    error_message = "the name filter must have {kubernetes_version} replaced by the cluster version"
  }

  assert {
    condition     = data.aws_ami.custom[0].most_recent == true
    error_message = "a name filter must take the newest matching image"
  }

  assert {
    condition     = length(regexall("(?m)^--//$", base64decode(aws_launch_template.main.user_data))) == 3 && strcontains(base64decode(aws_launch_template.main.user_data), "Content-Type: text/x-shellscript\n\n#!/bin/sh\necho hello\n")
    error_message = "user_data_parts must follow the module's NodeConfig as their own MIME parts"
  }

  assert {
    condition     = strcontains(base64decode(aws_launch_template.main.user_data), "Content-Type: application/node.eks.aws\n\napiVersion: node.eks.aws/v1alpha1\nkind: NodeConfig\nspec:\n  kubelet:")
    error_message = "a part with no content type must default to an extra nodeadm NodeConfig"
  }

  assert {
    condition     = !strcontains(base64decode(aws_launch_template.main.user_data), "--node-labels") && !strcontains(base64decode(aws_launch_template.main.user_data), "--register-with-taints")
    error_message = "no kubelet flags are rendered for a group without labels or taints"
  }
}

run "custom_ami_rejects_ami_type" {
  command = plan

  variables {
    ami                           = { owners = ["111122223333"], id = "ami-0golden" }
    ami_type                      = "AL2023_x86_64_STANDARD"
    cluster_endpoint              = "https://ABC.gr7.eu-west-2.eks.amazonaws.com"
    cluster_certificate_authority = "Q0EtREFUQQ=="
    cluster_service_cidr          = "172.20.0.0/16"
  }

  expect_failures = [var.ami]
}

run "custom_ami_rejects_id_and_name" {
  command = plan

  variables {
    ami                           = { owners = ["111122223333"], id = "ami-0golden", name = "acme-*" }
    cluster_endpoint              = "https://ABC.gr7.eu-west-2.eks.amazonaws.com"
    cluster_certificate_authority = "Q0EtREFUQQ=="
    cluster_service_cidr          = "172.20.0.0/16"
  }

  expect_failures = [var.ami]
}

run "custom_ami_rejects_neither_id_nor_name" {
  command = plan

  variables {
    ami                           = { owners = ["111122223333"] }
    cluster_endpoint              = "https://ABC.gr7.eu-west-2.eks.amazonaws.com"
    cluster_certificate_authority = "Q0EtREFUQQ=="
    cluster_service_cidr          = "172.20.0.0/16"
  }

  expect_failures = [var.ami]
}

run "custom_ami_rejects_empty_owners" {
  command = plan

  variables {
    ami                           = { owners = [], id = "ami-0golden" }
    cluster_endpoint              = "https://ABC.gr7.eu-west-2.eks.amazonaws.com"
    cluster_certificate_authority = "Q0EtREFUQQ=="
    cluster_service_cidr          = "172.20.0.0/16"
  }

  expect_failures = [var.ami]
}

run "custom_ami_requires_bootstrap_facts" {
  command = plan

  variables {
    ami = { owners = ["111122223333"], name = "acme-eks-{kubernetes_version}-*" }
  }

  expect_failures = [
    var.kubernetes_version,
    var.cluster_endpoint,
    var.cluster_certificate_authority,
    var.cluster_service_cidr,
  ]
}

run "custom_ami_rejects_restricted_labels" {
  command = plan

  variables {
    ami                           = { owners = ["111122223333"], id = "ami-0golden" }
    cluster_endpoint              = "https://ABC.gr7.eu-west-2.eks.amazonaws.com"
    cluster_certificate_authority = "Q0EtREFUQQ=="
    cluster_service_cidr          = "172.20.0.0/16"
    labels                        = { "node-role.kubernetes.io/system" = "" }
  }

  expect_failures = [var.labels]
}

run "custom_ami_allows_kubelet_settable_labels" {
  command = plan

  override_data {
    target = data.aws_ami.custom[0]
    values = {
      id               = "ami-0golden"
      root_device_name = "/dev/xvda"
    }
  }

  variables {
    ami                           = { owners = ["111122223333"], id = "ami-0golden" }
    cluster_endpoint              = "https://ABC.gr7.eu-west-2.eks.amazonaws.com"
    cluster_certificate_authority = "Q0EtREFUQQ=="
    cluster_service_cidr          = "172.20.0.0/16"
    labels                        = { "node.kubernetes.io/pool" = "golden", "example.com/team" = "platform" }
  }

  assert {
    condition     = aws_eks_node_group.main.labels["node.kubernetes.io/pool"] == "golden"
    error_message = "node.kubernetes.io/ labels are kubelet-settable and must be accepted"
  }
}
