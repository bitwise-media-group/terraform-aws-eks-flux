# Copyright 2026 BitWise Media Group Ltd
# SPDX-License-Identifier: MIT

terraform {
  required_version = ">= 1.11, < 2"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.0, < 7"
    }
    helm = {
      source  = "hashicorp/helm"
      version = ">= 3.0, < 4"
    }
  }
}
