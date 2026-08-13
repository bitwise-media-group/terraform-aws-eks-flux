# Copyright 2026 BitWise Media Group Ltd
# SPDX-License-Identifier: MIT

output "name" {
  description = "Cluster name."
  value       = aws_eks_cluster.main.name
}

output "arn" {
  description = "Cluster ARN."
  value       = aws_eks_cluster.main.arn
}

output "endpoint" {
  description = "Control-plane endpoint (host for the helm/kubernetes providers)."
  value       = aws_eks_cluster.main.endpoint
}

output "ca_certificate" {
  description = "Base64-encoded cluster CA certificate."
  # try(): certificate_authority is only populated by the real API, so mocked
  # plans (the test suite) see an empty list here.
  value = try(aws_eks_cluster.main.certificate_authority[0].data, null)
}

output "kubernetes_version" {
  description = "Current control-plane version."
  value       = aws_eks_cluster.main.version
}

output "node_iam_role" {
  description = "The system node group's IAM role (name and ARN); Karpenter nodes use the separate karpenter role."
  value = {
    name = aws_iam_role.nodes.name
    arn  = aws_iam_role.nodes.arn
  }
}

output "karpenter" {
  description = "Karpenter wiring the flux-manifests component renders its EC2NodeClass/NodePool from: the node role, the interruption queue and the subnet/security-group discovery tag."
  value = {
    node_role_name      = aws_iam_role.karpenter_node.name
    node_role_arn       = aws_iam_role.karpenter_node.arn
    controller_role_arn = aws_iam_role.karpenter_controller.arn
    interruption_queue  = aws_sqs_queue.karpenter_interruption.name
    discovery_tag       = local.discovery_tag
    discovery_value     = var.name
  }
}

output "cilium" {
  description = "How Cilium is wired: the release terraform bootstraps (and the stack adopts), and where its ENI permissions live."
  value = {
    release               = helm_release.cilium.name
    namespace             = helm_release.cilium.namespace
    operator_pod_identity = var.cilium.operator_pod_identity
  }
}

output "platform_registry" {
  description = "The platform registry this cluster consumes from (pass-through of var.platform_registry): its url and whether it is a pull-through cache."
  value       = var.platform_registry
}

output "dns" {
  description = "Delegated zone wiring (null when dns.zone_name is unset): zone name, hosted zone id, apex domain, served host and the zone's name servers."
  value = var.dns.zone_name == null ? null : {
    zone_name    = var.dns.zone_name
    zone_id      = local.dns_zone_id
    domain       = local.dns_domain
    host         = local.patchy_domain
    name_servers = data.aws_route53_zone.cluster["this"].name_servers
  }
}

output "gateway" {
  description = "The Gateway's static addresses — reserved here or referenced from existing allocations (null when neither). One Cilium Gateway shares these across every HTTPRoute host."
  value = length(local.gateway_allocation_ids) > 0 ? {
    allocation_ids = local.gateway_allocation_ids
    addresses      = local.gateway_addresses
  } : null
}

output "rbac" {
  description = "Cluster RBAC subjects (null unless rbac.enabled): each role's IAM principal and the Kubernetes group its access entry maps onto, published as the RBAC_GROUP_* cluster vars flux-manifests binds against."
  value = var.rbac.enabled ? {
    for role, subject in local.rbac_roles : role => {
      principal_arn = subject.principal_arn
      group         = subject.group
    }
  } : null
}

output "flux" {
  description = "Flux bootstrap facts, including the exact cluster-vars contract this cluster publishes to the stack."
  value = {
    namespace    = module.flux_operator.namespace
    cluster_vars = merge(var.flux.cluster_vars, local.reserved_cluster_vars)
  }
}

output "registry_reader_principals" {
  description = "Every identity that reads the platform registry (node roles, flux controllers, kyverno controllers). Covered automatically when platform_registry is a pull-through cache in this account; feed these to the artifact-store module's direct_pull_principals when the cluster reads a central store directly instead."
  value       = local.registry_reader_principals
}

output "sso" {
  description = "SSO secrets this cluster owns (null unless sso.enabled): the generated dex client secrets, the composed config documents, and the out-of-band container dex's upstream-connector credentials must be written to (empty when sso.directory_secret is off)."
  value = var.sso.enabled ? {
    directory_secret = local.dex_directory_secret_name
    client_secrets   = { for client, secret in aws_secretsmanager_secret.dex_client : client => secret.name }
    config_documents = concat(
      [for secret in aws_secretsmanager_secret.flux_web_auth_config : secret.name],
      [for secret in aws_secretsmanager_secret.patchy_status_auth_config : secret.name],
    )
  } : null
}
