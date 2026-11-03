# Copyright 2026 BitWise Media Group Ltd
# SPDX-License-Identifier: MIT

output "name" {
  description = "The node group's actual name (the name stem plus the generated suffix)."
  value       = aws_eks_node_group.main.node_group_name
}

output "arn" {
  description = "Node group ARN."
  value       = aws_eks_node_group.main.arn
}

output "labels" {
  description = "Kubernetes labels every node in the group carries - the selectors workloads pin with."
  value       = aws_eks_node_group.main.labels
}

output "taints" {
  description = "Kubernetes taints every node in the group carries."
  value       = aws_eks_node_group.main.taint
}

output "security_group_ids" {
  description = "Security groups the launch template attaches to the nodes (the cluster security group plus any extras)."
  value       = aws_launch_template.main.vpc_security_group_ids
}

output "launch_template" {
  description = "The module-owned launch template behind the node group (id and current version)."
  value = {
    id      = aws_launch_template.main.id
    version = aws_launch_template.main.latest_version
  }
}

output "ami_id" {
  description = "The custom AMI the group runs (ami), resolved to its image id; null when EKS picks the AMI for ami_type."
  value       = local.custom_ami ? data.aws_ami.custom[0].id : null
}
