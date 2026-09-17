# Copyright 2026 BitWise Media Group Ltd
# SPDX-License-Identifier: MIT

terraform {
  # 1.11 is the floor for write-only arguments (secret_string_wo in sso.tf) and
  # the ephemeral resources that feed them. 1.16.0 is excluded: its apply
  # graph applied some replacements planned as destroy-then-create in the
  # opposite order (hashicorp/terraform#39076, fixed in 1.16.1), which for
  # the fixed-name cluster meant a CreateCluster call against a cluster that
  # still existed.
  required_version = ">= 1.11, != 1.16.0, < 2.0"

  required_providers {
    # 6.0 is the floor for aws_ecr_repository_creation_template (the
    # CREATE_ON_PUSH template the artifact store depends on), the
    # secret_string_wo write-only pair, and EKS Pod Identity associations.
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.0, < 7.0"
    }
    # Cilium is the only chart this module installs; everything else the
    # cluster runs arrives through flux.
    helm = {
      source  = "hashicorp/helm"
      version = "~> 3.0"
    }
    # The ephemeral dex client secrets (sso.tf).
    random = {
      source  = "hashicorp/random"
      version = ">= 3.7, < 4.0"
    }
    # The cluster issuer's certificate thumbprint for the IRSA OIDC provider
    # (iam.tf).
    tls = {
      source  = "hashicorp/tls"
      version = ">= 4.0, < 5.0"
    }
  }
}
