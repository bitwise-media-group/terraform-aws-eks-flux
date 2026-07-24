# Copyright 2026 BitWise Media Group Ltd
# SPDX-License-Identifier: MIT

terraform {
  required_version = ">= 1.11, < 2.0"

  required_providers {
    # 6.0 is the floor for aws_ecr_repository_creation_template and the
    # custom_role_arn / upstream_repository_prefix arguments a cross-account
    # ECR-to-ECR pull-through cache needs.
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.0, < 7.0"
    }
  }
}
