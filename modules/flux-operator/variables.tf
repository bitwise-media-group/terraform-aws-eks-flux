# Copyright 2026 BitWise Media Group Ltd
# SPDX-License-Identifier: MIT

variable "cluster_name" {
  description = "Name of the EKS cluster the Pod Identity associations are created on."
  type        = string
  nullable    = false
}

variable "namespace" {
  description = "Namespace for the flux-operator and Flux controllers."
  type        = string
  nullable    = false
  default     = "flux-system"
}

variable "operator_chart" {
  description = <<-EOT
    flux-operator helm chart location: the platform registry's charts/flux-operator, published by flux-containers
    (the artifact store must be populated before the first cluster bootstraps). A null version installs the latest
    available at create and pins it in state — later applies don't auto-upgrade.
  EOT
  type = object({
    repository = string # e.g. oci://<registry>/charts
    version    = optional(string)
  })
  nullable = false
}

variable "instance_chart" {
  description = <<-EOT
    flux-instance helm chart location (renders the FluxInstance CR; avoids the kubernetes_manifest plan-time CRD
    problem). A null version installs the latest available at create and pins it in state.
  EOT
  type = object({
    repository = string
    version    = optional(string)
  })
  nullable = false
}

variable "distribution" {
  description = <<-EOT
    Flux distribution: version constraint and the registry hosting the mirrored fluxcd controller images (and
    optionally the OCI artifact with the operator's manifests).
  EOT
  type = object({
    version  = string
    registry = string
    artifact = optional(string)
  })
  nullable = false
}

variable "sync" {
  description = "Cluster sync source: the flux-manifests artifact in the platform registry and the path within it."
  type = object({
    url      = string # oci://<registry>/flux-manifests
    ref      = string # channel tag (stable, staging) or exact version
    path     = string # stack (the single entrypoint all clusters share)
    interval = optional(string, "5m")
  })
  nullable = false
}

variable "signed_identity" {
  description = <<-EOT
    Cosign keyless identity (Go regexps over the Fulcio certificate) enforced on the generated flux-system
    OCIRepository, so an unsigned or tampered manifests artifact is never applied.
  EOT
  type = object({
    issuer            = string
    manifests_subject = string
  })
  nullable = false
}

variable "registry_arn" {
  description = "ARN pattern covering every repository beneath the platform registry prefix; the controllers' read grants are scoped to it."
  type        = string
  nullable    = false
}

variable "registry_is_pull_through_cache" {
  description = <<-EOT
    Whether the platform registry is a pull-through cache. When set, the controllers also get ecr:CreateRepository and
    ecr:BatchImportUpstreamImage on the prefix — the first pull of any artifact is what materialises its repository.
  EOT
  type        = bool
  nullable    = false
  default     = true
}

variable "kustomize_patches" {
  description = <<-EOT
    Extra kustomize patches applied to the generated Flux instance objects, on top of the built-in controller
    nodeSelector and flux-system OCIRepository verify patches.
  EOT
  type        = list(any)
  nullable    = false
  default     = []
}

variable "cluster_vars" {
  description = <<-EOT
    The cluster-vars ConfigMap contents — every value the flux-manifests stack substitutes via
    postBuild.substituteFrom.
  EOT
  type        = map(string)
  nullable    = false
  default     = {}
}

variable "namespaces" {
  description = <<-EOT
    Namespaces pre-created by the cluster-inputs chart (e.g. workload namespaces that must exist before their secrets
    arrive out-of-band); flux kustomizations adopt them via server-side apply.
  EOT
  type        = list(string)
  nullable    = false
  default     = []
}

variable "web_config_secret_name" {
  description = <<-EOT
    Name of a Secret in the namespace whose config.yaml key carries the Web Config API document for the Flux Status web
    UI (SSO, base URL). The operator hot-reloads it, so the Secret may arrive after bootstrap. Null runs the web server
    unconfigured (anonymous, defaults).
  EOT
  type        = string
  default     = null
}

variable "tags" {
  description = "Tags applied to the IAM roles and Pod Identity associations this module creates."
  type        = map(string)
  nullable    = false
  default     = {}
}
