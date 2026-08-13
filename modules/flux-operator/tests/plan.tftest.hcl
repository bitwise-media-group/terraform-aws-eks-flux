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
    url      = "oci://123456789012.dkr.ecr.eu-west-2.amazonaws.com/platform/flux-manifests"
    ref      = "stable"
    path     = "stack"
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
    error_message = "verification is cosign — in keyless mode no key material is distributed anywhere"
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
    error_message = "keyed mode must verify against the cosign-pub public-key Secret — source-controller never calls the signing service"
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
