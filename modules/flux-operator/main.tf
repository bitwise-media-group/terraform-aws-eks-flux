# Copyright 2026 BitWise Media Group Ltd
# SPDX-License-Identifier: MIT

# The flux bootstrap chain: three helm releases plus one per application, so
# a single terraform apply takes an empty cluster to a reconciling GitOps
# platform without any kubernetes_manifest plan-time CRD problems -
#
#   1. flux-operator     the operator + its CRDs (FluxInstance, ResourceSet, ...)
#   2. cluster-inputs    the terraform -> platform contract (local chart): the
#                        cluster-vars ConfigMap, the per-application <key>-vars
#                        ConfigMaps and pre-created namespaces
#   3. flux-instance     renders the FluxInstance CR; the operator materialises
#                        the Flux controllers and the sync OCIRepository (the
#                        platform entrypoint) from it
#   4. application-*     one seed per application image (local chart): the
#                        ResourceSetInputProvider + ResourceSet that resolve,
#                        verify and apply the image
#
# Everything is pulled from the platform registry (charts/flux-operator,
# charts/flux-instance, mirrored fluxcd controller images), so the artifact
# store must be populated by flux-containers before the first bootstrap.
#
# The operator, instance and application releases are BOOTSTRAP-ONLY
# (ignore_changes): the platform's flux component adopts the first two by
# release name and follows the newest mirrored charts from then on, so a
# flux-containers publish -- never a terraform apply -- is what upgrades flux
# on a running cluster; each application image ships its own copy of its seed
# objects and owns them from its first reconcile, so an application release
# is likewise never a terraform apply. cluster_inputs stays
# terraform-reconciled: cluster-vars and <key>-vars changes flow through
# applies.

locals {
  # How each application image is listed and pulled. Under the platform
  # prefix the flux controllers reach ECR with their Pod Identity: tags are
  # listed through the ECR API (an ECRArtifactTag input provider) and the
  # OCIRepository authenticates as provider aws. Anywhere else (ghcr.io, a
  # GAR mirror) the generic listing and pull apply, with an optional pull
  # secret. Keyed on the registry, never on the cloud: a ghcr-hosted image on
  # an AWS cluster is still a generic pull.
  applications = {
    for key, app in var.applications : key => merge(app, {
      tag_provider = app.platform ? "ECRArtifactTag" : "OCIArtifactTag"
      oci_provider = app.platform ? "aws" : "generic"
    })
  }

  # Platform controllers run on the always-on system node group, never on
  # Karpenter's workload capacity. The operator is pinned via chart values; the
  # Flux controllers via a kustomize patch on the generated flux-system
  # Deployments.
  system_node_selector = { role = "system" }

  controller_patches = [
    {
      patch = yamlencode([
        {
          op    = "add"
          path  = "/spec/template/spec/nodeSelector"
          value = local.system_node_selector
        }
      ])
      target = {
        kind          = "Deployment"
        labelSelector = "app.kubernetes.io/part-of=flux"
      }
    }
  ]

  # The Secret the cluster-inputs chart renders the signing key's public half
  # into (cosign.pub key), and the verify patch references, in keyed mode.
  cosign_public_key_secret = "cosign-pub"

  # FluxInstance spec.sync has no verify field, so signature enforcement on the
  # manifests artifact rides in as a patch on the generated OCIRepository
  # (named after the namespace, matching flux bootstrap). KEYLESS mode: the
  # artifact must carry a Fulcio certificate whose issuer/subject match the
  # flux-manifests publish workflow - no key material is distributed anywhere.
  # KEYED mode: source-controller verifies against the public key(s) in the
  # cosign-pub Secret (it never calls the signing service itself).
  sync_verify_patches = [
    {
      patch = (
        var.signed_identity.kms_public_key_pem != null
        ? yamlencode([
          {
            op   = "add"
            path = "/spec/verify"
            value = {
              provider  = "cosign"
              secretRef = { name = local.cosign_public_key_secret }
            }
          }
        ])
        : yamlencode([
          {
            op   = "add"
            path = "/spec/verify"
            value = {
              provider = "cosign"
              matchOIDCIdentity = [
                {
                  issuer  = var.signed_identity.issuer
                  subject = var.signed_identity.manifests_subject
                }
              ]
            }
          }
        ])
      )
      target = {
        kind = "OCIRepository"
        name = var.namespace
      }
    }
  ]
}

resource "helm_release" "flux_operator" {
  name             = "flux-operator"
  namespace        = var.namespace
  create_namespace = true

  repository = var.operator_chart.repository
  chart      = "flux-operator"
  version    = var.operator_chart.version

  values = [
    yamlencode(merge(
      {
        nodeSelector = local.system_node_selector
      },
      # The web server reads its Web Config API document (SSO, base URL) from
      # this Secret and hot-reloads on change, so the Secret may be delivered
      # after bootstrap.
      var.web_config_secret_name == null ? {} : {
        web = { configSecretName = var.web_config_secret_name }
      },
    ))
  ]

  wait    = true
  timeout = 300

  # Bootstrap-only: the stack's flux component adopts this release (same
  # name/namespace) and upgrades it from the mirror; terraform must never fight
  # it back.
  lifecycle {
    ignore_changes = all
  }

  # The controllers resolve ECR credentials through these associations from
  # their very first reconcile.
  depends_on = [aws_eks_pod_identity_association.flux]
}

resource "helm_release" "flux_instance" {
  name      = "flux"
  namespace = var.namespace

  repository = var.instance_chart.repository
  chart      = "flux-instance"
  version    = var.instance_chart.version

  values = [
    yamlencode({
      instance = {
        distribution = {
          version  = var.distribution.version
          registry = var.distribution.registry
          # Never the chart default (upstream's :latest, an ungated channel
          # that can reference controller images the mirror doesn't carry yet
          # -- a fresh bootstrap would wedge in ImagePullBackOff). Chart
          # version == operator version == manifests tag, so this pin is
          # release-frozen content identical to the manifests embedded in the
          # operator image just installed. Post-adoption, the stack's flux
          # component drops the field entirely (embedded-only).
          artifact = coalesce(
            var.distribution.artifact,
            "oci://ghcr.io/controlplaneio-fluxcd/flux-operator-manifests:v${helm_release.flux_operator.metadata.version}",
          )
        }
        cluster = {
          type          = "aws"
          networkPolicy = true
        }
        sync = {
          kind     = "OCIRepository"
          provider = "aws" # ECR auth via EKS Pod Identity (iam.tf)
          url      = var.sync.url
          ref      = var.sync.ref
          path     = var.sync.path
          interval = var.sync.interval
        }
        kustomize = {
          patches = concat(local.controller_patches, local.sync_verify_patches, var.kustomize_patches)
        }
      }
    })
  ]

  wait    = true
  timeout = 300

  # Bootstrap-only, as flux_operator above.
  lifecycle {
    ignore_changes = all
  }

  # cluster_inputs delivers the cluster-vars ConfigMap the stack substitutes
  # from; installing it first means the first reconcile can succeed immediately.
  depends_on = [helm_release.flux_operator, helm_release.cluster_inputs]
}

resource "helm_release" "cluster_inputs" {
  name      = "cluster-inputs"
  namespace = var.namespace

  chart = "${path.module}/charts/cluster-inputs"

  values = [
    yamlencode(merge(
      {
        clusterVars     = var.cluster_vars
        applicationVars = var.application_vars
        namespaces      = var.namespaces
      },
      # Keyed verification: the chart renders the public key into the Secret
      # the sync verify patch (and the stack, via SecretSync) reads.
      var.signed_identity.kms_public_key_pem == null ? {} : {
        cosignPublicKey = var.signed_identity.kms_public_key_pem
      },
    ))
  ]

  wait    = true
  timeout = 120

  depends_on = [helm_release.flux_operator]
}

# One seed per application image. The chart renders the two flux-operator
# objects that bootstrap an application (a ResourceSetInputProvider resolving
# the newest tag in range, and a ResourceSet turning it into a verified
# OCIRepository + Kustomization); the image carries the same two objects and
# takes them over on its first reconcile, so from then on the application
# owns itself. No helm.sh/resource-policy: keep -- uninstalling the release
# IS the removal path (the ResourceSet's finalizer garbage-collects the
# Kustomization, whose own finalizer prunes the application).
resource "helm_release" "application" {
  for_each = local.applications

  name      = "application-${each.key}"
  namespace = var.namespace

  chart = "${path.module}/charts/application"

  values = [
    yamlencode({
      name        = each.key
      url         = each.value.url
      semver      = each.value.semver
      path        = each.value.path
      interval    = each.value.interval
      tagProvider = each.value.tag_provider
      ociProvider = each.value.oci_provider
      pullSecret  = each.value.pull_secret != null ? each.value.pull_secret : ""
      timeout     = each.value.timeout
      prune       = each.value.prune
      wait        = each.value.wait
      dependsOn   = sort(tolist(each.value.depends_on))
      verify = {
        keyed   = each.value.verify.keyed
        issuer  = each.value.verify.issuer != null ? each.value.verify.issuer : ""
        subject = each.value.verify.subject != null ? each.value.verify.subject : ""
      }
    })
  ]

  wait    = true
  timeout = 120

  # Bootstrap-only, as flux_operator and flux_instance above: the image's own
  # copy of these objects wins every field from the first reconcile on, and a
  # terraform re-apply would fight it back. Never lift this.
  lifecycle {
    ignore_changes = all
  }

  # The FluxInstance must exist for the ResourceSet's dependsOn gate, and
  # cluster-vars (plus the application's own <key>-vars) must be in place for
  # the Kustomization's first substitution.
  depends_on = [helm_release.flux_instance, helm_release.cluster_inputs]
}
