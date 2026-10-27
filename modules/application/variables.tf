# Copyright 2026 BitWise Media Group Ltd
# SPDX-License-Identifier: MIT

variable "name" {
  description = <<-EOT
    The application's short name: the seed release is application-<name>, the seed objects <name>-manifests, the
    Kustomization <name> and the vars ConfigMap <name>-vars, all in the cluster's flux namespace. Must not be seeded
    by the cluster root as well (an applications key there) - an application lives in exactly one root.
  EOT
  type        = string
  nullable    = false

  validation {
    condition     = can(regex("^[a-z]([a-z0-9-]{0,30}[a-z0-9])?$", var.name))
    error_message = "name must be a short lowercase RFC-1035 label of at most 32 characters (it names the seed objects <name>-manifests and Kustomization <name>)."
  }

  validation {
    condition = !contains([
      "flux-system", "flux", "cilium", "kyverno", "kyverno-policies", "cert-manager", "cert-manager-issuers",
      "external-dns", "gateway", "gateway-api-crds", "aws-load-balancer-controller", "rbac", "secret-sync", "dex",
      "flux-web", "arc", "platform", "cluster-inputs",
    ], var.name)
    error_message = "name must not reuse a platform Kustomization or component name (flux-system, flux, cilium, kyverno, kyverno-policies, cert-manager, cert-manager-issuers, external-dns, gateway, gateway-api-crds, aws-load-balancer-controller, rbac, secret-sync, dex, flux-web, arc, platform, cluster-inputs) - the registry and the flux namespace are one flat namespace."
  }
}

variable "cluster" {
  description = <<-EOT
    The cluster to publish to: pass the cluster root's application_target output verbatim (through
    terraform_remote_state or any other channel) rather than composing it by hand.
      - name: the EKS cluster name; prefixes every IAM role (<name>-<key>, <name>-secrets-<ns>-<sa>).
      - namespace: the flux namespace the seed and vars live in.
      - platform_registry: the platform registry url (<account>.dkr.ecr.<region>.amazonaws.com/<prefix>); images
        beneath it are listed and pulled with the flux controllers' Pod Identity.
      - tree: the per-cloud tree the cluster syncs (flux.sync.path), the default image path ./deploy/<tree>.
      - issuer: the keyless signing issuer, the default for image.verify.issuer; null on a KMS-keyed cluster.
      - keyed: whether the cluster verifies with a KMS signing key (the cosign-pub Secret exists only then).
      - oidc_provider_arn / oidc_issuer: the cluster's IRSA OIDC provider and its issuer host (no scheme), which
        the podless secret-sync reader roles trust.
      - secret_prefix: the SECRET_PREFIX the readers' Secrets Manager grant is scoped to.
      - node_role_arn / node_subnet_ids / cluster_security_group_id: the Linux node role (admitted through the
        cluster root's EC2_LINUX access entry), the node subnets and the EKS-managed cluster security group that
        node_groups join with. Optional so an older application_target still plans; node_groups requires them.
  EOT
  type = object({
    name              = string
    namespace         = string
    platform_registry = string
    tree              = string
    issuer            = optional(string)
    keyed             = bool
    oidc_provider_arn = string
    oidc_issuer       = string
    secret_prefix     = string

    node_role_arn             = optional(string)
    node_subnet_ids           = optional(set(string), [])
    cluster_security_group_id = optional(string)
  })
  nullable = false

  validation {
    condition     = var.cluster.keyed || var.cluster.issuer != null
    error_message = "cluster.issuer is required on a keyless cluster (cluster.keyed = false) - it is the default issuer every keyless image verifies against."
  }
}

variable "image" {
  description = <<-EOT
    The application's manifest image, exactly as a cluster root applications entry (minus the dex clients that
    have moved to DexClient objects). Becomes one bootstrap-only seed: a ResourceSetInputProvider and ResourceSet
    named <name>-manifests that resolve the newest tag matching semver, verify the image's cosign signature and
    apply path from it as Kustomization <name>. The image ships the same two seed objects under flux/ and owns them
    from its first reconcile, so a new application release never needs a terraform apply; the seed is applied once
    and then ignored (ignore_changes). Destroying the module uninstalls the seed and prunes the application.
      - url: the image without a tag or digest. An ECR url must live under cluster.platform_registry (the flux
        controllers pull it with their Pod Identity and list its tags through the ECR API); any other registry is
        listed and pulled generically, optionally with pull_secret (a kubernetes.io/dockerconfigjson Secret in the
        flux namespace that both the tag listing and the pull read).
      - semver: the tag range the seed follows (default >=0.0.0); a range matching no tag prunes the application.
      - path: the Kustomization path inside the image (default ./deploy/<cluster.tree>).
      - depends_on: platform Kustomizations the application waits for (default kyverno-policies).
      - verify: keyless (subject, a Fulcio certificate-subject regexp; issuer defaults to cluster.issuer) XOR keyed
        (the cosign-pub public-key Secret, KMS-keyed clusters only).
  EOT
  type = object({
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
  })
  nullable = false

  validation {
    condition     = can(regex("^oci://[a-z0-9.-]+(:[0-9]+)?(/[a-z0-9._-]+)+$", var.image.url))
    error_message = "image.url must be oci://<host>/<repository> with no tag or digest (the seed resolves the tag from semver)."
  }

  validation {
    condition     = !can(regex("^oci://[0-9]{12}\\.dkr\\.ecr\\.", var.image.url)) || startswith(var.image.url, "oci://${var.cluster.platform_registry}/")
    error_message = "An ECR-hosted image.url must live under cluster.platform_registry - the flux controllers hold pull rights on that prefix alone, and its tags are listed through the ECR API with the same identity."
  }

  validation {
    condition     = (var.image.verify.subject != null) != var.image.verify.keyed
    error_message = "image.verify must be keyless (subject) or keyed, never both or neither - an unverified application image is never applied."
  }

  validation {
    condition     = !var.image.verify.keyed || var.cluster.keyed
    error_message = "image.verify.keyed requires a KMS-keyed cluster (cluster.keyed): the cosign-pub Secret only exists in KMS mode."
  }

  validation {
    condition     = var.image.verify.subject == null || var.image.verify.issuer != null || !var.cluster.keyed
    error_message = "A keyless image on a KMS-keyed cluster must set image.verify.issuer explicitly - there is no keyless issuer to default onto."
  }

  validation {
    condition     = var.image.pull_secret == null || !startswith(var.image.url, "oci://${var.cluster.platform_registry}/")
    error_message = "image.pull_secret only applies to images outside the platform registry - the platform registry is pulled with the flux controllers' Pod Identity."
  }
}

variable "vars" {
  description = <<-EOT
    The application's own substitution values, rendered as the <name>-vars ConfigMap in the flux namespace, which
    its Kustomization substitutes from beside cluster-vars. Terraform-reconciled (the inputs release), so changes
    flow through this root's applies. Keys must be SCREAMING_SNAKE_CASE, matching the substitution syntax.
  EOT
  type        = map(string)
  nullable    = false
  default     = {}

  validation {
    condition     = alltrue([for key in keys(var.vars) : can(regex("^[A-Z][A-Z0-9_]*$", key))])
    error_message = "vars must use SCREAMING_SNAKE_CASE keys (^[A-Z][A-Z0-9_]*$), the shape flux substitution reads."
  }
}

variable "namespaces" {
  description = <<-EOT
    Namespaces created ahead of the application (e.g. so out-of-band secrets can land before Flux deploys into
    them), labelled app.kubernetes.io/managed-by: application-<name>; the image's kustomizations adopt them via
    server-side apply. A namespace the cluster root already pre-creates (flux.namespaces) cannot be listed here too.
  EOT
  type        = set(string)
  nullable    = false
  default     = []

  validation {
    condition     = alltrue([for namespace in var.namespaces : can(regex("^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$", namespace))])
    error_message = "namespaces entries must be RFC-1123 labels."
  }
}

variable "workload_grants" {
  description = <<-EOT
    Workload IAM grants, keyed by a short name: each entry becomes one IAM role (<cluster.name>-<key>) carrying the
    given policy document, bound to its namespace/service-account pair through an EKS Pod Identity association -
    the same shape and role names as the cluster root's workload_grants. Podless secret-sync readers can't bind
    through Pod Identity; list those under secret_readers instead.
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
    error_message = "workload_grants keys must be short lowercase RFC-1035 labels (they suffix the IAM role name <cluster>-<key>)."
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

variable "secret_readers" {
  description = <<-EOT
    The KSAs the secrets-store-sync-controller runs as when materialising this application's SecretSync objects.
    Each pair gets a podless IRSA reader role <cluster.name>-secrets-<namespace>-<service_account>, trusted by the
    cluster's OIDC provider and allowed to read every Secrets Manager secret under cluster.secret_prefix - the role
    the manifests reach as $${SECRETS_ROLE_PREFIX}<namespace>-<service_account>. A pair the cluster root already
    lists (workload_identity.secret_readers, or one the SSO surface derives) cannot be listed here too.
  EOT
  type = set(object({
    namespace       = string
    service_account = string
  }))
  nullable = false
  default  = []
}

variable "node_groups" {
  description = <<-EOT
    Managed node groups the application brings with it, keyed by a short name: capacity Karpenter cannot express, such
    as a static pool of another architecture that only this application's pods tolerate. Each group is named
    <name>-<key> (a name prefix, so a replacement never collides with the group it supersedes), joins with the
    cluster's Linux node role into its node subnets wearing the EKS-managed cluster security group, and takes the
    cluster root's node_groups sizing arguments plus ami_type (null is the EKS AL2023 default for the instance
    architecture; AL2023_ARM_64_STANDARD for Graviton), labels and taints. Every group gets the Cilium
    agent-not-ready bootstrap taint exactly as the cluster root's groups do; add a taint of your own to keep other
    workloads off it. Linux only: Windows groups need the cluster root's windows node role.
  EOT
  type = map(object({
    instance_types = optional(list(string), ["m7i.large"])
    capacity_type  = optional(string, "ON_DEMAND")
    min_size       = optional(number, 2)
    max_size       = optional(number, 4)
    desired_size   = optional(number, 2)
    disk_size_gib  = optional(number, 50)
    ami_type       = optional(string)
    labels         = optional(map(string), {})
    taints = optional(list(object({
      key    = string
      value  = optional(string)
      effect = string
    })), [])
  }))
  nullable = false
  default  = {}

  validation {
    condition     = alltrue([for key in keys(var.node_groups) : can(regex("^[a-z]([a-z0-9-]*[a-z0-9])?$", key)) && length("${var.name}-${key}") <= 37])
    error_message = "node_groups keys must be lowercase RFC-1035 labels, and <name>-<key> must be at most 37 characters (it prefixes the node group and launch template names)."
  }

  validation {
    condition     = alltrue([for group in values(var.node_groups) : startswith(coalesce(group.ami_type, "AL2023_"), "AL2023_")])
    error_message = "node_groups ami_type must be an AL2023_* EKS AMI type (or null for the EKS default) - Windows groups need the cluster root's windows node role."
  }

  validation {
    condition     = length(var.node_groups) == 0 || (var.cluster.node_role_arn != null && var.cluster.cluster_security_group_id != null && length(var.cluster.node_subnet_ids) > 0)
    error_message = "node_groups needs cluster.node_role_arn, cluster.node_subnet_ids and cluster.cluster_security_group_id - pass an application_target from a cluster module that publishes them."
  }
}

variable "tags" {
  description = "Tags applied to the IAM roles and Pod Identity associations this module creates."
  type        = map(string)
  nullable    = false
  default     = {}
}
