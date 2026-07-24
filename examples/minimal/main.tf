# Copyright 2026 BitWise Media Group Ltd
# SPDX-License-Identifier: MIT

# The smallest cluster that reconciles: Cilium in ENI mode, Karpenter's IAM
# surface, the flux bootstrap, and nothing else. No DNS, no Gateway addresses,
# no SSO, no RBAC — the optional surfaces publish the empty-string convention
# and the manifests stack guards on them.
#
# Reaching anything running here means kubectl port-forward; add dns + gateway
# (see examples/complete) for a served domain.

provider "aws" {
  region = var.region
}

module "cluster" {
  source = "../.."

  name = var.name

  network = {
    vpc_id          = var.network.vpc_id
    node_subnet_ids = var.network.node_subnet_ids
  }

  platform_registry = var.platform_registry

  signed_identity = {
    manifests_subject  = var.signed_identity_subjects.manifests
    containers_subject = var.signed_identity_subjects.containers
  }

  tags = var.tags
}

# An exec plugin rather than data.aws_eks_cluster_auth: that data source mints a
# presigned STS token valid for about 15 minutes and resolves it once, while
# this apply spans cluster creation, the node group, the add-ons and then the
# flux chain. `aws eks get-token` runs when credentials are needed instead, so
# the token cannot expire mid-apply — at the cost of needing the AWS CLI on
# whatever runs terraform. ECR tokens are valid 12 hours, so that one stays a
# data source.
data "aws_ecr_authorization_token" "registry" {}

provider "helm" {
  kubernetes = {
    host                   = module.cluster.endpoint
    cluster_ca_certificate = base64decode(module.cluster.ca_certificate)

    exec = {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      args        = ["eks", "get-token", "--cluster-name", module.cluster.name, "--region", var.region]
    }
  }

  registries = [
    {
      url      = "oci://${split("/", var.platform_registry.url)[0]}"
      username = data.aws_ecr_authorization_token.registry.user_name
      password = data.aws_ecr_authorization_token.registry.password
    }
  ]
}
