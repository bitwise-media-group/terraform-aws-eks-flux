# Copyright 2026 BitWise Media Group Ltd
# SPDX-License-Identifier: MIT

# The terraform -> flux contract. reserved_cluster_vars is every value this
# cluster publishes to the flux-manifests stack (the cluster-vars ConfigMap,
# substituted into each Kustomization via postBuild.substituteFrom) — the
# authoritative table lives in the flux-manifests README. Optional surfaces use
# the empty-string convention so substitution never fails on an absent value;
# manifests guard on empties.
#
# The keys are deliberately cloud-neutral wherever the meaning is shared
# (CLUSTER_NAME, SIGNED_IDENTITY_*, STACK_COMPONENTS, RBAC_GROUP_*, ...), so a
# single manifests stack serves every cloud and branches only where it must —
# on CLOUD.

locals {
  # Which cosign mode verifies the platform artifacts: keyless (Fulcio
  # identities) or a KMS signing key. var.signed_identity's validations
  # guarantee exactly one.
  signing_kms = var.signed_identity.kms_key_arn != null

  # Charts, tag listings and the sync artifact all pull straight from the
  # platform registry; pods pull mirrored images from the same place.
  container_registry = var.platform_registry.url

  default_charts_repository     = "oci://${var.platform_registry.url}/charts"
  default_distribution_registry = "${local.container_registry}/images/ghcr.io/fluxcd"
  default_sync_url              = "oci://${var.platform_registry.url}/flux-manifests"

  node_pool = local.karpenter_node_pool

  claude_provider = var.patchy.claude.provider

  # Values every cluster publishes to flux-manifests, merged OVER any
  # caller-provided extras (reserved keys always win).
  reserved_cluster_vars = merge({
    CLUSTER_NAME = var.name

    # The one key that tells the stack which cloud it is on; everything else
    # below is either shared or guarded by it.
    CLOUD          = "aws"
    AWS_ACCOUNT_ID = local.account_id
    AWS_REGION     = data.aws_region.current.region
    AWS_PARTITION  = local.partition

    VPC_ID                  = var.network.vpc_id
    NODE_SECURITY_GROUP_ID  = aws_eks_cluster.main.vpc_config[0].cluster_security_group_id
    CLUSTER_DISCOVERY_TAG   = local.discovery_tag
    CLUSTER_DISCOVERY_VALUE = var.name

    PLATFORM_REGISTRY  = var.platform_registry.url
    CONTAINER_REGISTRY = local.container_registry
    # OCIRepository registry auth: the flux controllers resolve ECR
    # credentials from their Pod Identity association.
    OCI_PROVIDER = "aws"

    # Cosign verification, one mode or the other (the empty-string convention
    # marks the inactive one). Keyless publishes the Fulcio identities (Go
    # regexps): charts and mirrored images are signed by the flux-containers
    # publish workflow; the OCIRepository verify blocks and the Kyverno image
    # policy match these. KMS publishes the signing key's ARN instead, which
    # Kyverno resolves as awskms:///<arn> and the OCIRepositories verify via
    # the cosign-pub public-key Secret the bootstrap distributes.
    SIGNED_IDENTITY_ISSUER  = local.signing_kms ? "" : var.signed_identity.issuer
    SIGNED_IDENTITY_CHARTS  = local.signing_kms ? "" : var.signed_identity.containers_subject
    SIGNED_IDENTITY_IMAGES  = local.signing_kms ? "" : var.signed_identity.containers_subject
    SIGNED_IDENTITY_KMS_KEY = local.signing_kms ? var.signed_identity.kms_key_arn : ""

    # The stack's flux component (flux managing flux) re-renders the
    # FluxInstance this module bootstraps: it needs the manifests-artifact
    # signing subject for the sync verify patch, and the release channel for
    # sync.ref -- both otherwise trapped inside this module's helm values.
    SIGNED_IDENTITY_MANIFESTS = local.signing_kms ? "" : var.signed_identity.manifests_subject
    FLUX_SYNC_CHANNEL         = var.flux.sync.ref

    # DNS/TLS surface (empty when var.dns.zone_name is unset). DNS_ZONE_ID is
    # the Route53 hosted zone id external-dns filters on; DNS_ZONE_NAME keeps
    # the human-facing name (the cloud-neutral key of the pair).
    DNS_ZONE_NAME = var.dns.zone_name != null ? var.dns.zone_name : ""
    DNS_ZONE_ID   = local.dns_zone_id != null ? local.dns_zone_id : ""
    DNS_DOMAIN    = var.dns.zone_name != null ? local.dns_domain : ""
    PATCHY_DOMAIN = var.dns.zone_name != null ? local.patchy_domain : ""
    ACME_EMAIL    = var.dns.acme_email != null ? var.dns.acme_email : ""

    # The Gateway's reserved addresses. The gateway component annotates the
    # Cilium Gateway's LoadBalancer Service with the allocation ids; the IPs
    # are informational (external-dns publishes records against the NLB).
    GATEWAY_EIP_ALLOCATIONS = join(",", local.gateway_allocation_ids)
    GATEWAY_IP              = join(",", local.gateway_addresses)
    GATEWAY_SUBNETS         = join(",", sort(tolist(var.network.public_subnet_ids)))

    # instance, never ip. The AWS Load Balancer Controller can only register IP
    # targets when the AWS VPC CNI is the datapath; under any alternate CNI —
    # Cilium here — it is limited to instance targets, whatever the pods'
    # addresses look like. Published rather than hard-coded in the manifests so
    # the constraint is visible where the rest of the Gateway wiring is.
    GATEWAY_NLB_TARGET_TYPE = "instance"

    # Where the otel-collector writes telemetry. CloudWatch and X-Ray in this
    # account always; AMP only when a workspace endpoint is configured.
    OTEL_REGION       = data.aws_region.current.region
    OTEL_AMP_ENDPOINT = var.observability.amp_endpoint != null ? var.observability.amp_endpoint : ""

    # Per-cluster Secrets Manager naming: the manifests' secret-sync
    # resourceNames are all ${SECRET_PREFIX}<name>, so clusters sharing an
    # account can carry distinct secrets (empty-string convention when unset).
    SECRET_PREFIX = local.secret_prefix

    # The optional-tier election, dex riding the sso toggle rather than the
    # component set. A fully-empty election publishes the reserved name "none"
    # -- a short name matching no component -- because an empty string would
    # re-trigger the manifests' elect-everything := default.
    STACK_COMPONENTS = coalesce(
      join(",", sort(setunion(var.stack_components, var.sso.enabled ? ["dex"] : []))),
      "none",
    )

    # The Secrets Manager container holding the credentials for dex's upstream
    # identity-provider connector; the manifests mount the key from this secret
    # (it arrives out of band — see sso.tf). Empty when sso.directory_secret
    # is off.
    DEX_DIRECTORY_SECRET = local.dex_directory_secret_name

    # --- Karpenter -------------------------------------------------------
    # Wiring the component needs to render its EC2NodeClass/NodePool.
    KARPENTER_NODE_ROLE          = aws_iam_role.karpenter_node.name
    KARPENTER_INTERRUPTION_QUEUE = aws_sqs_queue.karpenter_interruption.name
    KARPENTER_SERVICE_ACCOUNT    = var.workload_identity.karpenter.service_account

    # The default NodePool's shape. Lists arrive comma-joined and are expanded
    # manifests-side with splitList, exactly as STACK_COMPONENTS already is —
    # cluster-vars is a flat string map, and this is the pattern the stack
    # already proves.
    KARPENTER_NODE_POOL_NAME       = local.node_pool.name
    KARPENTER_INSTANCE_CATEGORIES  = join(",", local.node_pool.instance_categories)
    KARPENTER_INSTANCE_FAMILIES    = join(",", local.node_pool.instance_families)
    KARPENTER_INSTANCE_SIZES       = join(",", local.node_pool.instance_sizes)
    KARPENTER_CAPACITY_TYPES       = join(",", local.node_pool.capacity_types)
    KARPENTER_ARCHITECTURES        = join(",", local.node_pool.architectures)
    KARPENTER_AMI_ALIAS            = local.node_pool.ami_alias
    KARPENTER_MAX_NODES            = tostring(local.node_pool.max_nodes)
    KARPENTER_CPU_LIMIT            = tostring(local.node_pool.max_cpu)
    KARPENTER_MEMORY_LIMIT         = "${local.node_pool.max_memory_gib}Gi"
    KARPENTER_NODE_DISK_GIB        = tostring(local.node_pool.disk_size_gib)
    KARPENTER_CONSOLIDATION_POLICY = local.node_pool.consolidation_policy
    KARPENTER_CONSOLIDATE_AFTER    = local.node_pool.consolidate_after
    KARPENTER_EXPIRE_AFTER         = local.node_pool.expire_after

    # --- Claude model provider (patchy's egress-broker) ------------------
    # The broker terminates all claude-runner model traffic and proxies it to
    # this provider. Keys are harness-scoped (CLAUDE_*, so codex/copilot could
    # later publish CODEX_* siblings) and the knobs provider-prefixed
    # (BEDROCK_REGION, never a generic REGION) — clarity over brevity,
    # mirroring the broker's own PATCHY_BEDROCK_* env names. The vertex pair
    # exists so the contract is identical on every cloud; on AWS it is always
    # empty (vertex needs GCP ambient credentials the broker cannot get here).
    CLAUDE_PROVIDER              = local.claude_provider.name
    CLAUDE_ANTHROPIC_AUTH        = local.claude_provider.anthropic_auth
    CLAUDE_BEDROCK_REGION        = local.claude_provider.name == "bedrock" ? coalesce(local.claude_provider.bedrock_region, data.aws_region.current.region) : ""
    CLAUDE_BEDROCK_REGION_PREFIX = local.claude_provider.bedrock_region_prefix != null ? local.claude_provider.bedrock_region_prefix : ""
    CLAUDE_VERTEX_REGION         = ""
    CLAUDE_VERTEX_PROJECT_ID     = ""
    # canonical=providerID pairs, comma-joined sorted — the same flat-string
    # list pattern KARPENTER_* and STACK_COMPONENTS already prove.
    CLAUDE_MODEL_MAP = join(",", [for k in sort(keys(local.claude_provider.model_map)) : "${k}=${local.claude_provider.model_map[k]}"])
    },
    # The RBAC subject groups, one var per role key in rbac.groups
    # (RBAC_GROUP_VIEWERS, RBAC_GROUP_DEVELOPERS, RBAC_GROUP_DEVOPS,
    # RBAC_GROUP_ADMINS) — the manifests bind Role/ClusterRoleBindings on them;
    # empty when the role is unbound or RBAC is off. These are the Kubernetes
    # group names the access entries map their IAM principals onto; the
    # manifests bind whatever names arrive and never see the subject type
    # behind them.
    {
      for role, subject in var.rbac.groups :
      "RBAC_GROUP_${upper(role)}" => (var.rbac.enabled && subject != null) ? subject.group : ""
    },
  )
}

# The signing key's public half — cosign verification inside the cluster never
# needs the private key, and Flux verifies against a public-key Secret rather
# than calling KMS, so this is the only key material that travels.
data "aws_kms_public_key" "signing" {
  count = local.signing_kms ? 1 : 0

  key_id = var.signed_identity.kms_key_arn
}

module "flux_operator" {
  source = "./modules/flux-operator"

  cluster_name = aws_eks_cluster.main.name

  operator_chart = {
    repository = coalesce(var.flux.operator_chart.repository, local.default_charts_repository)
    version    = var.flux.operator_chart.version
  }
  instance_chart = {
    repository = coalesce(var.flux.instance_chart.repository, local.default_charts_repository)
    version    = var.flux.instance_chart.version
  }
  distribution = {
    version  = var.flux.distribution.version
    registry = coalesce(var.flux.distribution.registry, local.default_distribution_registry)
    artifact = var.flux.distribution.artifact
  }
  sync = {
    url      = coalesce(var.flux.sync.url, local.default_sync_url)
    ref      = var.flux.sync.ref
    path     = var.flux.sync.path
    interval = var.flux.sync.interval
  }

  signed_identity = {
    issuer             = local.signing_kms ? null : var.signed_identity.issuer
    manifests_subject  = local.signing_kms ? null : var.signed_identity.manifests_subject
    kms_public_key_pem = one(data.aws_kms_public_key.signing[*].public_key_pem)
  }

  registry_arn                   = local.registry_arn
  registry_is_pull_through_cache = var.platform_registry.is_pull_through_cache

  kustomize_patches = var.flux.kustomize_patches
  cluster_vars      = merge(var.flux.cluster_vars, local.reserved_cluster_vars)
  namespaces        = var.flux.namespaces

  # The manifests contract's fixed name for the Flux status web UI's Web Config
  # Secret: composed in sso.tf, synced to flux-system by the manifests'
  # flux-web component, hot-reloaded by the operator (it may arrive after
  # bootstrap, or never on an SSO-less cluster -- harmless).
  web_config_secret_name = "flux-web-auth"

  tags = var.tags

  # The system pool must exist so the operator's pods can schedule, coredns
  # must resolve for the controllers to reach the API server and the registry,
  # and the Pod Identity agent must be live before the first reconcile needs
  # registry credentials.
  depends_on = [
    aws_eks_node_group.system,
    aws_eks_addon.pod_identity_agent,
    aws_eks_addon.main,
  ]
}
