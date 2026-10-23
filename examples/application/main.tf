# Copyright 2026 BitWise Media Group Ltd
# SPDX-License-Identifier: MIT

# An application published to an existing cluster from a root of its own -
# another state, another repository, another team. Nothing here touches the
# cluster root: the seed, the application's vars, its namespaces and its cloud
# identities are all this root's, keyed to the cluster through the cluster
# root's application_target output.
#
# That output arrives here as a plain variable so the example plans on its
# own. A real root usually reads it from the cluster's state instead:
#
#   data "terraform_remote_state" "cluster" {
#     backend = "s3"
#     config  = { bucket = "...", key = "clusters/patchy-x.tfstate", region = "eu-west-2" }
#   }
#
#   cluster = data.terraform_remote_state.cluster.outputs.application_target
#
# Its dex client, if it has one, is not here either: the application ships a
# DexClient in its own image, and the platform's dex-client-controller
# registers it.

provider "aws" {
  region = var.region
}

data "aws_eks_cluster" "target" {
  name = var.cluster.name
}

# The same exec plugin as examples/minimal: a token minted when credentials
# are needed rather than once at plan time. Both charts are local to the
# module, so no registry credentials are needed.
provider "helm" {
  kubernetes = {
    host                   = data.aws_eks_cluster.target.endpoint
    cluster_ca_certificate = base64decode(data.aws_eks_cluster.target.certificate_authority[0].data)

    exec = {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      args        = ["eks", "get-token", "--cluster-name", var.cluster.name, "--region", var.region]
    }
  }
}

module "demo" {
  source = "../../modules/application"

  name    = "demo"
  cluster = var.cluster

  image = {
    url    = "oci://${var.cluster.platform_registry}/manifests/demo"
    semver = "<1.0.0 >=0.1.0"
    verify = {
      subject = "^https://github\\.com/example-org/demo-manifests/\\.github/workflows/publish\\.yaml@refs/tags/v.+$"
    }
  }

  # The <name>-vars ConfigMap the image's Kustomization substitutes from.
  vars = {
    DEMO_DOMAIN = var.domain
  }

  namespaces = ["demo"]

  # The KSA the application's secret syncs run as; the manifests annotate it
  # with ${SECRETS_ROLE_PREFIX}demo-demo-secrets.
  secret_readers = [
    { namespace = "demo", service_account = "demo-secrets" },
  ]

  tags = var.tags
}
