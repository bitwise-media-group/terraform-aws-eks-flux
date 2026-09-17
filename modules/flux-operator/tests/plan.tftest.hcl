# Copyright 2026 BitWise Media Group Ltd
# SPDX-License-Identifier: MIT

# Plan-time contract tests with mocked providers. These assert the bootstrap
# chain's shape: what is adopted by flux afterwards, what is enforced on the
# sync artifact, and how the controllers reach ECR.

mock_provider "aws" {
  mock_data "aws_iam_policy_document" {
    defaults = {
      json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}"
    }
  }
}

mock_provider "helm" {}

variables {
  cluster_name = "patchy-x"

  operator_chart = {
    repository = "oci://123456789012.dkr.ecr.eu-west-2.amazonaws.com/platform/charts"
  }
  instance_chart = {
    repository = "oci://123456789012.dkr.ecr.eu-west-2.amazonaws.com/platform/charts"
  }
  distribution = {
    version  = "2.x"
    registry = "123456789012.dkr.ecr.eu-west-2.amazonaws.com/platform/images/ghcr.io/fluxcd"
  }
  sync = {
    url      = "oci://123456789012.dkr.ecr.eu-west-2.amazonaws.com/platform/manifests/platform"
    ref      = "stable"
    path     = "aws"
    interval = "5m"
  }

  signed_identity = {
    issuer            = "^https://token\\.actions\\.githubusercontent\\.com$"
    manifests_subject = "^https://github\\.com/bitwise-media-group/flux-manifests/\\.github/workflows/publish\\.yaml@refs/tags/v.+$"
  }

  registry_arn = "arn:aws:ecr:eu-west-2:123456789012:repository/platform/*"
}

run "bootstrap_chain" {
  command = plan

  assert {
    condition     = helm_release.flux_operator.namespace == "flux-system" && helm_release.flux_operator.create_namespace == true
    error_message = "the operator creates its own namespace so a single apply works against an empty cluster"
  }

  assert {
    condition     = helm_release.cluster_inputs.chart == "${path.module}/charts/cluster-inputs"
    error_message = "the cluster-vars contract ships as a local chart, not from the registry"
  }

  # cluster-inputs must land before the instance so the very first reconcile can
  # substitute from cluster-vars.
  assert {
    condition     = helm_release.flux_instance.wait == true && helm_release.cluster_inputs.wait == true
    error_message = "each link in the bootstrap chain must be ready before the next runs"
  }
}

run "sync_is_signature_verified" {
  command = plan

  # FluxInstance spec.sync has no verify field, so enforcement rides in as a
  # kustomize patch on the generated OCIRepository. Without it an unsigned or
  # tampered manifests artifact would be applied.
  assert {
    condition = anytrue([
      for patch in local.sync_verify_patches :
      patch.target.kind == "OCIRepository" && patch.target.name == "flux-system"
    ])
    error_message = "the verify patch must target the generated flux-system OCIRepository"
  }

  # Decoded rather than string-matched: the subject is a Go regexp full of
  # backslashes, which yamlencode escapes again on the way in.
  assert {
    condition     = yamldecode(local.sync_verify_patches[0].patch)[0].value.provider == "cosign"
    error_message = "verification is cosign - in keyless mode no key material is distributed anywhere"
  }

  assert {
    condition = (
      yamldecode(local.sync_verify_patches[0].patch)[0].value.matchOIDCIdentity[0].subject
      == var.signed_identity.manifests_subject
    )
    error_message = "the patch must pin the exact publishing workflow identity"
  }

  assert {
    condition = (
      yamldecode(local.sync_verify_patches[0].patch)[0].value.matchOIDCIdentity[0].issuer
      == var.signed_identity.issuer
    )
    error_message = "the patch must pin the issuer as well as the subject"
  }
}

run "keyed_verification" {
  command = plan

  variables {
    signed_identity = {
      kms_public_key_pem = "-----BEGIN PUBLIC KEY-----\nMFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAE\n-----END PUBLIC KEY-----\n"
    }
  }

  assert {
    condition     = yamldecode(local.sync_verify_patches[0].patch)[0].value.secretRef.name == "cosign-pub"
    error_message = "keyed mode must verify against the cosign-pub public-key Secret - source-controller never calls the signing service"
  }

  assert {
    condition     = !can(yamldecode(local.sync_verify_patches[0].patch)[0].value.matchOIDCIdentity)
    error_message = "keyed mode must not also carry a keyless identity match"
  }

  assert {
    condition     = strcontains(helm_release.cluster_inputs.values[0], "cosignPublicKey")
    error_message = "the cluster-inputs chart must receive the public key to render the cosign-pub Secret"
  }
}

run "controllers_pin_to_the_system_pool" {
  command = plan

  assert {
    condition     = local.controller_patches[0].target.labelSelector == "app.kubernetes.io/part-of=flux"
    error_message = "the Flux controllers must be pinned to the system node group, away from Karpenter's workload capacity"
  }

  assert {
    condition     = local.system_node_selector.role == "system"
    error_message = "the selector must match the label the cluster module puts on the system node group"
  }
}

run "registry_access_is_pod_identity" {
  command = plan

  assert {
    condition     = length(aws_eks_pod_identity_association.flux) == 2
    error_message = "source-controller (pulls the sync artifact and charts) and flux-operator (lists chart tags) both need registry read"
  }

  assert {
    condition = alltrue([
      for association in aws_eks_pod_identity_association.flux :
      association.namespace == "flux-system"
    ])
    error_message = "the associations must target the namespace the controllers actually run in"
  }

  assert {
    condition     = length(output.registry_reader_roles) == 2
    error_message = "both controller roles must be exported so a cluster reading a central store can be admitted there"
  }
}

run "no_applications_by_default" {
  command = plan

  assert {
    condition     = length(helm_release.application) == 0 && length(output.applications) == 0
    error_message = "a cluster with no applications must seed nothing - the platform alone is a complete deployment"
  }

  assert {
    condition     = !strcontains(helm_release.cluster_inputs.values[0], "-vars")
    error_message = "without application_vars no <key>-vars ConfigMap may be rendered"
  }
}

run "application_seeds" {
  command = plan

  variables {
    applications = {
      demo = {
        url        = "oci://123456789012.dkr.ecr.eu-west-2.amazonaws.com/platform/manifests/demo"
        platform   = true
        semver     = "<1.0.0 >=0.1.0"
        path       = "./deploy/aws"
        interval   = "30m"
        depends_on = ["kyverno-policies", "gateway"]
        verify = {
          keyed   = false
          issuer  = "^https://token\\.actions\\.githubusercontent\\.com$"
          subject = "^https://github\\.com/org/demo/\\.github/workflows/publish\\.yaml@refs/tags/v.+$"
        }
        prune   = true
        wait    = true
        timeout = "10m"
      }
      external = {
        url         = "oci://ghcr.io/org/external-manifests"
        platform    = false
        semver      = ">=0.0.0"
        path        = "./deploy/aws"
        interval    = "1h"
        depends_on  = ["kyverno-policies"]
        verify      = { keyed = false, issuer = "^https://token\\.actions\\.githubusercontent\\.com$", subject = "^https://github\\.com/org/external/.+$" }
        pull_secret = "ghcr-pull"
        prune       = true
        wait        = false
        timeout     = "5m"
      }
    }
    application_vars = {
      demo = { DEMO_DOMAIN = "demo.example.com" }
    }
  }

  # One bootstrap-only release per application, from the local seed chart,
  # named so the release list reads as the application inventory.
  assert {
    condition     = helm_release.application["demo"].name == "application-demo" && helm_release.application["demo"].chart == "${path.module}/charts/application"
    error_message = "each application must be one release of the local application chart, named application-<key>"
  }

  assert {
    condition     = helm_release.application["demo"].namespace == "flux-system"
    error_message = "the seed objects live in flux-system, where the image's own flux/ copy expects to adopt them"
  }

  # The registry, never the cloud, picks the listing and pull dialect: the
  # platform prefix is reached with the controllers' Pod Identity through the
  # ECR API; anywhere else is a generic OCI listing and pull.
  assert {
    condition     = output.applications["demo"].tag_provider == "ECRArtifactTag" && output.applications["demo"].oci_provider == "aws"
    error_message = "an image under the platform registry must be listed with ECRArtifactTag and pulled as provider aws"
  }

  assert {
    condition     = output.applications["external"].tag_provider == "OCIArtifactTag" && output.applications["external"].oci_provider == "generic"
    error_message = "an image outside the platform registry must be listed with OCIArtifactTag and pulled as provider generic"
  }

  assert {
    condition     = yamldecode(helm_release.application["external"].values[0]).pullSecret == "ghcr-pull" && yamldecode(helm_release.application["demo"].values[0]).pullSecret == ""
    error_message = "the pull secret must reach the chart for the external image only"
  }

  assert {
    condition     = yamldecode(helm_release.application["demo"].values[0]).verify.subject == var.applications["demo"].verify.subject
    error_message = "the keyless subject must reach the chart verbatim (a Go regexp full of backslashes)"
  }

  assert {
    condition     = join(",", yamldecode(helm_release.application["demo"].values[0]).dependsOn) == "gateway,kyverno-policies"
    error_message = "dependsOn must reach the chart as a sorted list"
  }

  assert {
    condition     = yamldecode(helm_release.cluster_inputs.values[0]).applicationVars.demo.DEMO_DOMAIN == "demo.example.com"
    error_message = "application_vars must reach the cluster-inputs chart, which renders the <key>-vars ConfigMaps"
  }
}

run "keyed_application_verification" {
  command = plan

  variables {
    signed_identity = {
      kms_public_key_pem = "-----BEGIN PUBLIC KEY-----\nMFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAE\n-----END PUBLIC KEY-----\n"
    }
    applications = {
      demo = {
        url        = "oci://123456789012.dkr.ecr.eu-west-2.amazonaws.com/platform/manifests/demo"
        platform   = true
        semver     = ">=0.0.0"
        path       = "./deploy/aws"
        interval   = "30m"
        depends_on = ["kyverno-policies"]
        verify     = { keyed = true }
        prune      = true
        wait       = true
        timeout    = "5m"
      }
    }
  }

  assert {
    condition     = yamldecode(helm_release.application["demo"].values[0]).verify.keyed == true && yamldecode(helm_release.application["demo"].values[0]).verify.subject == ""
    error_message = "keyed mode must hand the chart the keyed flag and no keyless identity - the chart then verifies against the cosign-pub Secret"
  }
}

run "keyed_application_requires_keyed_mode" {
  command = plan

  variables {
    applications = {
      demo = {
        url        = "oci://123456789012.dkr.ecr.eu-west-2.amazonaws.com/platform/manifests/demo"
        platform   = true
        semver     = ">=0.0.0"
        path       = "./deploy/aws"
        interval   = "30m"
        depends_on = ["kyverno-policies"]
        verify     = { keyed = true }
        prune      = true
        wait       = true
        timeout    = "5m"
      }
    }
  }

  expect_failures = [var.applications]
}
