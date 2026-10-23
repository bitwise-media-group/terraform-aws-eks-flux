# Copyright 2026 BitWise Media Group Ltd
# SPDX-License-Identifier: MIT

# Plan-time contract tests with mocked providers: the seed values a
# standalone application hands the shared chart, the inputs release, the
# IAM names the manifests rely on, and every validation.

mock_provider "aws" {
  mock_data "aws_iam_policy_document" {
    defaults = {
      json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}"
    }
  }

  mock_data "aws_caller_identity" {
    defaults = {
      account_id = "123456789012"
    }
  }

  mock_data "aws_partition" {
    defaults = {
      partition = "aws"
    }
  }

  mock_data "aws_region" {
    defaults = {
      region = "eu-west-2"
    }
  }
}

mock_provider "helm" {}

variables {
  name = "demo"

  cluster = {
    name              = "patchy-x"
    namespace         = "flux-system"
    platform_registry = "123456789012.dkr.ecr.eu-west-2.amazonaws.com/platform"
    tree              = "aws"
    issuer            = "^https://token\\.actions\\.githubusercontent\\.com$"
    keyed             = false
    oidc_provider_arn = "arn:aws:iam::123456789012:oidc-provider/oidc.eks.eu-west-2.amazonaws.com/id/ABC"
    oidc_issuer       = "oidc.eks.eu-west-2.amazonaws.com/id/ABC"
    secret_prefix     = "patchy-x-"
  }

  image = {
    url    = "oci://123456789012.dkr.ecr.eu-west-2.amazonaws.com/platform/manifests/demo"
    semver = "<1.0.0 >=0.1.0"
    verify = {
      subject = "^https://github\\.com/org/demo/\\.github/workflows/publish\\.yaml@refs/tags/v.+$"
    }
  }
}

run "platform_image_seed" {
  command = plan

  assert {
    condition     = helm_release.seed.name == "application-demo" && helm_release.seed.namespace == "flux-system"
    error_message = "the seed is release application-<name> in the cluster's flux namespace, exactly as the cluster root names its own"
  }

  assert {
    condition     = helm_release.seed.chart == "${path.module}/charts/application"
    error_message = "the seed is the module's local application chart (shared with the cluster root)"
  }

  # The registry, never the cloud, picks the listing and pull dialect.
  assert {
    condition     = output.tag_provider == "ECRArtifactTag" && output.oci_provider == "aws"
    error_message = "an image under the platform registry is listed with ECRArtifactTag and pulled as provider aws"
  }

  assert {
    condition     = yamldecode(helm_release.seed.values[0]).tagProvider == "ECRArtifactTag" && yamldecode(helm_release.seed.values[0]).ociProvider == "aws"
    error_message = "the providers must reach the chart"
  }

  assert {
    condition     = output.path == "./deploy/aws" && yamldecode(helm_release.seed.values[0]).path == "./deploy/aws"
    error_message = "the path defaults to ./deploy/<cluster.tree>, the platform's own tree selector"
  }

  # Keyless images default onto the cluster's own issuer.
  assert {
    condition     = yamldecode(helm_release.seed.values[0]).verify.issuer == var.cluster.issuer
    error_message = "a keyless image without an issuer verifies against cluster.issuer"
  }

  assert {
    condition     = yamldecode(helm_release.seed.values[0]).verify.subject == var.image.verify.subject && yamldecode(helm_release.seed.values[0]).verify.keyed == false
    error_message = "the keyless subject must reach the chart verbatim (a Go regexp full of backslashes)"
  }

  assert {
    condition     = join(",", yamldecode(helm_release.seed.values[0]).dependsOn) == "kyverno-policies" && yamldecode(helm_release.seed.values[0]).pullSecret == ""
    error_message = "the seed waits for kyverno-policies by default and needs no pull secret on the platform registry"
  }

  # Nothing to render: no vars, no namespaces, no inputs release.
  assert {
    condition     = length(helm_release.inputs) == 0
    error_message = "the inputs release exists only when there are vars or namespaces"
  }

  assert {
    condition     = length(aws_iam_role.workload) == 0 && length(aws_iam_role.secret_reader) == 0
    error_message = "no grants, no roles"
  }
}

run "external_image_seed" {
  command = plan

  variables {
    image = {
      url         = "oci://ghcr.io/org/demo-manifests"
      path        = "./deploy/custom"
      depends_on  = ["kyverno-policies", "gateway"]
      pull_secret = "ghcr-pull"
      verify = {
        issuer  = "^https://example\\.com$"
        subject = "^https://github\\.com/org/demo/.+$"
      }
    }
  }

  assert {
    condition     = output.tag_provider == "OCIArtifactTag" && output.oci_provider == "generic"
    error_message = "an image outside the platform registry is listed with OCIArtifactTag and pulled as provider generic"
  }

  assert {
    condition     = yamldecode(helm_release.seed.values[0]).pullSecret == "ghcr-pull" && output.path == "./deploy/custom"
    error_message = "the pull secret and an explicit path must reach the chart"
  }

  assert {
    condition     = yamldecode(helm_release.seed.values[0]).verify.issuer == "^https://example\\.com$"
    error_message = "an explicit issuer wins over cluster.issuer"
  }

  assert {
    condition     = join(",", yamldecode(helm_release.seed.values[0]).dependsOn) == "gateway,kyverno-policies"
    error_message = "dependsOn must reach the chart as a sorted list"
  }
}

run "keyed_seed" {
  command = plan

  variables {
    cluster = {
      name              = "patchy-x"
      namespace         = "flux-system"
      platform_registry = "123456789012.dkr.ecr.eu-west-2.amazonaws.com/platform"
      tree              = "aws"
      keyed             = true
      oidc_provider_arn = "arn:aws:iam::123456789012:oidc-provider/oidc.eks.eu-west-2.amazonaws.com/id/ABC"
      oidc_issuer       = "oidc.eks.eu-west-2.amazonaws.com/id/ABC"
      secret_prefix     = ""
    }
    image = {
      url    = "oci://123456789012.dkr.ecr.eu-west-2.amazonaws.com/platform/manifests/demo"
      verify = { keyed = true }
    }
  }

  assert {
    condition     = yamldecode(helm_release.seed.values[0]).verify.keyed == true && yamldecode(helm_release.seed.values[0]).verify.subject == "" && yamldecode(helm_release.seed.values[0]).verify.issuer == ""
    error_message = "keyed mode hands the chart the keyed flag and no keyless identity - the chart then verifies against the cosign-pub Secret"
  }
}

run "inputs_release" {
  command = plan

  variables {
    vars       = { DEMO_DOMAIN = "demo.example.com" }
    namespaces = ["demo-b", "demo"]
  }

  assert {
    condition     = helm_release.inputs["true"].name == "application-demo-inputs" && helm_release.inputs["true"].namespace == "flux-system"
    error_message = "vars and namespaces ride one terraform-reconciled release, application-<name>-inputs, in the flux namespace"
  }

  assert {
    condition     = helm_release.inputs["true"].chart == "${path.module}/charts/inputs"
    error_message = "the inputs are the module's local inputs chart"
  }

  assert {
    condition     = yamldecode(helm_release.inputs["true"].values[0]).name == "demo" && yamldecode(helm_release.inputs["true"].values[0]).vars.DEMO_DOMAIN == "demo.example.com"
    error_message = "the vars reach the chart under the application's name, which renders them as the <name>-vars ConfigMap"
  }

  assert {
    condition     = join(",", yamldecode(helm_release.inputs["true"].values[0]).namespaces) == "demo,demo-b"
    error_message = "namespaces reach the chart as a sorted list"
  }
}

run "namespaces_alone_need_inputs" {
  command = plan

  variables {
    namespaces = ["demo"]
  }

  assert {
    condition     = length(helm_release.inputs) == 1
    error_message = "namespaces without vars still need the inputs release"
  }
}

run "grants_and_readers" {
  command = plan

  variables {
    workload_grants = {
      egress-broker = {
        namespace       = "demo"
        service_account = "egress-broker"
        policy          = "{\"Version\":\"2012-10-17\",\"Statement\":[]}"
      }
    }
    secret_readers = [{ namespace = "demo", service_account = "demo-secrets" }]
  }

  assert {
    condition     = aws_iam_role.workload["egress-broker"].name == "patchy-x-egress-broker"
    error_message = "a workload grant's role is <cluster>-<key>, the same name the cluster root would mint"
  }

  assert {
    condition = (
      aws_eks_pod_identity_association.workload["egress-broker"].cluster_name == "patchy-x"
      && aws_eks_pod_identity_association.workload["egress-broker"].namespace == "demo"
      && aws_eks_pod_identity_association.workload["egress-broker"].service_account == "egress-broker"
    )
    error_message = "a workload grant binds its pair through Pod Identity on the cluster"
  }

  # ${SECRETS_ROLE_PREFIX}<ns>-<sa> must keep resolving for the manifests.
  assert {
    condition     = aws_iam_role.secret_reader["secrets-demo-demo-secrets"].name == "patchy-x-secrets-demo-demo-secrets"
    error_message = "a secret reader's role is <cluster>-secrets-<ns>-<sa>"
  }

  assert {
    condition     = local.secret_arn_pattern == "arn:aws:secretsmanager:eu-west-2:123456789012:secret:patchy-x-*"
    error_message = "the readers may read exactly the secrets under the cluster's SECRET_PREFIX"
  }

  assert {
    condition     = length(aws_eks_pod_identity_association.workload) == 1
    error_message = "the podless readers get no Pod Identity association - they assume their roles through IRSA"
  }
}

run "invalid_name" {
  command = plan

  variables {
    name = "Demo_App"
  }

  expect_failures = [var.name]
}

run "reserved_name" {
  command = plan

  variables {
    name = "dex"
  }

  expect_failures = [var.name]
}

run "keyless_cluster_needs_issuer" {
  command = plan

  variables {
    cluster = {
      name              = "patchy-x"
      namespace         = "flux-system"
      platform_registry = "123456789012.dkr.ecr.eu-west-2.amazonaws.com/platform"
      tree              = "aws"
      keyed             = false
      oidc_provider_arn = "arn:aws:iam::123456789012:oidc-provider/oidc.eks.eu-west-2.amazonaws.com/id/ABC"
      oidc_issuer       = "oidc.eks.eu-west-2.amazonaws.com/id/ABC"
      secret_prefix     = ""
    }
  }

  expect_failures = [var.cluster]
}

run "url_with_tag" {
  command = plan

  variables {
    image = {
      url    = "oci://ghcr.io/org/demo:1.0.0"
      verify = { subject = "^https://github\\.com/org/demo/.+$" }
    }
  }

  expect_failures = [var.image]
}

run "foreign_ecr_url" {
  command = plan

  variables {
    image = {
      url    = "oci://210987654321.dkr.ecr.eu-west-2.amazonaws.com/other/demo"
      verify = { subject = "^https://github\\.com/org/demo/.+$" }
    }
  }

  expect_failures = [var.image]
}

run "unverified_image" {
  command = plan

  variables {
    image = {
      url    = "oci://ghcr.io/org/demo"
      verify = {}
    }
  }

  expect_failures = [var.image]
}

run "keyed_image_needs_keyed_cluster" {
  command = plan

  variables {
    image = {
      url    = "oci://ghcr.io/org/demo"
      verify = { keyed = true }
    }
  }

  expect_failures = [var.image]
}

run "keyless_image_on_keyed_cluster_needs_issuer" {
  command = plan

  variables {
    cluster = {
      name              = "patchy-x"
      namespace         = "flux-system"
      platform_registry = "123456789012.dkr.ecr.eu-west-2.amazonaws.com/platform"
      tree              = "aws"
      keyed             = true
      oidc_provider_arn = "arn:aws:iam::123456789012:oidc-provider/oidc.eks.eu-west-2.amazonaws.com/id/ABC"
      oidc_issuer       = "oidc.eks.eu-west-2.amazonaws.com/id/ABC"
      secret_prefix     = ""
    }
  }

  expect_failures = [var.image]
}

run "pull_secret_on_platform_registry" {
  command = plan

  variables {
    image = {
      url         = "oci://123456789012.dkr.ecr.eu-west-2.amazonaws.com/platform/manifests/demo"
      pull_secret = "ecr-pull"
      verify      = { subject = "^https://github\\.com/org/demo/.+$" }
    }
  }

  expect_failures = [var.image]
}

run "lowercase_vars" {
  command = plan

  variables {
    vars = { demo_domain = "demo.example.com" }
  }

  expect_failures = [var.vars]
}

run "invalid_namespace" {
  command = plan

  variables {
    namespaces = ["Demo"]
  }

  expect_failures = [var.namespaces]
}

run "grant_key_collides_with_platform" {
  command = plan

  variables {
    workload_grants = {
      secrets-demo = {
        namespace       = "demo"
        service_account = "demo"
        policy          = "{}"
      }
    }
  }

  expect_failures = [var.workload_grants]
}

run "grant_key_shape" {
  command = plan

  variables {
    workload_grants = {
      Broker = {
        namespace       = "demo"
        service_account = "demo"
        policy          = "{}"
      }
    }
  }

  expect_failures = [var.workload_grants]
}

run "grant_policy_not_json" {
  command = plan

  variables {
    workload_grants = {
      broker = {
        namespace       = "demo"
        service_account = "demo"
        policy          = "not json"
      }
    }
  }

  expect_failures = [var.workload_grants]
}
