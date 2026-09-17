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
  description = "The IAM role shared by the Linux managed node groups (name and ARN); Windows node groups and Karpenter nodes use their own separate roles."
  value = {
    name = aws_iam_role.nodes.name
    arn  = aws_iam_role.nodes.arn
  }
}

output "system_node_group" {
  description = "The system node group's actual name and ARN (the name carries a generated suffix)."
  value = {
    name = module.system_node_group.name
    arn  = module.system_node_group.arn
  }
}

output "node_groups" {
  description = "Each var.node_groups entry's actual node group name and ARN (the names carry generated suffixes)."
  value = {
    for name, group in module.node_group : name => {
      name = group.name
      arn  = group.arn
    }
  }
}

output "karpenter" {
  description = <<-EOT
    Karpenter wiring the flux-manifests component renders its EC2NodeClass/NodePool from: the node role, the
    interruption queue and the subnet/security-group discovery tag.
  EOT
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
  description = <<-EOT
    How Cilium is wired: the release terraform bootstraps (and the stack adopts), and where its ENI permissions live.
  EOT
  value = {
    release               = helm_release.cilium.name
    namespace             = helm_release.cilium.namespace
    operator_pod_identity = var.cilium.operator_pod_identity
  }
}

output "platform_registry" {
  description = <<-EOT
    The platform registry this cluster consumes from (pass-through of var.platform_registry): its url and whether it is
    a pull-through cache.
  EOT
  value       = var.platform_registry
}

output "dns" {
  description = <<-EOT
    Delegated zone wiring (null when dns.zone_name is unset): zone name, per-flavour hosted zone ids (public always;
    private under split-horizon), apex domain, served host and the public zone's name servers.
  EOT
  value = var.dns.zone_name == null ? null : {
    zone_name    = var.dns.zone_name
    zone_ids     = { for kind, zone in data.aws_route53_zone.cluster : kind => zone.zone_id }
    domain       = local.dns_domain
    host         = local.platform_domain
    name_servers = data.aws_route53_zone.cluster["public"].name_servers
  }
}

output "gateway" {
  description = <<-EOT
    The Gateway's static addresses - reserved here or referenced from existing allocations (null when neither, and
    always null for a private Gateway, which carries no EIPs). One Cilium Gateway shares these across every HTTPRoute
    host.
  EOT
  value = length(local.gateway_allocation_ids) > 0 ? {
    allocation_ids = local.gateway_allocation_ids
    addresses      = local.gateway_addresses
  } : null
}

output "rbac" {
  description = <<-EOT
    Cluster RBAC subjects (null unless rbac.enabled): each role's IAM principal (null when the role is OIDC-only) and
    the Kubernetes group it maps onto, published as the RBAC_GROUP_* cluster vars flux-manifests binds against.
  EOT
  value = var.rbac.enabled ? {
    for role, subject in local.rbac_roles : role => {
      principal_arn = subject.principal_arn
      group         = subject.group
    }
  } : null
}

output "flux" {
  description = <<-EOT
    Flux bootstrap facts: the namespace, the platform entrypoint the FluxInstance syncs, the electable components in
    force, the application seeds (per key: the seed release, its tag-listing provider and the resolved path) and the
    exact cluster-vars contract this cluster publishes to the platform.
  EOT
  value = {
    namespace           = module.flux_operator.namespace
    sync_url            = local.sync_url
    platform_components = sort(setunion(var.platform_components, var.sso.enabled ? ["dex"] : []))
    applications = {
      for key, app in module.flux_operator.applications : key => merge(app, {
        url  = local.applications[key].url
        path = local.applications[key].path
      })
    }
    cluster_vars = merge(var.flux.cluster_vars, local.reserved_cluster_vars)
  }
}

output "secret_prefix" {
  description = <<-EOT
    The normalized Secrets Manager name prefix (var.secret_prefix, or the empty string), published as SECRET_PREFIX.
    Application modules and roots compose container names as <prefix><name> from this rather than re-deriving
    the rule.
  EOT
  value       = local.secret_prefix
}

output "secrets_role_prefix" {
  description = <<-EOT
    The ARN prefix of the podless secret-sync reader roles (published as SECRETS_ROLE_PREFIX): a
    workload_identity.secret_readers pair <ns>/<sa> assumes <prefix><ns>-<sa>. Exported so an application's
    out-of-cluster wiring can name its reader roles without importing the naming rule.
  EOT
  value       = local.reserved_cluster_vars.SECRETS_ROLE_PREFIX
}

output "workload_roles" {
  description = <<-EOT
    Every workload IAM role this module mints, keyed as in iam.tf: the platform grants, each workload_grants entry
    (by its key) and the secrets-<ns>-<sa> readers. Role ARNs, for roots that grant these identities further
    access (a bucket policy, a cross-account trust).
  EOT
  value       = { for key, role in aws_iam_role.workload : key => role.arn }
}

output "registry_reader_principals" {
  description = <<-EOT
    Every identity that reads the platform registry (node roles, flux controllers, kyverno controllers). Covered
    automatically when platform_registry is a pull-through cache in this account; feed these to the artifact-store
    module's direct_pull_principals when the cluster reads a central store directly instead.
  EOT
  value       = local.registry_reader_principals
}

output "sso" {
  description = <<-EOT
    SSO facts this cluster owns (null unless sso.enabled): the dex issuer, every registered client (platform and
    application, as published in DEX_CLIENTS), the generated dex-client-<id> secret names for the confidential ones
    and the composed config documents. The out-of-band dex-<id>-<field> connector containers live in
    modules/sso-secrets (a durable root), fed the same sso value.
  EOT
  value = var.sso.enabled ? {
    issuer_url       = "https://dex.${local.platform_domain}"
    clients          = { for id, client in local.dex_clients : id => { name = client.name, public = client.public, redirect_uris = client.redirect_uris } }
    client_secrets   = { for client, secret in aws_secretsmanager_secret.dex_client : client => secret.name }
    config_documents = [for secret in aws_secretsmanager_secret.flux_web_auth_config : secret.name]
  } : null
}

output "kubectl_oidc" {
  description = <<-EOT
    kubectl-via-dex wiring (null unless sso.kubectl.enabled): the EKS identity provider config name (null until the
    second, post-bootstrap apply that creates it -- see sso.kubectl's bootstrap-order note) plus the issuer, client
    id and groups prefix a kubelogin (int128/kubelogin, `kubectl oidc-login`) exec-plugin kubeconfig entry needs:

      kubectl oidc-login setup \
        --oidc-issuer-url=<issuer> \
        --oidc-client-id=<client_id> \
        --oidc-extra-scope=groups,email,profile

    then wire the same three flags into a user's `kubectl config set-credentials --exec-command=kubectl
    --exec-arg=oidc-login --exec-arg=get-token ...` entry. rbac.groups.*.group for a role reached this way must
    carry groups_prefix literally, e.g. "oidc:GRP_PATCHY_NONPROD_ADMIN".
  EOT
  value = var.sso.enabled && var.sso.kubectl.enabled ? {
    identity_provider_config_name = try(aws_eks_identity_provider_config.dex[0].oidc[0].identity_provider_config_name, null)
    issuer_url                    = "https://dex.${local.platform_domain}"
    client_id                     = var.sso.kubectl.client_id
    redirect_uris                 = var.sso.kubectl.redirect_uris
    groups_claim_prefix           = var.sso.kubectl.groups_claim_prefix
  } : null
}
