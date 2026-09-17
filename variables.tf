# Copyright 2026 BitWise Media Group Ltd
# SPDX-License-Identifier: MIT

variable "name" {
  description = "Cluster name. Also prefixes the IAM roles, the Karpenter discovery tag and the default gateway EIP names."
  type        = string
  nullable    = false

  validation {
    condition     = can(regex("^[a-z]([a-z0-9-]{0,21})$", var.name))
    error_message = "name must be a short lowercase RFC-1035 label of at most 22 characters (it prefixes IAM role name_prefixes, whose 26-character generated suffix must fit the 64-character role name limit)."
  }
}

# No region variable: an EKS cluster is placed by the provider. The AWS_REGION
# cluster var comes from aws_region rather than an input that could disagree
# with it.

variable "network" {
  description = <<-EOT
    Existing VPC wiring, created upstream and never owned here.
    node_subnet_ids are the private subnets nodes launch into; pod_subnet_ids narrows the subnets Cilium
    allocates pod ENIs from (defaults to the node subnets); public_subnet_ids carry the public Gateway's NLB and its
    reserved EIPs (a private Gateway spans the node subnets instead, so they may be omitted then).
    manage_discovery_tags lets this module apply the karpenter.sh/discovery tag to those subnets - turn it off
    where the VPC owner tags them instead.
    security_group_ids attach to the control-plane ENIs alongside the EKS-managed cluster security group - use
    them for caller-owned rules (e.g. API access from a bastion or VPN range).
    restrict_default_security_group revokes the allow-all egress rules (0.0.0.0/0 and ::/0) on the EKS-managed
    cluster security group and pins the documented minimum self-rules there instead. The revoke runs the AWS CLI
    on the apply host (it must be installed and authenticated as the provider identity, with
    ec2:DescribeSecurityGroupRules and ec2:RevokeSecurityGroupEgress), fires once per cluster after bootstrap,
    and is drift-blind: a manually re-added rule is not re-revoked, and toggling back off restores nothing.
    Nodes wear that group, so only enable this where node egress (ECR and S3 pulls, the EKS and SSM APIs)
    arrives through VPC endpoints or caller-added rules.
  EOT
  type = object({
    vpc_id                          = string
    node_subnet_ids                 = set(string)
    pod_subnet_ids                  = optional(set(string), [])
    public_subnet_ids               = optional(set(string), [])
    manage_discovery_tags           = optional(bool, true)
    security_group_ids              = optional(set(string), [])
    restrict_default_security_group = optional(bool, false)
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
    (PoC posture) - constrain it as soon as a stable egress CIDR exists.
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
    Cluster RBAC subjects. Each role names the Kubernetes group its access entry (or OIDC federation) maps to. The
    group names are published as RBAC_GROUP_<ROLE> cluster vars, which flux-manifests' rbac component binds
    Role/ClusterRoleBindings against - the manifests contract carries only group names, never the subject type
    behind them.
    principal_arn is optional: set it for an IAM Identity Center permission-set role (or any IAM role/user) that
    should get an EKS access entry mapping it onto the group. Leave it null when the group is populated purely
    through OIDC federation instead (sso.kubectl) - no access entry is created, and the group name only ever
    reaches Kubernetes via the groups claim dex asserts. A role can rely on both mechanisms at once by giving the
    IAM principal and the OIDC-asserted group the same literal group name.
  EOT
  type = object({
    enabled = optional(bool, false)
    groups = optional(object({
      viewers    = optional(object({ principal_arn = optional(string), group = optional(string, "platform:viewers") }))
      developers = optional(object({ principal_arn = optional(string), group = optional(string, "platform:developers") }))
      devops     = optional(object({ principal_arn = optional(string), group = optional(string, "platform:devops") }))
      admins     = optional(object({ principal_arn = optional(string), group = optional(string, "platform:admins") }))
    }), {})
  })
  nullable = false
  default  = {}

  validation {
    condition     = var.rbac.enabled || alltrue([for role in values(var.rbac.groups) : role == null])
    error_message = "rbac.groups requires rbac.enabled - without it no access entries are created and the group subjects would bind nothing."
  }

  validation {
    condition = alltrue([
      for role in values(var.rbac.groups) :
      role == null || role.principal_arn == null || can(regex("^arn:aws[a-z-]*:iam::[0-9]{12}:(role|user)/", role.principal_arn))
    ])
    error_message = "Each rbac.groups entry's principal_arn, when set, must be an IAM role or user ARN."
  }
}

variable "cluster_admin_principals" {
  description = <<-EOT
    IAM principal ARNs granted AmazonEKSClusterAdminPolicy through an access entry - the break-glass and CI identities.
    The creating principal is admitted automatically (bootstrap_cluster_creator_admin_permissions), so this is for
    everyone else.
  EOT
  type        = set(string)
  nullable    = false
  default     = []
}

variable "system_node_group" {
  description = <<-EOT
    The always-on managed node group platform controllers pin to (label role=system): flux, kyverno, cert-manager,
    external-dns, karpenter and the rest. These counts are CLUSTER-WIDE totals, not per-zone.
    Sizing must fit the whole platform tier - Karpenter only provisions workload capacity, never this.
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
    condition     = contains(["ON_DEMAND", "SPOT"], var.system_node_group.capacity_type)
    error_message = "system_node_group.capacity_type must be ON_DEMAND or SPOT (the platform tier should stay ON_DEMAND)."
  }
}

variable "node_groups" {
  description = <<-EOT
    Additional managed node groups, keyed by name ("system" is reserved for the platform tier). Most clusters need
    none - Karpenter provisions workload capacity - so this exists for capacity Karpenter cannot express: static
    pools with extra security groups, or Windows nodes.
    Each group takes the system_node_group sizing arguments plus: security_group_ids, attached to the group's nodes
    through its launch template alongside the EKS-managed cluster security group every node wears; ami_type,
    selecting the AMI family (null is the EKS AL2023 default); labels and taints for scheduling.
    Linux groups get the Cilium agent-not-ready bootstrap taint automatically, exactly like the system group.
    WINDOWS_* groups instead run the AMI's bundled vpc-shared-eni CNI (Cilium has no Windows datapath): they join
    through a dedicated windows node role and EC2_WINDOWS access entry this module creates on demand, they skip the
    Cilium taint, and their pods are addressed by EKS's control-plane VPC resource controller - which only hands out
    addresses once Windows IPAM is enabled (the amazon-vpc-cni ConfigMap in kube-system with
    enable-windows-ipam: "true", a Kubernetes object this module does not manage; ship it through flux).
  EOT
  type = map(object({
    instance_types     = optional(list(string), ["m7i.large"])
    capacity_type      = optional(string, "ON_DEMAND")
    min_size           = optional(number, 2)
    max_size           = optional(number, 4)
    desired_size       = optional(number, 2)
    disk_size_gib      = optional(number, 50)
    security_group_ids = optional(set(string), [])
    ami_type           = optional(string)
    labels             = optional(map(string), {})
    taints = optional(list(object({
      key    = string
      value  = optional(string)
      effect = string
    })), [])
  }))
  nullable = false
  default  = {}

  validation {
    condition     = !contains(keys(var.node_groups), "system")
    error_message = "node_groups must not use the key \"system\" - the platform tier's group is configured through system_node_group."
  }

  validation {
    condition     = alltrue([for name in keys(var.node_groups) : can(regex("^[a-z]([a-z0-9-]{0,36})$", name))])
    error_message = "node_groups keys must be short lowercase RFC-1035 labels (they prefix the node group and launch template names)."
  }
}

variable "cilium" {
  description = <<-EOT
    The CNI. Cilium runs in ENI mode with the AWS VPC CNI never installed, so pods hold routable VPC addresses exactly
    as they would under vpc-cni, and kube-proxy is replaced by Cilium's eBPF datapath. This is the one chart terraform
    installs: it must exist before the first node can report Ready, so flux cannot own the bootstrap. The release is
    bootstrap-only (ignore_changes) and the stack's cilium component adopts it afterwards.

    operator_pod_identity moves the ENI permissions off the node role and onto a Pod Identity association. Off by
    default: in ENI mode the agent cannot report Ready until the operator has attached ENIs, but the pod-identity-agent
    addon only installs once nodes exist - a bootstrap cycle. Turn it on against a running cluster if the node-role
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
    splitList, exactly as PLATFORM_COMPONENTS already is).

    There is deliberately no min_nodes: Karpenter scales from zero on pending pods and offers only ceilings
    (spec.limits). The cluster's floor is system_node_group.min_size.
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
    error_message = "karpenter.node_pool must select instances by category or by family - both cannot be empty."
  }
}

variable "addons" {
  description = <<-EOT
    EKS add-ons. Everything AWS offers managed is taken managed, and only the rest reaches the cluster through flux.
    vpc-cni and kube-proxy are absent by construction - Cilium replaces both, and
    bootstrap_self_managed_addons is off so EKS never installs them.

    aws-secrets-store-csi-driver-provider bundles the Secrets Store CSI driver alongside the AWS provider, so only the
    secrets-store-sync-controller (the SecretSync CRD) remains a flux component. metrics-server is a COMMUNITY add-on:
    AWS supports its lifecycle, not the software. cert-manager and external-dns are community add-ons too but stay
    flux-managed on purpose - as add-ons they would pull images from AWS's registry, breaking the invariant that
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
    composing this by hand - `module.cache.platform_registry` (a pull-through cache in the cluster's own account, the
    default posture) or `module.store.platform_registry` (reading a central store directly, which additionally requires
    the store to admit this cluster's registry_reader_principals). Both modules emit exactly this shape, so the
    is_pull_through_cache flag is never guessed.

    url is <account>.dkr.ecr.<region>.amazonaws.com/<prefix>. is_pull_through_cache adds ecr:CreateRepository and
    ecr:BatchImportUpstreamImage to every puller's grant - a cache materialises each repository on its FIRST pull, so
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
    Cosign verification identity for every platform artifact - exactly one of two modes.

    KEYLESS (subjects set, kms_key_arn null): Go regexps matched against the Fulcio certificate of GitHub Actions OIDC
    signatures. The artifact-store module's signed_identity_subjects output provides the subjects; the issuer default
    matches GitHub Actions. Cloud agnostic - the signing identities are GitHub's, not AWS's, so the same values serve
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
    error_message = "kms_key_arn and the keyless subjects are mutually exclusive - verification is keyless or KMS, never both."
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
    grants and the DNS_* / PLATFORM_DOMAIN cluster vars. The PUBLIC flavour of the zone is always required - Let's
    Encrypt resolves cert-manager's DNS-01 challenges over public DNS, so even a fully internal cluster keeps a
    public zone for certificate issuance. private_zone adds the split-horizon flavour: a private zone under the
    same name, associated with the cluster VPC, shadowing the public one for in-VPC resolution - required when the
    Gateway is private (gateway.private), and equally valid alongside a public Gateway endpoint. host optionally
    narrows the served host below the zone apex - it is published as PLATFORM_DOMAIN, the host the platform's
    wildcard Gateway listener and every application route hang off.
  EOT
  type = object({
    zone_name    = optional(string)
    private_zone = optional(bool, false)
    host         = optional(string)
    acme_email   = optional(string)
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
    The platform Gateway's static addresses. One Cilium Gateway materialises one LoadBalancer Service (an NLB), and
    every HTTPRoute hostname shares its address - so the EIPs are reserved once, one per public subnet the NLB spans,
    and new hosts are manifests-only. Reserving them here (default) keeps them outside the disposable cluster's
    lifecycle, so destroy/recreate serves the same addresses; alternatively reference existing allocations by id.

    private flips the NLB internal: it spans the node subnets instead of the public ones and takes no Elastic IPs
    (internal NLBs cannot carry them), so the whole EIP surface above goes inert. A private Gateway is only
    reachable through in-VPC resolution, which is what requires dns.private_zone - the public zone still exists,
    carrying only the cert-manager DNS-01 challenges that certificate issuance needs.

    install_crds publishes GATEWAY_API_CRDS, which has the flux-manifests gateway component install the Gateway API
    CRDs (the standard-channel set Cilium requires): EKS ships none today, and Cilium implements the API without
    owning its CRDs. Flip it off if the CRDs arrive some other way - most likely the day EKS installs them as managed
    cluster furniture - and the manifests orphan them rather than pruning (deleting a CRD deletes every Gateway and
    HTTPRoute with it).
  EOT
  type = object({
    private           = optional(bool, false)
    reserve_static_ip = optional(bool, true)
    allocation_ids    = optional(set(string), [])
    install_crds      = optional(bool, true)
  })
  nullable = false
  default  = {}

  validation {
    condition     = !var.gateway.reserve_static_ip || length(var.gateway.allocation_ids) == 0
    error_message = "gateway.allocation_ids references EXISTING addresses, so it requires reserve_static_ip = false."
  }

  validation {
    condition     = var.gateway.private || !var.gateway.reserve_static_ip || length(var.network.public_subnet_ids) > 0
    error_message = "gateway.reserve_static_ip needs network.public_subnet_ids - one EIP is reserved per subnet the Gateway's NLB spans."
  }

  validation {
    condition     = !var.gateway.private || length(var.gateway.allocation_ids) == 0
    error_message = "gateway.private is an internal NLB, which cannot carry Elastic IPs - allocation_ids requires a public Gateway."
  }

  validation {
    condition     = !var.gateway.private || var.dns.private_zone
    error_message = "gateway.private needs dns.private_zone - an internal Gateway is only reachable through the private zone's in-VPC resolution."
  }
}

variable "workload_identity" {
  description = <<-EOT
    Namespace/service-account pairs the PLATFORM workload IAM roles bind to (EKS Pod Identity associations, except
    the podless secret_readers which bind through IRSA) - the terraform <-> platform-manifests contract, cloud-neutral
    in shape so every cluster tracks the same manifests. Override the platform pairs only to follow a manifests
    change; application grants arrive through workload_grants instead.
    secret_readers lists the KSAs the secrets-store-sync-controller runs as when materialising a consumer's
    SecretSync objects (podless, so IRSA rather than Pod Identity): every application that syncs secrets names its
    <namespace>/<service-account> pair here (an application module's secret_readers output), on top of the pairs the
    SSO surface derives itself. Each becomes a <name>-secrets-<ns>-<sa> role, published as SECRETS_ROLE_PREFIX.
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
    # the KSAs the secrets-store-sync-controller runs as when materialising
    # a consumer's SecretSync objects, beyond the pairs the SSO surface
    # derives itself (sso.tf / iam.tf) - applications declare theirs here
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
    Pass the workspace's full remote-write URL (…/workspaces/ws-…/api/v1/remote_write) - the manifests hand it to the
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
    Prefix for every Secrets Manager secret name the platform and its applications sync, published as the
    SECRET_PREFIX cluster var. Lets multiple clusters share one account with distinct secrets; the modules/sso-secrets
    instantiation (a durable root, holding the out-of-band dex connector credentials) and every application module
    creating containers must use the same prefix. Include the trailing separator (e.g. 'platform-x-'); empty keeps
    the unprefixed names.
  EOT
  type        = string
  default     = null

  validation {
    condition     = var.secret_prefix == null || can(regex("^[A-Za-z0-9/_+=.@-]*$", var.secret_prefix))
    error_message = "secret_prefix must use Secrets Manager name characters only ([A-Za-z0-9/_+=.@-])."
  }
}

variable "platform_components" {
  description = <<-EOT
    The platform-manifests electable-tier components (short names: flux-web, arc) this cluster elects, published
    as the PLATFORM_COMPONENTS cluster var. The platform entrypoint's ResourceSet ranges over the election: an
    elected component gets its own OCIRepository (oci://<registry>/manifests/<name>) and Kustomization. Electing
    none is explicit - set []. dex is not elected here: it deploys exactly when sso is enabled, and without it the
    elected components still run, just with no SSO auth and no human-facing HTTPRoute (kubectl port-forward to
    reach). The core tier (flux, cilium, kyverno, kyverno-policies, cert-manager, cert-manager-issuers,
    external-dns, gateway, aws-load-balancer-controller, rbac, secret-sync) is never electable. Applications are
    not components: they arrive through var.applications as their own images.
  EOT
  type        = set(string)
  nullable    = false
  default     = ["flux-web"]

  validation {
    condition = alltrue([
      for component in var.platform_components : contains(["flux-web", "arc"], component)
    ])
    error_message = "platform_components entries must be electable-tier short names: flux-web, arc (dex rides the sso toggle; the core tier is never electable)."
  }
}

variable "workload_grants" {
  description = <<-EOT
    Application workload IAM grants, keyed by a short name: each entry becomes one IAM role (<name>-<key>) carrying
    the given policy document, bound to its namespace/service-account pair through an EKS Pod Identity association.
    This is how an application module hands its cloud permissions to the cluster (e.g. a model-invoke grant for an
    egress broker): the module emits the map, the root wires it here, and nothing application-specific lives in this
    module. The platform's own pairs (external-dns, cert-manager, kyverno, the load-balancer controller, karpenter,
    otel-collector) are fixed by workload_identity and are not declared here. Podless secret-sync readers are the
    one grant shape this map cannot express - list those under workload_identity.secret_readers instead.
  EOT
  type = map(object({
    namespace       = string
    service_account = string
    policy          = string
  }))
  nullable = false
  default  = {}

  validation {
    condition     = alltrue([for key in keys(var.workload_grants) : can(regex("^[a-z]([a-z0-9-]{0,38})$", key))])
    error_message = "workload_grants keys must be short lowercase RFC-1035 labels (they suffix the IAM role name <name>-<key>)."
  }

  validation {
    condition = alltrue([
      for key in keys(var.workload_grants) :
      !contains(["external-dns", "cert-manager", "otel-collector", "aws-load-balancer-controller"], key)
      && !startswith(key, "kyverno-") && !startswith(key, "secrets-")
    ])
    error_message = "workload_grants keys must not collide with the platform grants (external-dns, cert-manager, otel-collector, aws-load-balancer-controller, kyverno-*) or the secrets-* reader roles."
  }

  validation {
    condition     = alltrue([for grant in values(var.workload_grants) : can(jsondecode(grant.policy))])
    error_message = "Each workload_grants entry's policy must be an IAM policy document (JSON)."
  }
}

variable "applications" {
  description = <<-EOT
    Application manifest images this cluster seeds, keyed by the application's short name. Each entry creates a
    bootstrap-only seed in flux-system (a ResourceSetInputProvider and ResourceSet named <key>-manifests) that
    resolves the newest tag matching semver, verifies the image's cosign signature and applies path from it as
    Kustomization <key>; the image ships the same two seed objects under flux/ and owns them from its first
    reconcile, so a new application release never needs a terraform apply. Removing a key uninstalls the seed and
    prunes the application. The entry is applied once and then ignored (ignore_changes), exactly like the
    flux-operator and flux-instance releases.
      - url: the image without a tag or digest. An ECR url must live under platform_registry.url (the flux
        controllers pull it with their Pod Identity and list its tags through the ECR API); any other registry is
        listed and pulled generically, optionally with pull_secret (a kubernetes.io/dockerconfigjson Secret in
        flux-system that both the tag listing and the pull read).
      - semver: the tag range the seed follows (default >=0.0.0); a range matching no tag prunes the application.
      - path: the Kustomization path inside the image (default ./deploy/<flux.sync.path>, the same per-cloud tree
        selector the platform uses, published as PLATFORM_TREE).
      - depends_on: platform Kustomizations the application waits for (default kyverno-policies).
      - verify: keyless (subject, a Fulcio certificate-subject regexp; issuer defaults to signed_identity.issuer)
        XOR keyed (the cosign-pub public-key Secret, KMS mode only).
      - dex_clients: OIDC relying parties the application registers with the platform's dex, keyed by client id.
        A confidential client (public = false) gets a generated secret in Secrets Manager
        (<secret_prefix>dex-client-<id>, rotated by bumping version) that dex and the client's readers (the
        application's secret-sync KSAs, as <namespace>/<service-account>) may read; a public client (PKCE) gets
        none. Every client is published in DEX_CLIENTS. Requires sso.enabled.
    Application vars ride separately in application_vars, so a composite image's inner applications can each have
    their own ConfigMap.
  EOT
  type = map(object({
    url        = string
    semver     = optional(string, ">=0.0.0")
    path       = optional(string)
    interval   = optional(string, "30m")
    depends_on = optional(set(string), ["kyverno-policies"])
    verify = object({
      issuer  = optional(string)
      subject = optional(string)
      keyed   = optional(bool, false)
    })
    pull_secret = optional(string)
    prune       = optional(bool, true)
    wait        = optional(bool, true)
    timeout     = optional(string, "5m")
    dex_clients = optional(map(object({
      name          = optional(string)
      public        = optional(bool, false)
      redirect_uris = optional(list(string), [])
      readers       = optional(set(string), [])
      version       = optional(number, 1)
    })), {})
  }))
  nullable = false
  default  = {}

  validation {
    condition     = alltrue([for key in keys(var.applications) : can(regex("^[a-z]([a-z0-9-]{0,30}[a-z0-9])?$", key))])
    error_message = "applications keys must be short lowercase RFC-1035 labels of at most 32 characters (they name the seed objects <key>-manifests and Kustomization <key>)."
  }

  validation {
    condition = alltrue([
      for key in keys(var.applications) : !contains([
        "flux-system", "flux", "cilium", "kyverno", "kyverno-policies", "cert-manager", "cert-manager-issuers",
        "external-dns", "gateway", "gateway-api-crds", "aws-load-balancer-controller", "rbac", "secret-sync", "dex",
        "flux-web", "arc", "platform", "cluster-inputs",
      ], key)
    ])
    error_message = "applications keys must not reuse a platform Kustomization or component name (flux-system, flux, cilium, kyverno, kyverno-policies, cert-manager, cert-manager-issuers, external-dns, gateway, gateway-api-crds, aws-load-balancer-controller, rbac, secret-sync, dex, flux-web, arc, platform, cluster-inputs) - the registry and the flux-system namespace are one flat namespace."
  }

  validation {
    condition = alltrue([
      for app in values(var.applications) : can(regex("^oci://[a-z0-9.-]+(:[0-9]+)?(/[a-z0-9._-]+)+$", app.url))
    ])
    error_message = "Each applications entry's url must be oci://<host>/<repository> with no tag or digest (the seed resolves the tag from semver)."
  }

  validation {
    condition = alltrue([
      for app in values(var.applications) :
      !can(regex("^oci://[0-9]{12}\\.dkr\\.ecr\\.", app.url)) || startswith(app.url, "oci://${var.platform_registry.url}/")
    ])
    error_message = "An ECR-hosted applications url must live under platform_registry.url - the flux controllers hold pull rights on that prefix alone, and its tags are listed through the ECR API with the same identity."
  }

  validation {
    condition = alltrue([
      for app in values(var.applications) : (app.verify.subject != null) != app.verify.keyed
    ])
    error_message = "Each applications entry's verify must be keyless (subject) or keyed, never both or neither - an unverified application image is never applied."
  }

  validation {
    condition = alltrue([
      for app in values(var.applications) : !app.verify.keyed || var.signed_identity.kms_key_arn != null
    ])
    error_message = "applications[*].verify.keyed requires signed_identity.kms_key_arn: the cosign-pub Secret only exists in KMS mode."
  }

  validation {
    condition = alltrue([
      for app in values(var.applications) : app.verify.subject == null || app.verify.issuer != null || var.signed_identity.kms_key_arn == null
    ])
    error_message = "A keyless applications entry on a KMS-mode cluster must set verify.issuer explicitly - there is no keyless issuer to default onto."
  }

  validation {
    condition = alltrue([
      for app in values(var.applications) : app.pull_secret == null || !startswith(app.url, "oci://${var.platform_registry.url}/")
    ])
    error_message = "applications[*].pull_secret only applies to images outside the platform registry - the platform registry is pulled with the flux controllers' Pod Identity."
  }

  validation {
    condition = alltrue([
      for app in values(var.applications) : length(app.dex_clients) == 0 || var.sso.enabled
    ])
    error_message = "applications[*].dex_clients requires sso.enabled - without dex there is nothing to register a client with."
  }

  validation {
    condition = alltrue(flatten([
      for app in values(var.applications) : [
        for id in keys(app.dex_clients) : can(regex("^[a-z0-9-]+$", id)) && id != "flux-web" && id != var.sso.kubectl.client_id
      ]
    ]))
    error_message = "applications[*].dex_clients ids must match ^[a-z0-9-]+$ and must not reuse the platform's own client ids (flux-web, sso.kubectl.client_id)."
  }

  validation {
    condition = length(flatten([for app in values(var.applications) : keys(app.dex_clients)])) == length(distinct(flatten([
      for app in values(var.applications) : keys(app.dex_clients)
    ])))
    error_message = "applications[*].dex_clients ids must be unique across every application - dex has one flat client namespace."
  }

  validation {
    condition = alltrue(flatten([
      for app in values(var.applications) : [
        for client in values(app.dex_clients) : [
          for reader in client.readers : contains([
            for pair in var.workload_identity.secret_readers : "${pair.namespace}/${pair.service_account}"
          ], reader)
        ]
      ]
    ]))
    error_message = "Each applications[*].dex_clients readers entry must be a <namespace>/<service-account> pair listed in workload_identity.secret_readers - only a declared secret-sync reader has a role to admit."
  }

  validation {
    condition = alltrue(flatten([
      for app in values(var.applications) : [
        for client in values(app.dex_clients) : !client.public || length(client.readers) == 0
      ]
    ]))
    error_message = "A public dex client has no secret, so applications[*].dex_clients readers only applies to confidential clients."
  }
}

variable "application_vars" {
  description = <<-EOT
    Per-application substitution values, keyed by application short name: each entry is rendered as the <key>-vars
    ConfigMap in flux-system (terraform-reconciled through cluster-inputs, so changes flow through applies), which the
    application's Kustomization substitutes from beside cluster-vars. Keys are top-level rather than nested in
    applications so a composite image's inner applications can each have their own ConfigMap. Keys must be
    SCREAMING_SNAKE_CASE, matching the substitution syntax; an application's own module typically emits this map.
  EOT
  type        = map(map(string))
  nullable    = false
  default     = {}

  validation {
    condition     = alltrue([for key in keys(var.application_vars) : can(regex("^[a-z]([a-z0-9-]{0,30}[a-z0-9])?$", key))])
    error_message = "application_vars keys must be short lowercase RFC-1035 labels (they name the <key>-vars ConfigMap)."
  }

  validation {
    condition = alltrue(flatten([
      for vars in values(var.application_vars) : [for name in keys(vars) : can(regex("^[A-Z][A-Z0-9_]*$", name))]
    ]))
    error_message = "application_vars entries must use SCREAMING_SNAKE_CASE keys (^[A-Z][A-Z0-9_]*$), the shape flux substitution reads."
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
    clients holds the per-client knobs for the platform's own generated relying-party pair (key: flux-web) -- today
    just version, the client secret's rotation counter (absent clients sit at 1): bump it to mint a new client secret;
    the raw dex-client-* secret and any config document embedding the same value rewrite in one apply, so the pair
    cannot drift (then restart dex: it reads client secrets from env at startup). Application clients carry their
    own version under applications[*].dex_clients; every client, platform or application, is published in
    DEX_CLIENTS for the dex component to render.
    kubectl federates the EKS API server itself to dex (an aws_eks_identity_provider_config), so kubectl can
    authenticate humans through Okta/whatever upstream connector without an IAM principal at all -- pair it with an
    rbac.groups entry that has no principal_arn, just the OIDC-asserted group name. client_id names dex's PUBLIC
    static client for this flow (no secret: kubectl's OIDC device/PKCE flow can't hold one), rendered by
    flux-manifests' dex component once elected. groups_claim_prefix is prepended to every group dex asserts before
    the API server evaluates RBAC (AWS requires a non-empty prefix, so a spoofed claim can't collide with system:
    or IAM-sourced group names) -- an rbac.groups.*.group value reached this way must carry the same prefix
    literally, e.g. group = "oidc:GRP_PATCHY_NONPROD_ADMIN" when groups_claim_prefix is the default "oidc:".
    BOOTSTRAP ORDER: unlike the dex relying parties above, the identity provider config is validated by the EKS API
    at creation time -- it calls the issuer's discovery endpoint. On a cluster's first apply dex isn't deployed yet
    (flux installs it after the cluster exists), so this resource can only be created once dex is live and serving
    over its Gateway route: expect a first apply with sso.kubectl.enabled = false, then a second apply once flux
    has converged to turn it on.
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
    kubectl = optional(object({
      enabled             = optional(bool, false)
      client_id           = optional(string, "kubectl-oidc")
      redirect_uris       = optional(list(string), ["http://localhost:8000/callback"])
      groups_claim_prefix = optional(string, "oidc:")
    }), {})
  })
  nullable = false
  default  = {}

  validation {
    condition     = alltrue([for client in keys(var.sso.clients) : contains(["flux-web"], client)])
    error_message = "sso.clients keys must be platform client ids: flux-web (application clients are declared under applications[*].dex_clients)."
  }

  validation {
    condition     = !var.sso.enabled || var.sso.connector != null
    error_message = "sso.enabled requires sso.connector -- a dex deployment with no upstream connector is a footgun (nobody can authenticate)."
  }

  validation {
    condition     = var.sso.enabled || !var.sso.kubectl.enabled
    error_message = "sso.kubectl.enabled requires sso.enabled -- kubectl cannot federate to a dex that isn't deployed."
  }

  validation {
    condition     = var.sso.kubectl.groups_claim_prefix != ""
    error_message = "sso.kubectl.groups_claim_prefix must be non-empty -- EKS requires a groups prefix on OIDC identity provider configs, to keep an asserted claim from colliding with system: or IAM-sourced group names."
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
    Flux bootstrap knobs. Chart repositories, the distribution registry and the sync url default onto platform_registry
    (sync.url defaults to oci://<registry>/manifests/platform, the platform entrypoint image, and is published as
    FLUX_SYNC_URL - the platform's flux component asserts it on the FluxInstance, which is how a running cluster is
    re-pointed); sync.ref picks the release channel (stable, staging, or edge for dev clusters tracking trunk -- pair
    edge with the manifests_edge signing subject), which the entrypoint pins every component to unless a
    <NAME>_MANIFESTS_REF cluster var overrides one; sync.path selects the per-cloud tree ("aws" -- requires
    platform-manifests >= 4.0.0), published as PLATFORM_TREE so applications select the same tree.
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
      path     = optional(string, "aws")
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
