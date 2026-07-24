# Copyright 2026 BitWise Media Group Ltd
# SPDX-License-Identifier: MIT

output "namespace" {
  description = "Namespace the flux-operator and Flux controllers run in."
  value       = var.namespace
}

output "registry_reader_roles" {
  description = "IAM role ARNs the flux controllers assume through Pod Identity — the identities that read the platform registry."
  value       = [for role in aws_iam_role.flux : role.arn]
}
