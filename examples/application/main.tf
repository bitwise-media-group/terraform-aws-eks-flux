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
#
# Nor is its capacity: modules/application owns no nodes. An application that
# needs a dedicated pool calls modules/node-group beside it (below), fed from
# the same application_target - or ships a Karpenter NodePool against the
# platform's EC2NodeClass default in its own manifests and needs no terraform
# for capacity at all.

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
      subject = "^https://github\\.com/example-org/demo-manifests/\\.github/workflows/release\\.yaml@refs/heads/main$"
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

# The application's own capacity: a static Graviton pool only its pods
# tolerate. It joins the way the cluster root's node_groups do - the shared
# Linux node role (the cluster root's EC2_LINUX access entry already admits
# it), the node subnets and the EKS-managed cluster security group - and the
# module adds Cilium's agent-not-ready bootstrap taint ahead of the pool's own
# (cilium_agent_taint, on by default).
module "node_group" {
  source = "../../modules/node-group"

  cluster_name              = var.cluster.name
  name                      = "demo-arm64"
  node_role_arn             = var.cluster.node_role_arn
  subnet_ids                = var.cluster.node_subnet_ids
  cluster_security_group_id = var.cluster.cluster_security_group_id

  instance_types = ["m7g.large"]
  ami_type       = "AL2023_ARM_64_STANDARD"
  min_size       = 1
  max_size       = 3
  desired_size   = 1

  # Only read with a custom ami (the nodeadm bootstrap it renders); wired
  # here so switching the pool to a golden image is a one-line change.
  kubernetes_version            = var.cluster.version
  cluster_endpoint              = var.cluster.endpoint
  cluster_certificate_authority = var.cluster.certificate_authority
  cluster_service_cidr          = var.cluster.service_cidr

  # The manifests pin the demo pods here with a nodeSelector on the label and
  # a toleration for the taint, which keeps everything else off the pool.
  labels = { "example.com/pool" = "demo-arm64" }
  taints = [{ key = "example.com/pool", value = "demo-arm64", effect = "NO_SCHEDULE" }]

  tags = var.tags
}
