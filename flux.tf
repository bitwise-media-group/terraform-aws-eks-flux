# Copyright 2026 BitWise Media Group Ltd
# SPDX-License-Identifier: MIT

# The terraform -> flux contract. reserved_cluster_vars is every value this
# cluster publishes to the platform manifests (the cluster-vars ConfigMap,
# substituted into each Kustomization via postBuild.substituteFrom) - the
# authoritative table lives in the platform-manifests README. Optional
# surfaces use the empty-string convention so substitution never fails on an
# absent value; manifests guard on empties. Applications may read any of
# these too, but nothing application-specific is published here: an
# application's own values ride in its <key>-vars ConfigMap
# (var.application_vars).
#
# The keys are deliberately cloud-neutral wherever the meaning is shared
# (CLUSTER_NAME, SIGNED_IDENTITY_*, PLATFORM_COMPONENTS, RBAC_GROUP_*, ...);
# the manifests are per-cloud trees (flux.sync.path selects "aws"), so
# aws-only facts publish as AWS-prefixed keys and nothing branches on a cloud
# var.

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

  # The platform entrypoint image: one small artifact whose ResourceSet
  # ranges over PLATFORM_COMPONENTS and emits an OCIRepository +
  # Kustomization per component (oci://<registry>/manifests/<name>). The
  # FluxInstance's single sync points here.
  default_sync_url = "oci://${var.platform_registry.url}/manifests/platform"
  sync_url         = coalesce(var.flux.sync.url, local.default_sync_url)

  node_pool = local.karpenter_node_pool

  # The application seeds. Defaults that depend on cluster-level facts are
  # resolved here (the keyless issuer onto the platform's, the path onto the
  # per-cloud tree the platform itself syncs); the registry decides how the
  # image is listed and pulled: under the platform prefix the flux
  # controllers' Pod Identity reaches it through the ECR API, anywhere else
  # the generic OCI listing (and an optional pull secret) does.
  applications = {
    for key, app in var.applications : key => {
      url        = app.url
      platform   = startswith(app.url, "oci://${var.platform_registry.url}/")
      semver     = app.semver
      path       = coalesce(app.path, "./deploy/${var.flux.sync.path}")
      interval   = app.interval
      depends_on = app.depends_on
      verify = {
        keyed   = app.verify.keyed
        issuer  = app.verify.keyed ? null : coalesce(app.verify.issuer, var.signed_identity.issuer)
        subject = app.verify.subject
      }
      pull_secret = app.pull_secret
      prune       = app.prune
      wait        = app.wait
      timeout     = app.timeout
    }
  }

  # Values every cluster publishes to the platform, merged OVER any
  # caller-provided extras (reserved keys always win).
  reserved_cluster_vars = merge({
    CLUSTER_NAME = var.name

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
    # credentials from their Pod Identity association. ARTIFACT_TAG_PROVIDER
    # is the same election for the ResourceSetInputProviders' tag listing - 
    # a flux-operator RSIP type name, since the manifests cannot derive it
    # from OCI_PROVIDER inside a substitution.
    OCI_PROVIDER          = "aws"
    ARTIFACT_TAG_PROVIDER = "ECRArtifactTag"

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

    # KMS mode also publishes the signing key's public half (base64 PEM,
    # dropping straight into Secret data): the manifests render it into each
    # verified component namespace as a cosign-pub Secret, so the chart
    # OCIRepositories' secretRef verify resolves without any cross-namespace
    # secret machinery. Public material - safe in a ConfigMap.
    COSIGN_PUBLIC_KEY = local.signing_kms ? base64encode(one(data.aws_kms_public_key.signing[*].public_key_pem)) : ""

    # The platform's flux component (flux managing flux) re-renders the
    # FluxInstance this module bootstraps: it needs the manifests signing
    # subject for the sync verify patch, the release channel for sync.ref
    # (and for every component source the entrypoint emits), the sync url
    # and the per-cloud tree -- all otherwise trapped inside this module's
    # bootstrap-only helm values. Publishing FLUX_SYNC_URL is what lets a
    # running cluster be re-pointed: the flux component asserts it on the
    # FluxInstance, so a changed var moves the sync without a kubectl patch.
    SIGNED_IDENTITY_MANIFESTS = local.signing_kms ? "" : var.signed_identity.manifests_subject
    FLUX_SYNC_CHANNEL         = var.flux.sync.ref
    FLUX_SYNC_URL             = local.sync_url
    PLATFORM_TREE             = var.flux.sync.path

    # DNS/TLS surface (empty when var.dns.zone_name is unset). The public
    # zone always exists - cert-manager's DNS-01 solver pins its id, since
    # Let's Encrypt validates over public DNS - and the private id rides
    # alongside when split-horizon is on. external-dns cannot serve both
    # flavours from one instance (its planner flattens matched zones into a
    # single record view), so the manifests pin one instance per flavour by
    # zone id and render the private instance only when its id is set.
    DNS_ZONE_NAME       = var.dns.zone_name != null ? var.dns.zone_name : ""
    DNS_PUBLIC_ZONE_ID  = try(data.aws_route53_zone.cluster["public"].zone_id, "")
    DNS_PRIVATE_ZONE_ID = try(data.aws_route53_zone.cluster["private"].zone_id, "")
    DNS_DOMAIN          = var.dns.zone_name != null ? local.dns_domain : ""
    PLATFORM_DOMAIN     = var.dns.zone_name != null ? local.platform_domain : ""
    ACME_EMAIL          = var.dns.acme_email != null ? var.dns.acme_email : ""

    # The Gateway's NLB shape. A public Gateway is an internet-facing NLB on
    # the public subnets, pinned to the reserved addresses by allocation id
    # (the IPs are informational - external-dns publishes records against
    # the NLB); a private Gateway (var.gateway.private) is an internal NLB
    # on the node subnets, with the EIP vars empty - the gateway component
    # gates that annotation absent.
    GATEWAY_NLB_SCHEME      = var.gateway.private ? "internal" : "internet-facing"
    GATEWAY_EIP_ALLOCATIONS = join(",", local.gateway_allocation_ids)
    GATEWAY_IP              = join(",", local.gateway_addresses)
    GATEWAY_SUBNETS         = join(",", sort(tolist(local.gateway_subnet_ids)))

    # instance, never ip. The AWS Load Balancer Controller can only register IP
    # targets when the AWS VPC CNI is the datapath; under any alternate CNI - 
    # Cilium here - it is limited to instance targets, whatever the pods'
    # addresses look like. Published rather than hard-coded in the manifests so
    # the constraint is visible where the rest of the Gateway wiring is.
    GATEWAY_NLB_TARGET_TYPE = "instance"

    # Whether the manifests install the Gateway API CRDs (the standard-channel
    # set Cilium requires). EKS ships none and Cilium does not own them, so
    # this defaults on; it exists to be flipped off the day AWS installs the
    # CRDs as managed cluster furniture (as GKE already does), handing them
    # over rather than fighting for ownership. "true"/"false" rather than the
    # empty-string convention: a boolean, not an optional value, and the
    # manifests' := default ("true") covers a terraform predating the key.
    GATEWAY_API_CRDS = var.gateway.install_crds ? "true" : "false"

    # The stack's cilium component adopts helm_release.cilium by name
    # (cilium.tf) and needs the two values that release computes from this
    # cluster's own infrastructure rather than from a chart default:
    # k8sServiceHost (kube-proxy replacement's direct route to the API
    # server) and eni.subnetIDsFilter (which subnets the operator pulls pod
    # ENIs from). Neither can be hardcoded in the manifests, and unlike the
    # rest of this map's optional surfaces, Cilium cannot run without them - 
    # no empty-string convention.
    CILIUM_K8S_SERVICE_HOST = local.cluster_endpoint_host
    CILIUM_POD_SUBNET_IDS   = jsonencode(sort(tolist(local.pod_subnet_ids)))

    # Where the otel-collector writes telemetry. CloudWatch and X-Ray in this
    # account always; AMP only when a workspace endpoint is configured.
    OTEL_REGION       = data.aws_region.current.region
    OTEL_AMP_ENDPOINT = var.observability.amp_endpoint != null ? var.observability.amp_endpoint : ""

    # Per-cluster Secrets Manager naming: the manifests' secret-sync
    # resourceNames are all ${SECRET_PREFIX}<name>, so clusters sharing an
    # account can carry distinct secrets (empty-string convention when unset).
    SECRET_PREFIX = local.secret_prefix

    # The sync KSAs' IRSA reader roles (iam.tf), published as one ARN prefix
    # rather than a var per pair: role names are deterministic
    # (${var.name}-secrets-<ns>-<sa>), so the manifests compose
    # ${SECRETS_ROLE_PREFIX}<ns>-<sa> into each sync SA's
    # eks.amazonaws.com/role-arn annotation.
    SECRETS_ROLE_PREFIX = "arn:${local.partition}:iam::${local.account_id}:role/${var.name}-secrets-"

    # The electable-tier election, dex riding the sso toggle rather than the
    # component set. The platform entrypoint's ResourceSet ranges over this
    # list (the list IS the component graph's election). A fully-empty
    # election publishes the reserved name "none" -- a short name matching no
    # component -- because an empty string would re-trigger the manifests'
    # elect-everything := default.
    PLATFORM_COMPONENTS = coalesce(
      join(",", sort(setunion(var.platform_components, var.sso.enabled ? ["dex"] : []))),
      "none",
    )

    # Arbitrary SSO federation: the non-secret half of each connector,
    # JSON-encoded since a cluster var is a flat string. Defaults to "[]"
    # rather than "" (unlike the rest of this map's empty-string convention)
    # because the manifests unconditionally mustFromJson-parse it. The
    # credential containers the manifests sync alongside it are derived from
    # the same local (sso.tf), so the id/field naming cannot drift.
    DEX_CONNECTORS = var.sso.enabled ? jsonencode([
      for id, c in local.dex_connectors : merge({ id = id }, c)
    ]) : "[]"

    # Every OIDC relying party dex serves, platform and application alike:
    # the flux-web client (when elected), the PUBLIC kubectl client
    # (sso.kubectl, the OIDC/PKCE flow kubelogin drives, no secret) and each
    # applications[*].dex_clients entry, JSON-encoded like DEX_CONNECTORS and
    # for the same reason. The dex component renders staticClients from it
    # and syncs ${SECRET_PREFIX}dex-client-<id> for every confidential
    # client; the containers are minted from the same local (sso.tf), so the
    # ids cannot drift. The identity provider config trusting the kubectl
    # tokens at the API server is created straight from var.sso.kubectl in
    # main.tf, not published here -- there is nothing for the manifests to
    # do with it.
    DEX_CLIENTS = var.sso.enabled ? jsonencode([
      for id, c in local.dex_clients : {
        id           = id
        name         = c.name
        public       = c.public
        redirectURIs = c.redirect_uris
      }
    ]) : "[]"

    # --- Karpenter -------------------------------------------------------
    # Wiring the component needs to render its EC2NodeClass/NodePool.
    KARPENTER_NODE_ROLE          = aws_iam_role.karpenter_node.name
    KARPENTER_INTERRUPTION_QUEUE = aws_sqs_queue.karpenter_interruption.name
    KARPENTER_SERVICE_ACCOUNT    = var.workload_identity.karpenter.service_account

    # The default NodePool's shape. Lists arrive comma-joined and are expanded
    # manifests-side with splitList, exactly as STACK_COMPONENTS already is - 
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
    },
    # The RBAC subject groups, one var per role key in rbac.groups
    # (RBAC_GROUP_VIEWERS, RBAC_GROUP_DEVELOPERS, RBAC_GROUP_DEVOPS,
    # RBAC_GROUP_ADMINS) - the manifests bind Role/ClusterRoleBindings on them;
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

# The signing key's public half - cosign verification inside the cluster never
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
    url      = local.sync_url
    ref      = var.flux.sync.ref
    path     = var.flux.sync.path
    interval = var.flux.sync.interval
  }

  applications     = local.applications
  application_vars = var.application_vars

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

  # The platform contract's fixed name for the Flux status web UI's Web Config
  # Secret: composed in sso.tf, synced to flux-system by the platform's
  # flux-web component, hot-reloaded by the operator (it may arrive after
  # bootstrap, or never on an SSO-less cluster -- harmless).
  web_config_secret_name = "flux-web-auth"

  tags = var.tags

  # The system pool must exist so the operator's pods can schedule, coredns
  # must resolve for the controllers to reach the API server and the registry,
  # and the Pod Identity agent must be live before the first reconcile needs
  # registry credentials.
  depends_on = [
    module.system_node_group,
    aws_eks_addon.pod_identity_agent,
    aws_eks_addon.main,
  ]
}
