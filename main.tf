# Copyright 2026 BitWise Media Group Ltd
# SPDX-License-Identifier: MIT

# A minimum-viable EKS cluster for the flux-operator platform: Cilium in ENI
# mode with the AWS VPC CNI never installed, kube-proxy replaced by Cilium's
# eBPF datapath, EKS Pod Identity for workload IAM, a small always-on system
# node group for platform controllers (label role=system) and Karpenter for
# everything else.
#
# EKS delegates DNS, metrics and CSI to add-ons - so everything AWS offers
# managed is taken managed (see var.addons) and only the rest reaches the
# cluster through flux.
#
# BOOTSTRAP ORDER is the constraint everything in this file exists to uphold. A node cannot
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

  # Every repository beneath the platform prefix, in the registry's own
  # account - which is the cluster's account when platform_registry is a
  # pull-through cache, and the store's account when it is read directly.
  registry_arn = "arn:${local.partition}:ecr:${local.registry_region}:${local.registry_owner}:repository/${local.registry_prefix}/*"

  addons = { for name, addon in var.addons : name => addon if addon.enabled }

  # Per-add-on configuration applied when the caller passes none of their own.
  # coredns is pinned to the system pool the same way every other platform
  # component is. The secrets provider must delegate file writes to the CSI
  # driver: the podless SecretSync flow (the secret-sync flux component this
  # module's stack depends on) mounts through a fake target path that exists
  # in no filesystem, so a provider that writes the files itself - its
  # default - fails every sync with "open /mnt/secrets-store/<path>: no such
  # file or directory". driverWritesSecrets makes it return the files over
  # gRPC instead, which serves real CSI mounts and the sync controller alike.
  addon_configuration_defaults = {
    coredns                               = jsonencode({ nodeSelector = local.system_node_selector })
    aws-secrets-store-csi-driver-provider = jsonencode({ driverWritesSecrets = true })
  }
}

# ---------------------------------------------------------------------------
# The node IAM roles. The Linux role is shared by every Linux node group and
# (via karpenter.tf's own role) the shape Karpenter nodes take. Windows node
# groups get their own role on demand: an IAM principal carries exactly one
# EKS access entry, and Windows nodes join through EC2_WINDOWS while Linux
# nodes join through EC2_LINUX.
# ---------------------------------------------------------------------------

locals {
  node_managed_policies = [
    "arn:${local.partition}:iam::aws:policy/AmazonEKSWorkerNodePolicy",
    # PullOnly, not the older ReadOnly: nodes never write to the registry.
    "arn:${local.partition}:iam::aws:policy/AmazonEC2ContainerRegistryPullOnly",
    # Session Manager access for break-glass, without opening SSH anywhere.
    "arn:${local.partition}:iam::aws:policy/AmazonSSMManagedInstanceCore",
  ]

  windows_node_groups = {
    for name, group in var.node_groups : name => group
    if group.ami_type != null && startswith(group.ami_type, "WINDOWS_")
  }
  windows_nodes_enabled = length(local.windows_node_groups) > 0
}

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
  name_prefix        = "${var.name}-nodes-"
  description        = "EKS nodes (${var.name}) - kubelet, ECR pulls and the Cilium ENI datapath"
  assume_role_policy = data.aws_iam_policy_document.node_assume_role.json

  tags = var.tags

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_iam_role_policy_attachment" "nodes" {
  for_each = toset(local.node_managed_policies)

  role       = aws_iam_role.nodes.name
  policy_arn = each.value
}

# Deliberately NOT AmazonEKS_CNI_Policy: that is the AWS VPC CNI's grant, and
# the VPC CNI is never installed here. Cilium's equivalent lives in cilium.tf.

resource "aws_iam_instance_profile" "nodes" {
  name_prefix = "${var.name}-nodes-"
  role        = aws_iam_role.nodes.name

  tags = var.tags

  lifecycle {
    create_before_destroy = true
  }
}

# The Windows role carries the same managed policies but never the Cilium ENI
# grant: Cilium has no Windows datapath, and Windows pods are addressed by the
# control plane's VPC resource controller instead.
resource "aws_iam_role" "nodes_windows" {
  for_each = toset(local.windows_nodes_enabled ? ["true"] : [])

  name_prefix        = "${var.name}-nodes-win-"
  description        = "EKS Windows nodes (${var.name}) - kubelet and ECR pulls"
  assume_role_policy = data.aws_iam_policy_document.node_assume_role.json

  tags = var.tags

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_iam_role_policy_attachment" "nodes_windows" {
  for_each = toset(local.windows_nodes_enabled ? local.node_managed_policies : [])

  role       = aws_iam_role.nodes_windows["true"].name
  policy_arn = each.value
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
  name_prefix        = "${var.name}-cluster-"
  description        = "EKS control plane (${var.name})"
  assume_role_policy = data.aws_iam_policy_document.cluster_assume_role.json

  tags = var.tags

  lifecycle {
    create_before_destroy = true
  }
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
    # traverse the public one; the public endpoint is opt-in for terraform and
    # helm bootstrap from CI and workstations without a VPN path.
    endpoint_private_access = true
    endpoint_public_access  = var.public_access.enable
    public_access_cidrs = (
      var.public_access.enable
      ? (length(var.public_access.cidrs) > 0 ? var.public_access.cidrs : ["0.0.0.0/0"])
      : null
    )

    # No module-owned security group rides along here: one would be additive
    # next to the EKS-managed group (so restrict nothing), and once
    # network.restrict_default_security_group trims that group there is
    # nothing left for it to say. Caller-owned rules (API access from a
    # bastion or VPN range) come in as caller-owned groups instead.
    security_group_ids = var.network.security_group_ids
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
    for_each = var.encryption_kms_key_arn != null ? ["true"] : []

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

resource "aws_eks_access_entry" "nodes_windows" {
  for_each = aws_iam_role.nodes_windows

  cluster_name  = aws_eks_cluster.main.name
  principal_arn = each.value.arn
  type          = "EC2_WINDOWS"

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
  # manifests contract never carries an IAM-specific subject type.
  rbac_roles = var.rbac.enabled ? {
    for role, subject in var.rbac.groups : role => subject if subject != null
  } : {}

  # Only roles carrying an IAM principal get an access entry -- a role bound
  # purely through OIDC federation (sso.kubectl) reaches its group via the
  # groups claim dex asserts, which EKS's identity provider config resolves
  # without any access entry at all.
  rbac_roles_with_principal = { for role, subject in local.rbac_roles : role => subject if subject.principal_arn != null }
}

resource "aws_eks_access_entry" "rbac" {
  for_each = local.rbac_roles_with_principal

  cluster_name      = aws_eks_cluster.main.name
  principal_arn     = each.value.principal_arn
  kubernetes_groups = [each.value.group]
  type              = "STANDARD"

  tags = var.tags
}

# Federates the API server itself to dex, so kubectl can authenticate humans
# through whatever upstream connector sso.connector declares without an IAM
# principal at all -- RBAC then binds the prefixed groups claim the same way
# it binds an access entry's kubernetes_groups (var.rbac.groups.*.group).
#
# BOOTSTRAP ORDER: EKS validates the issuer's discovery endpoint at creation
# time, and dex only exists once flux has reconciled it post-cluster-create
# -- so this cannot be created in the same apply that first creates the
# cluster. Land sso.kubectl.enabled = false on the first apply, then flip it
# on once dex is live and serving over its Gateway route.
resource "aws_eks_identity_provider_config" "dex" {
  count = var.sso.enabled && var.sso.kubectl.enabled ? 1 : 0

  cluster_name = aws_eks_cluster.main.name

  oidc {
    identity_provider_config_name = "dex"
    issuer_url                    = "https://dex.${local.platform_domain}"
    client_id                     = var.sso.kubectl.client_id

    username_claim  = "email"
    username_prefix = "-"
    groups_claim    = "groups"
    groups_prefix   = var.sso.kubectl.groups_claim_prefix
  }

  tags = var.tags

  # Doesn't guarantee dex has actually reconciled (that's flux's async job),
  # only that this apply isn't racing the module resources dex depends on.
  depends_on = [module.flux_operator]
}

# ---------------------------------------------------------------------------
# Managed node groups. The always-on system group carries the platform tier - 
# flux controllers, kyverno, cert-manager, karpenter and the rest pin here via
# nodeSelector role=system, away from Karpenter's workload capacity - and
# var.node_groups adds static pools Karpenter cannot express (extra security
# groups, Windows nodes).
# ---------------------------------------------------------------------------

locals {
  # Nothing schedules on a new Linux node until Cilium can give it an address.
  # The Cilium agent and operator tolerate all taints, and the operator removes
  # this one once the agent is ready (operator.removeNodeTaints, on by
  # default), so it gates workloads without gating the CNI that clears it.
  # Windows nodes never carry it: Cilium has no Windows datapath, so the taint
  # would sit unremoved and the group would never schedule a pod.
  cilium_bootstrap_taint = [{
    key    = "node.cilium.io/agent-not-ready"
    value  = "true"
    effect = "NO_EXECUTE"
  }]
}

module "system_node_group" {
  source = "./modules/node-group"

  cluster_name              = aws_eks_cluster.main.name
  name                      = "system"
  node_role_arn             = aws_iam_role.nodes.arn
  subnet_ids                = var.network.node_subnet_ids
  cluster_security_group_id = aws_eks_cluster.main.vpc_config[0].cluster_security_group_id

  instance_types = var.system_node_group.instance_types
  capacity_type  = var.system_node_group.capacity_type
  min_size       = var.system_node_group.min_size
  max_size       = var.system_node_group.max_size
  desired_size   = var.system_node_group.desired_size
  disk_size_gib  = var.system_node_group.disk_size_gib

  labels = local.system_node_selector
  taints = local.cilium_bootstrap_taint

  tags = var.tags

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

module "node_group" {
  source   = "./modules/node-group"
  for_each = var.node_groups

  cluster_name              = aws_eks_cluster.main.name
  name                      = each.key
  node_role_arn             = contains(keys(local.windows_node_groups), each.key) ? aws_iam_role.nodes_windows["true"].arn : aws_iam_role.nodes.arn
  subnet_ids                = var.network.node_subnet_ids
  cluster_security_group_id = aws_eks_cluster.main.vpc_config[0].cluster_security_group_id
  security_group_ids        = each.value.security_group_ids

  instance_types = each.value.instance_types
  capacity_type  = each.value.capacity_type
  min_size       = each.value.min_size
  max_size       = each.value.max_size
  desired_size   = each.value.desired_size
  disk_size_gib  = each.value.disk_size_gib
  ami_type       = each.value.ami_type

  labels = each.value.labels
  taints = concat(
    contains(keys(local.windows_node_groups), each.key) ? [] : local.cilium_bootstrap_taint,
    each.value.taints,
  )

  tags = var.tags

  # Same bootstrap gate as the system group; the windows entries are inert
  # no-ops unless a WINDOWS_* group elects them into existence.
  depends_on = [
    helm_release.cilium,
    aws_eks_access_entry.nodes,
    aws_eks_access_entry.nodes_windows,
    aws_iam_role_policy_attachment.nodes,
    aws_iam_role_policy_attachment.nodes_windows,
    aws_iam_role_policy.cilium_eni,
  ]
}

# ---------------------------------------------------------------------------
# The EBS CSI driver ships as an EKS-managed add-on, but unlike coredns or
# metrics-server it drives the EC2 API (CreateVolume/AttachVolume/...) and so
# needs its own IAM identity - the same one for every consumer, hence the AWS
# managed policy and a fixed namespace/service-account pair rather than a
# var.workload_identity entry.
# ---------------------------------------------------------------------------

resource "aws_iam_role" "ebs_csi" {
  for_each = toset(contains(keys(local.addons), "aws-ebs-csi-driver") ? ["true"] : [])

  name_prefix        = "${var.name}-ebs-csi-"
  description        = "EBS CSI driver (${var.name})"
  assume_role_policy = data.aws_iam_policy_document.pod_identity_assume_role.json

  tags = var.tags

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_iam_role_policy_attachment" "ebs_csi" {
  for_each = toset(contains(keys(local.addons), "aws-ebs-csi-driver") ? ["true"] : [])

  role       = aws_iam_role.ebs_csi["true"].name
  policy_arn = "arn:${local.partition}:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
}

resource "aws_eks_pod_identity_association" "ebs_csi" {
  for_each = toset(contains(keys(local.addons), "aws-ebs-csi-driver") ? ["true"] : [])

  cluster_name    = aws_eks_cluster.main.name
  namespace       = "kube-system"
  service_account = "ebs-csi-controller-sa"
  role_arn        = aws_iam_role.ebs_csi["true"].arn

  tags = var.tags

  depends_on = [aws_eks_addon.pod_identity_agent]
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

  depends_on = [module.system_node_group]
}

resource "aws_eks_addon" "main" {
  for_each = { for name, addon in local.addons : name => addon if name != "eks-pod-identity-agent" }

  cluster_name  = aws_eks_cluster.main.name
  addon_name    = each.key
  addon_version = each.value.version

  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "PRESERVE"

  # Module defaults (see local.addon_configuration_defaults) unless the
  # caller overrides them; anything else takes the add-on's own defaults.
  configuration_values = (
    each.value.configuration_values != null
    ? each.value.configuration_values
    : lookup(local.addon_configuration_defaults, each.key, null)
  )

  tags = var.tags

  depends_on = [
    module.system_node_group,
    aws_eks_addon.pod_identity_agent,
    aws_eks_pod_identity_association.ebs_csi,
  ]
}

# ---------------------------------------------------------------------------
# Restricting the EKS-managed cluster security group (opt-in). EKS always
# creates eks-cluster-sg-* with allow-all egress and attaches it to the
# control-plane ENIs and every node - it cannot be replaced or detached, only
# edited. network.restrict_default_security_group pins the documented minimum
# self-rules onto it and then revokes the 0.0.0.0/0 / ::/0 egress rules; EKS
# re-adds only the self-referencing rules and tags on cluster update, so the
# revoke sticks.
#
# The revoke has no declarative form (terraform cannot delete rules on a
# security group it does not manage), hence the AWS CLI. It is deliberately
# ordered after the add-ons: bootstrap then completes identically with the
# toggle on or off, and open egress is closed only once the cluster is up.
# ---------------------------------------------------------------------------

# The documented minimum egress for restricting cluster traffic: out to the
# group itself only for the API server, the kubelets and DNS.
locals {
  cluster_self_egress_rules = {
    https   = { protocol = "tcp", port = 443, description = "API server" }
    kubelet = { protocol = "tcp", port = 10250, description = "Kubelet" }
    dns-tcp = { protocol = "tcp", port = 53, description = "DNS (TCP)" }
    dns-udp = { protocol = "udp", port = 53, description = "DNS (UDP)" }
  }
}

resource "aws_vpc_security_group_egress_rule" "default_self" {
  for_each = var.network.restrict_default_security_group ? local.cluster_self_egress_rules : {}

  security_group_id            = aws_eks_cluster.main.vpc_config[0].cluster_security_group_id
  referenced_security_group_id = aws_eks_cluster.main.vpc_config[0].cluster_security_group_id
  ip_protocol                  = each.value.protocol
  from_port                    = each.value.port
  to_port                      = each.value.port
  description                  = "${each.value.description} to members of this security group"

  tags = var.tags
}

resource "terraform_data" "revoke_default_egress" {
  for_each = toset(var.network.restrict_default_security_group ? ["true"] : [])

  # Once per cluster: the EKS-managed group's id changes only when the cluster
  # is replaced. Drift-blind by design - a manually re-added rule stays.
  triggers_replace = aws_eks_cluster.main.vpc_config[0].cluster_security_group_id

  provisioner "local-exec" {
    environment = {
      SG_ID      = aws_eks_cluster.main.vpc_config[0].cluster_security_group_id
      AWS_REGION = data.aws_region.current.region
    }

    # Revoke by rule id so a partial state (one of the two already gone, or a
    # cluster created before IPv6 rules existed) never errors the apply.
    command = <<-EOT
      set -eu
      rule_ids=$(aws ec2 describe-security-group-rules \
        --filters "Name=group-id,Values=$SG_ID" \
        --query "SecurityGroupRules[?IsEgress && (CidrIpv4=='0.0.0.0/0' || CidrIpv6=='::/0')].SecurityGroupRuleId" \
        --output text)
      if [ -n "$rule_ids" ]; then
        aws ec2 revoke-security-group-egress --group-id "$SG_ID" --security-group-rule-ids $rule_ids
      fi
    EOT
  }

  # The minimum rules must exist before the open egress goes away, and the
  # add-ons must be ACTIVE so first-boot image pulls never race the revoke.
  depends_on = [
    aws_vpc_security_group_egress_rule.default_self,
    aws_eks_addon.main,
    aws_eks_addon.pod_identity_agent,
  ]
}
