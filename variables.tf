# Copyright 2026 BitWise Media Group Ltd
# SPDX-License-Identifier: MIT

variable "name" {
  description = "Cluster name. Also prefixes the IAM roles, the Karpenter discovery tag and the default gateway EIP names."
  type        = string
  nullable    = false

  validation {
    condition     = can(regex("^[a-z]([a-z0-9-]{0,22})$", var.name))
    error_message = "name must be a short lowercase RFC-1035 label (it prefixes IAM role names with tight length limits)."
  }
}

# No region variable: an EKS cluster is placed by the provider. The AWS_REGION
# cluster var comes from aws_region rather than an input that could disagree
# with it.

variable "network" {
  description = <<-EOT
    Existing VPC wiring, created upstream and never owned here.
    node_subnet_ids are the private subnets nodes launch into; pod_subnet_ids narrows the subnets Cilium
    allocates pod ENIs from (defaults to the node subnets); public_subnet_ids carry the Gateway's NLB and its reserved
    EIPs. manage_discovery_tags lets this module apply the karpenter.sh/discovery tag to those subnets — turn it off
    where the VPC owner tags them instead.
  EOT
  type = object({
    vpc_id                = string
    node_subnet_ids       = set(string)
    pod_subnet_ids        = optional(set(string), [])
    public_subnet_ids     = optional(set(string), [])
    manage_discovery_tags = optional(bool, true)
  })
  nullable = false

  validation {
    condition     = length(var.network.node_subnet_ids) > 0
    error_message = "network.node_subnet_ids must name at least one private subnet for the system node group."
  }
}

variable "kubernetes_version" {
  description = "EKS control-plane version, e.g. 1.34. Null tracks whatever EKS defaults to at create and pins it in state."
  type        = string
  nullable    = true
  default     = null
}

variable "upgrade_policy" {
  description = <<-EOT
    EKS support policy. STANDARD ends support at the end of standard support; EXTENDED keeps a version supported (at
    extra cost) past that date.
  EOT
  type        = string
  nullable    = false
  default     = "STANDARD"

  validation {
    condition     = contains(["STANDARD", "EXTENDED"], var.upgrade_policy)
    error_message = "upgrade_policy must be STANDARD or EXTENDED."
  }
}

variable "public_access" {
  description = <<-EOT
    Public control-plane endpoint. Disabled by default, so the API is reachable only through the always-on private
    endpoint. When enabled, cidrs constrains who may reach the public endpoint; empty leaves it open to 0.0.0.0/0
    (PoC posture) — constrain it as soon as a stable egress CIDR exists.
  EOT
  type = object({
    enable = optional(bool, false)
    cidrs  = optional(set(string), [])
  })
  nullable = false
  default  = {}

  validation {
    condition     = var.public_access.enable || length(var.public_access.cidrs) == 0
    error_message = "public_access.cidrs only applies when public_access.enable is true."
  }
}

variable "cluster_log_types" {
  description = "Control-plane log streams shipped to CloudWatch Logs."
  type        = set(string)
  nullable    = false
  default     = ["api", "audit", "authenticator"]

  validation {
    condition = alltrue([
      for log in var.cluster_log_types :
      contains(["api", "audit", "authenticator", "controllerManager", "scheduler"], log)
    ])
    error_message = "cluster_log_types entries must be api, audit, authenticator, controllerManager or scheduler."
  }
}

variable "encryption_kms_key_arn" {
  description = "Optional customer-managed KMS key for Kubernetes secrets envelope encryption; null leaves EKS's default encryption in place."
  type        = string
  nullable    = true
  default     = null
}

variable "rbac" {
  description = <<-EOT
    Cluster RBAC subjects. Each role names an IAM principal (typically an IAM Identity Center permission-set role ARN)
    and the Kubernetes group its access entry maps to. The group names are published as RBAC_GROUP_<ROLE> cluster vars,
    which flux-manifests' rbac component binds Role/ClusterRoleBindings against — the manifests contract carries only
    group names, never the IAM subjects behind them.
  EOT
  type = object({
    enabled = optional(bool, false)
    groups = optional(object({
      viewers    = optional(object({ principal_arn = string, group = optional(string, "platform:viewers") }))
      developers = optional(object({ principal_arn = string, group = optional(string, "platform:developers") }))
      devops     = optional(object({ principal_arn = string, group = optional(string, "platform:devops") }))
      admins     = optional(object({ principal_arn = string, group = optional(string, "platform:admins") }))
    }), {})
  })
  nullable = false
  default  = {}

  validation {
    condition     = var.rbac.enabled || alltrue([for role in values(var.rbac.groups) : role == null])
    error_message = "rbac.groups requires rbac.enabled — without it no access entries are created and the group subjects would bind nothing."
  }

  validation {
    condition = alltrue([
      for role in values(var.rbac.groups) :
      role == null || can(regex("^arn:aws[a-z-]*:iam::[0-9]{12}:(role|user)/", role.principal_arn))
    ])
    error_message = "Each rbac.groups entry's principal_arn must be an IAM role or user ARN."
  }
}

variable "cluster_admin_principals" {
  description = <<-EOT
    IAM principal ARNs granted AmazonEKSClusterAdminPolicy through an access entry — the break-glass and CI identities.
    The creating principal is admitted automatically (bootstrap_cluster_creator_admin_permissions), so this is for
    everyone else.
  EOT
  type        = set(string)
  nullable    = false
  default     = []
}

variable "system_node_pool" {
  description = <<-EOT
    The always-on managed node group platform controllers pin to (label role=system): flux, kyverno, cert-manager,
    external-dns, karpenter and the rest. These counts are CLUSTER-WIDE totals, not per-zone.
    Sizing must fit the whole platform tier — Karpenter only provisions workload capacity, never this.
  EOT
  type = object({
    instance_types = optional(list(string), ["m7i.large"])
    capacity_type  = optional(string, "ON_DEMAND")
    min_size       = optional(number, 2)
    max_size       = optional(number, 4)
    desired_size   = optional(number, 2)
    disk_size_gib  = optional(number, 50)
  })
  nullable = false
  default  = {}

  validation {
    condition     = contains(["ON_DEMAND", "SPOT"], var.system_node_pool.capacity_type)
    error_message = "system_node_pool.capacity_type must be ON_DEMAND or SPOT (the platform tier should stay ON_DEMAND)."
  }
}

variable "cilium" {
  description = <<-EOT
    The CNI. Cilium runs in ENI mode with the AWS VPC CNI never installed, so pods hold routable VPC addresses exactly as
    they would under vpc-cni, and kube-proxy is replaced by Cilium's eBPF datapath. This is the one chart terraform
    installs: it must exist before the first node can report Ready, so flux cannot own the bootstrap. The release is
    bootstrap-only (ignore_changes) and the stack's cilium component adopts it afterwards.

    operator_pod_identity moves the ENI permissions off the node role and onto a Pod Identity association. Off by
    default: in ENI mode the agent cannot report Ready until the operator has attached ENIs, but the pod-identity-agent
    addon only installs once nodes exist — a bootstrap cycle. Turn it on against a running cluster if the node-role
    grant is unacceptable. helm_values is merged OVER the computed values for anything not modelled here.
  EOT
  type = object({
    chart_version         = optional(string)
    repository            = optional(string)
    operator_pod_identity = optional(bool, false)
    helm_values           = optional(any, {})
  })
  nullable = false
  default  = {}
}

variable "karpenter" {
  description = <<-EOT
    Workload capacity, provisioned by Karpenter. Terraform owns the IAM roles, the interruption
    queue and the discovery tags; the chart and the EC2NodeClass/NodePool objects are a flux-manifests component,
    rendered from the KARPENTER_* cluster vars this shape publishes (lists arrive comma-joined and are expanded with
    splitList, exactly as STACK_COMPONENTS already is).

    There is deliberately no min_nodes: Karpenter scales from zero on pending pods and offers only ceilings
    (spec.limits). The cluster's floor is system_node_pool.min_size.
  EOT
  type = object({
    node_pool = optional(object({
      name                 = optional(string, "default")
      instance_categories  = optional(list(string), ["c", "m", "r"])
      instance_families    = optional(list(string), [])
      instance_sizes       = optional(list(string), ["large", "xlarge", "2xlarge"])
      capacity_types       = optional(list(string), ["spot", "on-demand"])
      architectures        = optional(list(string), ["amd64"])
      ami_alias            = optional(string, "al2023@latest")
      max_nodes            = optional(number, 20)
      max_cpu              = optional(number, 64)
      max_memory_gib       = optional(number, 256)
      disk_size_gib        = optional(number, 100)
      consolidation_policy = optional(string, "WhenEmptyOrUnderutilized")
      consolidate_after    = optional(string, "1m")
      expire_after         = optional(string, "720h")
    }), {})
  })
  nullable = false
  default  = {}

  validation {
    condition = alltrue([
      for capacity_type in var.karpenter.node_pool.capacity_types : contains(["spot", "on-demand"], capacity_type)
    ])
    error_message = "karpenter.node_pool.capacity_types entries must be spot or on-demand."
  }

  validation {
    condition = alltrue([
      for architecture in var.karpenter.node_pool.architectures : contains(["amd64", "arm64"], architecture)
    ])
    error_message = "karpenter.node_pool.architectures entries must be amd64 or arm64."
  }

  validation {
    condition     = contains(["WhenEmpty", "WhenEmptyOrUnderutilized"], var.karpenter.node_pool.consolidation_policy)
    error_message = "karpenter.node_pool.consolidation_policy must be WhenEmpty or WhenEmptyOrUnderutilized."
  }

  validation {
    condition     = length(var.karpenter.node_pool.instance_categories) > 0 || length(var.karpenter.node_pool.instance_families) > 0
    error_message = "karpenter.node_pool must select instances by category or by family — both cannot be empty."
  }
}

variable "addons" {
  description = <<-EOT
    EKS add-ons. Everything AWS offers managed is taken managed, and only the rest reaches the cluster through flux.
    vpc-cni and kube-proxy are absent by construction — Cilium replaces both, and
    bootstrap_self_managed_addons is off so EKS never installs them.

    aws-secrets-store-csi-driver-provider bundles the Secrets Store CSI driver alongside the AWS provider, so only the
    secrets-store-sync-controller (the SecretSync CRD) remains a flux component. metrics-server is a COMMUNITY add-on:
    AWS supports its lifecycle, not the software. cert-manager and external-dns are community add-ons too but stay
    flux-managed on purpose — as add-ons they would pull images from AWS's registry, breaking the invariant that
    clusters never pull from a public registry and the Kyverno policy that enforces it.
  EOT
  type = map(object({
    enabled              = optional(bool, true)
    version              = optional(string)
    configuration_values = optional(string)
  }))
  nullable = false
  default = {
    eks-pod-identity-agent                = {}
    coredns                               = {}
    aws-ebs-csi-driver                    = {}
    snapshot-controller                   = {}
    eks-node-monitoring-agent             = {}
    aws-secrets-store-csi-driver-provider = {}
    metrics-server                        = {}
  }

  validation {
    condition     = !contains(keys(var.addons), "vpc-cni") && !contains(keys(var.addons), "kube-proxy")
    error_message = "vpc-cni and kube-proxy must never be installed: Cilium replaces both, and the AWS VPC CNI would fight it for ENI ownership."
  }
}

variable "platform_registry" {
  description = <<-EOT
    Where the cluster consumes charts, images and the manifests artifact from. Pass a module output rather than
    composing this by hand — `module.cache.platform_registry` (a pull-through cache in the cluster's own account, the
    default posture) or `module.store.platform_registry` (reading a central store directly, which additionally requires
    the store to admit this cluster's registry_reader_principals). Both modules emit exactly this shape, so the
    is_pull_through_cache flag is never guessed.

    url is <account>.dkr.ecr.<region>.amazonaws.com/<prefix>. is_pull_through_cache adds ecr:CreateRepository and
    ecr:BatchImportUpstreamImage to every puller's grant — a cache materialises each repository on its FIRST pull, so
    without them the first image pull of a fresh cluster fails.
  EOT
  type = object({
    url                   = string
    is_pull_through_cache = bool
  })
  nullable = false

  validation {
    condition     = can(regex("^[0-9]{12}\\.dkr\\.ecr\\.[a-z0-9-]+\\.amazonaws\\.com/[^/]+", var.platform_registry.url))
    error_message = "platform_registry.url must be an ECR prefix: <account>.dkr.ecr.<region>.amazonaws.com/<prefix>."
  }
}

variable "signed_identity" {
  description = <<-EOT
    Cosign verification identity for every platform artifact — exactly one of two modes.

    KEYLESS (subjects set, kms_key_arn null): Go regexps matched against the Fulcio certificate of GitHub Actions OIDC
    signatures. The artifact-store module's signed_identity_subjects output provides the subjects; the issuer default
    matches GitHub Actions. Cloud agnostic — the signing identities are GitHub's, not AWS's, so the same values serve
    clusters on any cloud.

    KMS (kms_key_arn set, subjects null): the publish workflows sign with an asymmetric SIGN_VERIFY KMS key
    (cosign sign --key awskms:///<arn>; the artifact-store module's signing_kms_key_arn grants the publishers kms:Sign).
    The key's public half is distributed to the cluster as the flux-system cosign-pub Secret for the bootstrap verify
    patch, the ARN is published as the SIGNED_IDENTITY_KMS_KEY cluster var, and kyverno's controllers get
    kms:GetPublicKey / kms:Verify to resolve it at admission time.
  EOT
  type = object({
    issuer             = optional(string, "^https://token\\.actions\\.githubusercontent\\.com$")
    manifests_subject  = optional(string)
    containers_subject = optional(string)
    kms_key_arn        = optional(string)
  })
  nullable = false

  validation {
    condition = var.signed_identity.kms_key_arn != null || (
      var.signed_identity.manifests_subject != null && var.signed_identity.containers_subject != null
    )
    error_message = "Keyless verification needs both manifests_subject and containers_subject (or set kms_key_arn for KMS mode)."
  }

  validation {
    condition = var.signed_identity.kms_key_arn == null || (
      var.signed_identity.manifests_subject == null && var.signed_identity.containers_subject == null
    )
    error_message = "kms_key_arn and the keyless subjects are mutually exclusive — verification is keyless or KMS, never both."
  }

  validation {
    condition     = var.signed_identity.kms_key_arn == null || can(regex("^arn:aws[a-z-]*:kms:", var.signed_identity.kms_key_arn))
    error_message = "signed_identity.kms_key_arn must be a KMS key ARN."
  }
}

variable "dns" {
  description = <<-EOT
    Existing delegated Route53 hosted zone (created upstream; never owned here, so cluster destroy/recreate never
    touches the zone or its NS delegation). zone_name enables the DNS/TLS surface: the external-dns + cert-manager
    grants and the DNS_* / PATCHY_DOMAIN cluster vars. host optionally narrows the served host below the zone apex.
  EOT
  type = object({
    zone_name  = optional(string)
    host       = optional(string)
    acme_email = optional(string)
  })
  nullable = false
  default  = {}

  validation {
    condition     = var.dns.zone_name == null || var.dns.acme_email != null
    error_message = "dns.acme_email is required when dns.zone_name is set (Let's Encrypt registration for the cert-manager issuers)."
  }
}

variable "gateway" {
  description = <<-EOT
    The platform Gateway's static addresses. One Cilium Gateway materialises one LoadBalancer Service (an NLB), and every
    HTTPRoute hostname shares its address — so the EIPs are reserved once, one per public subnet the NLB spans, and new
    hosts are manifests-only. Reserving them here (default) keeps them outside the disposable cluster's lifecycle, so
    destroy/recreate serves the same addresses; alternatively reference existing allocations by id.
  EOT
  type = object({
    reserve_static_ip = optional(bool, true)
    allocation_ids    = optional(set(string), [])
  })
  nullable = false
  default  = {}

  validation {
    condition     = !var.gateway.reserve_static_ip || length(var.gateway.allocation_ids) == 0
    error_message = "gateway.allocation_ids references EXISTING addresses, so it requires reserve_static_ip = false."
  }

  validation {
    condition     = !var.gateway.reserve_static_ip || length(var.network.public_subnet_ids) > 0
    error_message = "gateway.reserve_static_ip needs network.public_subnet_ids — one EIP is reserved per subnet the Gateway's NLB spans."
  }
}

variable "workload_identity" {
  description = <<-EOT
    Namespace/service-account pairs the EKS Pod Identity associations bind to — the terraform <-> flux-manifests
    contract, cloud-neutral in shape so every cluster tracks the same manifests. Override only to follow a
    manifests change.
  EOT
  type = object({
    external_dns = optional(object({
      namespace       = optional(string, "external-dns")
      service_account = optional(string, "external-dns")
    }), {})
    cert_manager = optional(object({
      namespace       = optional(string, "cert-manager")
      service_account = optional(string, "cert-manager")
    }), {})
    otel_collector = optional(object({
      namespace       = optional(string, "otel-collector")
      service_account = optional(string, "otel-collector")
    }), {})
    kyverno = optional(object({
      namespace = optional(string, "kyverno")
      # the controllers that fetch image signatures from the registry at
      # admission/report time
      service_accounts = optional(list(string), ["kyverno-admission-controller", "kyverno-reports-controller"])
    }), {})
    # NOT an ingress path: Cilium is the Gateway API implementation and owns all
    # L7 routing. The AWS Load Balancer Controller exists only to turn the one
    # Service type=LoadBalancer that Cilium's Gateway materialises into an NLB
    # bound to the reserved EIPs. EKS's built-in legacy cloud provider could do
    # that too, but AWS ships it critical fixes only and advises against new
    # NLBs on it.
    load_balancer = optional(object({
      namespace       = optional(string, "aws-load-balancer-controller")
      service_account = optional(string, "aws-load-balancer-controller")
    }), {})
    karpenter = optional(object({
      namespace       = optional(string, "kube-system")
      service_account = optional(string, "karpenter")
    }), {})
    # patchy's egress-broker terminates all claude-runner model traffic; when
    # patchy.claude.provider is bedrock its KSA carries the Bedrock invoke grant
    patchy_egress_broker = optional(object({
      namespace       = optional(string, "patchy")
      service_account = optional(string, "patchy-egress-broker")
    }), {})
    # extra KSAs the secrets-store-sync-controller runs as when materialising
    # a consumer's SecretSync objects, beyond the pairs the SSO surface and
    # the patchy election already derive (sso.tf / iam.tf)
    secret_readers = optional(list(object({
      namespace       = string
      service_account = string
    })), [])
  })
  nullable = false
  default  = {}
}

variable "observability" {
  description = <<-EOT
    Where the otel-collector ships telemetry. CloudWatch and X-Ray in the cluster's own account always; amp_endpoint
    optionally adds an Amazon Managed Prometheus remote-write target (and the aps:RemoteWrite grant that goes with it).
    Pass the workspace's full remote-write URL (…/workspaces/ws-…/api/v1/remote_write) — the manifests hand it to the
    prometheusremotewrite exporter verbatim.
  EOT
  type = object({
    amp_endpoint = optional(string)
  })
  nullable = false
  default  = {}
}

variable "secret_prefix" {
  description = <<-EOT
    Prefix for every Secrets Manager secret name the manifests stack syncs, published as the SECRET_PREFIX cluster var.
    Lets multiple clusters share one account with distinct secrets; the modules/secrets instantiation (a durable
    root, holding the out-of-band credential secrets) must create them under the same prefix. Include the trailing
    separator (e.g. 'patchy-x-'); empty keeps the unprefixed names.
  EOT
  type        = string
  default     = null

  validation {
    condition     = var.secret_prefix == null || can(regex("^[A-Za-z0-9/_+=.@-]*$", var.secret_prefix))
    error_message = "secret_prefix must use Secrets Manager name characters only ([A-Za-z0-9/_+=.@-])."
  }
}

variable "stack_components" {
  description = <<-EOT
    The flux-manifests optional-tier components (short names: flux-web, patchy) this cluster elects, published as the
    STACK_COMPONENTS cluster var. The default elects the whole tier; electing none is explicit -- set []. dex is not
    elected here: it deploys exactly when sso is enabled, and without it the elected components still run, just with no
    SSO auth and no human-facing HTTPRoute (kubectl port-forward to reach). The core tier (kyverno, cert-manager,
    external-dns, gateway, rbac, karpenter) is not electable.
  EOT
  type        = set(string)
  nullable    = false
  default     = ["flux-web", "patchy"]

  validation {
    condition = alltrue([
      for component in var.stack_components : contains(["flux-web", "patchy"], component)
    ])
    error_message = "stack_components entries must be optional-tier short names: flux-web, patchy (dex rides the sso toggle)."
  }
}

variable "patchy" {
  description = <<-EOT
    Patchy platform knobs. harnesses elects the agent harnesses the cluster runs, published as the AGENT_HARNESSES
    cluster var -- it gates the chart's per-harness runners, the harness credential syncs, and the derived
    secret-reader Pod Identity roles (iam.tf); create the matching credential secrets with modules/secrets (same
    value there). claude.provider configures the model provider patchy's egress-broker terminates all
    claude-runner traffic against, published as the CLAUDE_* cluster vars (CLAUDE_PROVIDER, CLAUDE_ANTHROPIC_AUTH,
    CLAUDE_BEDROCK_REGION, CLAUDE_BEDROCK_REGION_PREFIX, CLAUDE_VERTEX_REGION, CLAUDE_VERTEX_PROJECT_ID,
    CLAUDE_MODEL_MAP). Keys are harness-scoped (CLAUDE_*, not a generic PROVIDER_*) and the knobs provider-prefixed
    (bedrock_region, not a bare region) — clarity over brevity, mirroring the broker's own PATCHY_BEDROCK_* env names.
    When the provider is bedrock the broker's KSA additionally gets the Bedrock invoke grant (iam.tf).
    evaluation.enabled deploys the evaluation controller -- the evolve-facing remote-evaluation API plus the runners
    that execute submitted evaluation units -- published as the PATCHY_EVALUATION cluster var. It requires sso (the API
    has no unauthenticated posture; evolve authenticates through dex as a public PKCE client) and at least one harness
    (the chart refuses an evaluation controller with zero enabled runners).
  EOT
  type = object({
    harnesses = optional(set(string), ["claude"])

    # Harness-scoped: the model provider belongs to the claude runner alone.
    # A future codex/copilot provider surface slots in as a sibling key
    # (patchy.codex.provider) without renaming anything here.
    claude = optional(object({
      provider = optional(object({
        name                  = optional(string, "anthropic") # anthropic | bedrock
        anthropic_auth        = optional(string, "token")     # key | token
        bedrock_region        = optional(string)              # defaults to the cluster region
        bedrock_region_prefix = optional(string)              # inference-profile geo prefix (us/eu/apac)
        model_map             = optional(map(string), {})     # canonical id -> provider model id
      }), {})
    }), {})

    evaluation = optional(object({
      enabled = optional(bool, false)
    }), {})
  })
  default  = {}
  nullable = false

  validation {
    condition = alltrue([
      for harness in var.patchy.harnesses : contains(["claude", "codex", "copilot"], harness)
    ])
    error_message = "patchy.harnesses entries must be harness short names: claude, codex, copilot."
  }

  validation {
    condition     = contains(["anthropic", "bedrock"], var.patchy.claude.provider.name)
    error_message = "patchy.claude.provider.name must be anthropic or bedrock (vertex needs GCP ambient credentials the broker cannot get on EKS; foundry is deliberately unsupported for now)."
  }

  validation {
    condition     = contains(["key", "token"], var.patchy.claude.provider.anthropic_auth)
    error_message = "patchy.claude.provider.anthropic_auth must be key or token."
  }

  validation {
    condition     = var.patchy.claude.provider.name == "bedrock" || var.patchy.claude.provider.bedrock_region == null
    error_message = "patchy.claude.provider.bedrock_region only applies when the provider is bedrock."
  }

  validation {
    condition     = var.patchy.claude.provider.name == "bedrock" || var.patchy.claude.provider.bedrock_region_prefix == null
    error_message = "patchy.claude.provider.bedrock_region_prefix only applies when the provider is bedrock."
  }

  validation {
    condition     = !var.patchy.evaluation.enabled || var.sso.enabled
    error_message = "patchy.evaluation requires sso -- the evaluation API has no unauthenticated posture; evolve authenticates through dex."
  }

  validation {
    condition     = !var.patchy.evaluation.enabled || length(var.patchy.harnesses) > 0
    error_message = "patchy.evaluation requires at least one harness -- the chart refuses an evaluation controller with zero enabled runners."
  }
}

variable "sso" {
  description = <<-EOT
    Platform SSO: deploys dex as the OIDC identity provider and wires every elected relying party to it -- generated
    client pairs (sso.tf), the DEX_CONNECTORS cluster var, and the human-facing HTTPRoutes. Upstream identity is
    arbitrary: connector declares the deployment's single upstream IdP -- which connector type a deployment federates
    isn't known ahead of time, but it only ever federates one --
      - type: the dex connector type (oidc, saml, google, microsoft, github, ...), passed through verbatim, not
        validated against dex's own supported list.
      - id: the dex connector id, also the naming stem for the credential containers (dex-<id>-<field>) and env vars;
        defaults to type -- set it when the type alone reads poorly (e.g. id = "okta" for an oidc connector).
      - name: the display name shown on dex's login screen; defaults to the connector id when unset.
      - config: the connector's own config: block, passed through near-verbatim (issuer, clientID, scopes,
        claimMapping, adminEmail, ...) -- a redirectURI is injected by default (sso.tf) unless the caller sets one.
        Values keep their native types (bools, lists, numbers) all the way into dex's rendered YAML, e.g.
        fetchTransitiveGroupMembership = true stays a bool.
      - secrets: the out-of-band credential fields this connector needs (default ["client-id", "client-secret"]).
        Each field becomes a dex-<id>-<field> Secrets Manager container (modules/secrets, instantiated in a durable
        root and fed this same sso value -- an OAuth client cannot be terraformed, so its credentials arrive out of
        band) and a <ID>_<FIELD> env var (uppercased, dashes -> underscores) dex expands
        from its own process env at startup ($<ID>_<FIELD>) -- reference it yourself, e.g.
        config.clientID = "$GOOGLE_CLIENT_ID".
    Requires the DNS surface: the issuer and redirect URLs need the served domain.
    clients holds the per-client knobs for the generated relying-party pairs (keys: flux-web, patchy-status) -- today
    just version, the client secret's rotation counter (absent clients sit at 1): bump it to mint a new client secret;
    the raw dex-client-* secret and any config document embedding the same value rewrite in one apply, so the pair
    cannot drift (then restart dex: it reads client secrets from env at startup).
  EOT
  # config is bare any, NOT map(any): map(any) unifies the map's value
  # types, so a mixed-type config ({clientID = "$...",
  # fetchTransitiveGroupMembership = true}) silently collapses to
  # map(string) and dex rejects the stringified bool at startup. Bare any
  # inside a plain object faces no such unification, so each value keeps
  # its native type all the way into the DEX_CONNECTORS JSON. That safety
  # is also why connector is a single object rather than a map of them:
  # map elements must share one concrete type, which would collapse
  # heterogeneous configs to map(string) just as silently.
  type = object({
    enabled = optional(bool, false)
    connector = optional(object({
      id      = optional(string)
      type    = string
      name    = optional(string)
      config  = optional(any, {})
      secrets = optional(set(string), ["client-id", "client-secret"])
    }))
    clients = optional(map(object({
      version = number
    })), {})
  })
  nullable = false
  default  = {}

  validation {
    condition     = alltrue([for client in keys(var.sso.clients) : contains(["flux-web", "patchy-status"], client)])
    error_message = "sso.clients keys must be generated client ids: flux-web, patchy-status."
  }

  validation {
    condition     = !var.sso.enabled || var.sso.connector != null
    error_message = "sso.enabled requires sso.connector -- a dex deployment with no upstream connector is a footgun (nobody can authenticate)."
  }

  validation {
    condition = var.sso.connector == null || (
      can(regex("^[a-z0-9-]+$", coalesce(var.sso.connector.id, var.sso.connector.type))) &&
      coalesce(var.sso.connector.id, var.sso.connector.type) != "client"
    )
    error_message = "sso.connector.id (defaulting to type) must match ^[a-z0-9-]+$ and must not be \"client\" (reserved -- relying-party secrets are already named dex-client-<id>)."
  }

  validation {
    condition = var.sso.connector == null || alltrue([
      for field in var.sso.connector.secrets : can(regex("^[a-z0-9-]+$", field))
    ])
    error_message = "sso.connector.secrets entries must match ^[a-z0-9-]+$."
  }
}

variable "flux" {
  description = <<-EOT
    Flux bootstrap knobs. Chart repositories, the distribution registry and the sync url default onto platform_registry;
    sync.ref picks the release channel (stable, staging, or edge for dev clusters tracking trunk -- pair edge with the
    manifests_edge signing subject).
  EOT
  type = object({
    operator_chart = optional(object({
      repository = optional(string)
      version    = optional(string)
    }), {})
    instance_chart = optional(object({
      repository = optional(string)
      version    = optional(string)
    }), {})
    distribution = optional(object({
      version  = optional(string, "2.x")
      registry = optional(string)
      artifact = optional(string)
    }), {})
    sync = optional(object({
      url      = optional(string)
      ref      = optional(string, "stable")
      path     = optional(string, "stack")
      interval = optional(string, "5m")
    }), {})
    kustomize_patches = optional(list(any), [])
    cluster_vars      = optional(map(string), {})
    namespaces        = optional(list(string), [])
  })
  nullable = false
  default  = {}

  validation {
    condition     = contains(["stable", "staging", "edge"], var.flux.sync.ref) || can(regex("^v", var.flux.sync.ref))
    error_message = "flux.sync.ref must be a channel tag (stable, staging, edge) or a pinned version tag (vX.Y.Z)."
  }
}

variable "tags" {
  description = "Tags applied to every resource this module creates."
  type        = map(string)
  nullable    = false
  default     = {}
}
