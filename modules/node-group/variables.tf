# Copyright 2026 BitWise Media Group Ltd
# SPDX-License-Identifier: MIT

variable "cluster_name" {
  description = "Name of the EKS cluster the node group joins."
  type        = string
  nullable    = false
}

variable "name" {
  description = <<-EOT
    Node group name stem. Used as a name prefix, so a replacement never collides with the group it supersedes.
  EOT
  type        = string
  nullable    = false

  validation {
    condition     = can(regex("^[a-z]([a-z0-9-]{0,36})$", var.name))
    error_message = "name must be a short lowercase RFC-1035 label (it prefixes the node group and launch template names)."
  }
}

variable "node_role_arn" {
  description = <<-EOT
    IAM role the nodes run as. Its access entry type (EC2_LINUX / EC2_WINDOWS) must match ami_type's OS family.
  EOT
  type        = string
  nullable    = false
}

variable "subnet_ids" {
  description = "Subnets the nodes launch into."
  type        = set(string)
  nullable    = false

  validation {
    condition     = length(var.subnet_ids) > 0
    error_message = "subnet_ids must name at least one subnet."
  }
}

variable "cluster_security_group_id" {
  description = <<-EOT
    The EKS-managed cluster security group. Always attached - without it nodes cannot reach the control plane.
  EOT
  type        = string
  nullable    = false
}

variable "security_group_ids" {
  description = "Additional security groups the launch template attaches alongside the cluster security group."
  type        = set(string)
  nullable    = false
  default     = []
}

variable "instance_types" {
  description = "Instance types the node group launches, in preference order."
  type        = list(string)
  nullable    = false
  default     = ["m7i.large"]
}

variable "capacity_type" {
  description = "ON_DEMAND or SPOT capacity."
  type        = string
  nullable    = false
  default     = "ON_DEMAND"

  validation {
    condition     = contains(["ON_DEMAND", "SPOT"], var.capacity_type)
    error_message = "capacity_type must be ON_DEMAND or SPOT."
  }
}

variable "min_size" {
  description = "Minimum node count (cluster-wide total, not per-zone)."
  type        = number
  nullable    = false
  default     = 2
}

variable "max_size" {
  description = "Maximum node count (cluster-wide total, not per-zone)."
  type        = number
  nullable    = false
  default     = 4
}

variable "desired_size" {
  description = <<-EOT
    Initial node count. Set once at create and never argued about again (ignore_changes) - the count is Kubernetes' to
    move on a live cluster.
  EOT
  type        = number
  nullable    = false
  default     = 2
}

variable "disk_size_gib" {
  description = "Root volume size in GiB (gp3), set through the launch template."
  type        = number
  nullable    = false
  default     = 50
}

variable "ami_type" {
  description = <<-EOT
    EKS AMI type. Null takes the EKS default for the instance architecture (AL2023). WINDOWS_* types launch Windows
    nodes - pair them with a node role admitted through an EC2_WINDOWS access entry. Bottlerocket is deliberately
    unsupported: its two-volume layout (a separate data volume) does not fit the single root device this module's
    launch template sizes.
  EOT
  type        = string
  nullable    = true
  default     = null

  validation {
    condition     = var.ami_type == null || can(regex("^(AL2023_|WINDOWS_)", var.ami_type))
    error_message = "ami_type must be an AL2023_* or WINDOWS_* EKS AMI type (or null for the EKS default)."
  }
}

variable "ami" {
  description = <<-EOT
    A custom AL2023 AMI in place of the EKS-published one picked by ami_type (the two are mutually exclusive). The
    image is resolved at plan time and must be owned by one of owners (account ids, or self / amazon /
    aws-marketplace) - this check also applies to an explicit id, so an image from an unexpected account fails the plan.
    Set exactly one of:
      - id: the exact image id. Pins the image - nodes only roll when the id changes.
      - name: an EC2 name filter (* wildcards), with the newest match taking effect. "{kubernetes_version}" is
        replaced by kubernetes_version, so a pattern such as "acme-eks-{kubernetes_version}-*" follows the
        cluster through upgrades. A newer matching image produces a new launch template version - and a rolling node
        update - on the next apply.
    EKS merges no bootstrap user data into a custom image, so the module renders it: a nodeadm NodeConfig (cluster
    endpoint, certificate authority and service CIDR) whose kubelet flags register the group's labels and taints, so
    a taint such as Cilium's agent-not-ready is present the moment the node registers. user_data_parts are appended
    to that MIME document - extra NodeConfigs (application/node.eks.aws, merged by nodeadm) or any content type
    cloud-init understands (text/x-shellscript, text/cloud-config, ...).
    Switching between an EKS AMI and a custom one replaces the node group (destroy-then-create).
  EOT
  type = object({
    owners = list(string)
    id     = optional(string)
    name   = optional(string)
    user_data_parts = optional(list(object({
      content_type = optional(string, "application/node.eks.aws")
      content      = string
    })), [])
  })
  nullable = true
  default  = null

  validation {
    condition     = var.ami == null || length(coalesce(try(var.ami.owners, null), [])) > 0
    error_message = "ami.owners must name at least one owner - an AMI is only trusted when its owner is pinned."
  }

  validation {
    condition     = var.ami == null || (try(var.ami.id, null) == null) != (try(var.ami.name, null) == null)
    error_message = "ami must set exactly one of id or name."
  }

  validation {
    condition     = var.ami == null || var.ami_type == null
    error_message = "ami and ami_type are mutually exclusive - a custom AMI carries no EKS AMI type."
  }
}

variable "kubernetes_version" {
  description = <<-EOT
    The cluster's Kubernetes version (e.g. "1.33"), substituted for "{kubernetes_version}" in ami.name. Required only
    when ami.name uses the placeholder.
  EOT
  type        = string
  nullable    = true
  default     = null

  validation {
    condition     = var.kubernetes_version != null || !strcontains(try(var.ami.name, null) == null ? "" : var.ami.name, "{kubernetes_version}")
    error_message = "kubernetes_version is required when ami.name uses the {kubernetes_version} placeholder."
  }
}

variable "cluster_endpoint" {
  description = "The cluster's API server endpoint, rendered into a custom AMI's NodeConfig. Required when ami is set."
  type        = string
  nullable    = true
  default     = null

  validation {
    condition     = var.ami == null || var.cluster_endpoint != null
    error_message = "cluster_endpoint is required when ami is set - a custom AMI's nodes bootstrap from the module-rendered NodeConfig."
  }
}

variable "cluster_certificate_authority" {
  description = <<-EOT
    The cluster's base64-encoded certificate authority data, rendered into a custom AMI's NodeConfig. Required when ami
    is set.
  EOT
  type        = string
  nullable    = true
  default     = null

  validation {
    condition     = var.ami == null || var.cluster_certificate_authority != null
    error_message = "cluster_certificate_authority is required when ami is set - a custom AMI's nodes bootstrap from the module-rendered NodeConfig."
  }
}

variable "cluster_service_cidr" {
  description = "The cluster's Kubernetes service CIDR, rendered into a custom AMI's NodeConfig. Required when ami is set."
  type        = string
  nullable    = true
  default     = null

  validation {
    condition     = var.ami == null || var.cluster_service_cidr != null
    error_message = "cluster_service_cidr is required when ami is set - a custom AMI's nodes bootstrap from the module-rendered NodeConfig."
  }
}

variable "labels" {
  description = <<-EOT
    Kubernetes labels applied to every node in the group. With a custom ami the kubelet also registers them itself, so
    keys in the kubernetes.io / k8s.io namespaces are refused (the NodeRestriction admission plugin stops a kubelet
    from self-applying them) - except node.kubernetes.io/ and kubelet.kubernetes.io/, which it allows.
  EOT
  type        = map(string)
  nullable    = false
  default     = {}

  validation {
    condition = var.ami == null || alltrue([
      for key in keys(var.labels) :
      !can(regex("(^|\\.)(kubernetes|k8s)\\.io/", key)) || can(regex("^([a-z0-9.-]+\\.)?(kubelet|node)\\.kubernetes\\.io/", key))
    ])
    error_message = "With a custom ami, labels must not use the kubernetes.io or k8s.io namespaces (other than node.kubernetes.io/ and kubelet.kubernetes.io/) - the kubelet cannot self-apply them."
  }
}

variable "taints" {
  description = "Kubernetes taints applied to every node in the group."
  type = list(object({
    key    = string
    value  = optional(string)
    effect = string
  }))
  nullable = false
  default  = []

  validation {
    condition = alltrue([
      for taint in var.taints : contains(["NO_SCHEDULE", "NO_EXECUTE", "PREFER_NO_SCHEDULE"], taint.effect)
    ])
    error_message = "Each taint effect must be NO_SCHEDULE, NO_EXECUTE or PREFER_NO_SCHEDULE."
  }
}

variable "tags" {
  description = <<-EOT
    Tags applied to every resource this module creates (and, via the launch template, to the instances and volumes).
  EOT
  type        = map(string)
  nullable    = false
  default     = {}
}
