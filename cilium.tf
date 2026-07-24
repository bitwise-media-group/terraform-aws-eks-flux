# Copyright 2026 BitWise Media Group Ltd
# SPDX-License-Identifier: MIT

# Cilium in ENI mode — the CNI, the kube-proxy replacement and the Gateway API
# implementation, with the AWS VPC CNI never installed.
#
# ENI mode rather than an overlay because pods must hold routable VPC
# addresses: the control plane reaches admission webhooks directly, the
# Gateway's NLB can target pod IPs, and the datapath matches what vpc-cni would
# have given us. It also makes raw CiliumNetworkPolicy / FQDNNetworkPolicy
# usable, which GKE Dataplane V2 rejects.
#
# This is the ONLY helm release in the root module, and it exists here rather
# than in flux for one reason: a node cannot report Ready without a CNI, so
# nothing flux-managed can be the CNI. The release is bootstrap-only
# (ignore_changes), exactly like the flux-operator/flux-instance pair, so the
# stack's cilium component adopts it by name and upgrades ship by publishing to
# the registry rather than by terraform apply.

locals {
  cilium_chart_repository = coalesce(var.cilium.repository, "oci://${var.platform_registry.url}/charts")

  # kubeProxyReplacement needs a direct route to the API server, since there is
  # no kube-proxy to service-route it. The endpoint is only known after the
  # cluster exists, which is why this release cannot precede it.
  cluster_endpoint_host = replace(aws_eks_cluster.main.endpoint, "https://", "")

  cilium_values = {
    # --- ENI datapath -----------------------------------------------------
    eni = {
      enabled = true
      # Pod ENIs come from these subnets; the operator discovers the rest of
      # the instance's networking from the EC2 API.
      subnetIDsFilter = tolist(local.pod_subnet_ids)
      # Hand unused addresses back so a burst does not permanently strand IPs.
      awsReleaseExcessIPs = true
    }
    ipam        = { mode = "eni" }
    routingMode = "native"
    # Pods carry VPC addresses, so only traffic leaving the VPC is masqueraded.
    egressMasqueradeInterfaces = "eth+"

    # --- kube-proxy replacement ------------------------------------------
    kubeProxyReplacement = true
    k8sServiceHost       = local.cluster_endpoint_host
    k8sServicePort       = 443

    # --- Gateway API ------------------------------------------------------
    # One Gateway materialises one LoadBalancer Service; every HTTPRoute
    # hostname shares its address (gateway.tf reserves the EIPs behind it).
    gatewayAPI = { enabled = true }

    # --- placement --------------------------------------------------------
    # The operator is a Deployment and must be schedulable on a node with no
    # working CNI, so it runs hostNetwork and tolerates the not-ready taint.
    operator = {
      replicas = 1
    }
    # Cleans up leftover CNI configuration on nodes joining or rejoining.
    nodeinit = { enabled = true }
  }
}

data "aws_iam_policy_document" "cilium_eni" {
  # The ENI lifecycle the operator drives: attach interfaces to instances and
  # move secondary addresses on and off them.
  statement {
    sid    = "ManageENIs"
    effect = "Allow"

    actions = [
      "ec2:CreateNetworkInterface",
      "ec2:AttachNetworkInterface",
      "ec2:DeleteNetworkInterface",
      "ec2:ModifyNetworkInterfaceAttribute",
      "ec2:AssignPrivateIpAddresses",
      "ec2:UnassignPrivateIpAddresses",
      "ec2:CreateTags",
    ]

    resources = ["*"]
  }

  # Read-only discovery: subnets and their free capacity, the instance's own
  # type (for ENI/IP limits), security groups and route tables.
  statement {
    sid    = "DescribeNetworking"
    effect = "Allow"

    actions = [
      "ec2:DescribeNetworkInterfaces",
      "ec2:DescribeSubnets",
      "ec2:DescribeVpcs",
      "ec2:DescribeRouteTables",
      "ec2:DescribeSecurityGroups",
      "ec2:DescribeInstances",
      "ec2:DescribeInstanceTypes",
      "ec2:DescribeTags",
    ]

    resources = ["*"]
  }
}

# By default these permissions sit on the NODE role, not on a Pod Identity
# association — and that is a bootstrap ordering decision, not an oversight.
# In ENI mode the Cilium agent cannot report ready until the operator has
# attached ENIs and populated the CiliumNode, so the operator needs credentials
# while the first node group is still coming up; the eks-pod-identity-agent
# add-on only installs once nodes exist. Pod Identity there is a genuine cycle.
# This is also what the AWS VPC CNI does by default. Flip
# cilium.operator_pod_identity against a running cluster to move it.
resource "aws_iam_role_policy" "cilium_eni" {
  count = var.cilium.operator_pod_identity ? 0 : 1

  name   = "${var.name}-cilium-eni"
  role   = aws_iam_role.nodes.id
  policy = data.aws_iam_policy_document.cilium_eni.json
}

resource "aws_iam_role" "cilium_operator" {
  count = var.cilium.operator_pod_identity ? 1 : 0

  name               = "${var.name}-cilium-operator"
  description        = "Cilium operator (${var.name}) — ENI attachment and address management"
  assume_role_policy = data.aws_iam_policy_document.pod_identity_assume_role.json

  tags = var.tags
}

resource "aws_iam_role_policy" "cilium_operator" {
  count = var.cilium.operator_pod_identity ? 1 : 0

  name   = "eni"
  role   = aws_iam_role.cilium_operator[0].id
  policy = data.aws_iam_policy_document.cilium_eni.json
}

resource "aws_eks_pod_identity_association" "cilium_operator" {
  count = var.cilium.operator_pod_identity ? 1 : 0

  cluster_name    = aws_eks_cluster.main.name
  namespace       = "kube-system"
  service_account = "cilium-operator"
  role_arn        = aws_iam_role.cilium_operator[0].arn

  tags = var.tags

  depends_on = [aws_eks_addon.pod_identity_agent]
}

resource "helm_release" "cilium" {
  name      = "cilium"
  namespace = "kube-system"

  repository = local.cilium_chart_repository
  chart      = "cilium"
  version    = var.cilium.chart_version

  values = [yamlencode(merge(local.cilium_values, var.cilium.helm_values))]

  # There are no nodes yet — that is the point. The objects land in the API
  # server so the agent starts the instant the first node registers; waiting
  # for readiness here would deadlock against the node group that depends on
  # this release.
  wait    = false
  timeout = 600

  # Bootstrap-only: the stack's cilium component adopts this release (same
  # name/namespace) and upgrades it from the mirror; terraform must never fight
  # it back.
  lifecycle {
    ignore_changes = all
  }
}
