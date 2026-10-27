# Copyright 2026 BitWise Media Group Ltd
# SPDX-License-Identifier: MIT

# The static addresses for the platform Gateway. Cilium's Gateway API
# implementation materialises exactly one LoadBalancer Service per Gateway
# (cilium-gateway-<name>), which the AWS Load Balancer Controller turns into an
# NLB bound to these Elastic IPs - one per subnet the NLB spans, which is an NLB
# requirement rather than a per-host one. Every HTTPRoute hostname then shares
# that one address set, so adding a host is manifests-only: an HTTPRoute plus
# the external-dns record, no terraform change.
#
# Living outside the Gateway's lifecycle means cluster destroy/recreate serves
# the same addresses again: external-dns records barely blip and the domain
# comes back without manual action. The flux-manifests gateway component
# attaches them by allocation id through the GATEWAY_EIP_ALLOCATIONS cluster
# var (spec.infrastructure.annotations ->
# service.beta.kubernetes.io/aws-load-balancer-eip-allocations).
#
# Two shapes: reserve them here (reserve_static_ip, the default), or reference
# existing allocations by id (reserve_static_ip = false + allocation_ids), the
# way a cloud-accounts-owned reservation would arrive.
#
# A private Gateway (var.gateway.private) is an internal NLB: it spans the
# internal subnets (network.internal_subnet_ids, the node subnets by default)
# rather than the public ones and cannot carry Elastic IPs, so
# the whole EIP surface here goes inert (validation keeps allocation_ids
# empty) and stability comes from the private zone's records instead.

resource "aws_eip" "gateway" {
  for_each = var.gateway.reserve_static_ip && !var.gateway.private ? var.network.public_subnet_ids : []

  domain = "vpc"

  tags = merge(var.tags, {
    Name = "${var.name}-gateway-${each.value}"
  })
}

data "aws_eip" "gateway" {
  for_each = !var.gateway.reserve_static_ip ? var.gateway.allocation_ids : []

  id = each.value
}

locals {
  gateway_eips = var.gateway.reserve_static_ip ? values(aws_eip.gateway) : values(data.aws_eip.gateway)

  # Sorted so the published vars are stable across plans regardless of set
  # iteration order. Both empty under a private Gateway.
  gateway_allocation_ids = sort([for eip in local.gateway_eips : eip.id])
  gateway_addresses      = sort([for eip in local.gateway_eips : eip.public_ip])

  # The subnets the NLB spans: the internal subnets for an internal NLB
  # (the node subnets unless the caller names others), the public subnets
  # otherwise.
  gateway_subnet_ids = !var.gateway.private ? var.network.public_subnet_ids : (
    length(var.network.internal_subnet_ids) > 0 ? var.network.internal_subnet_ids : var.network.node_subnet_ids
  )
}
