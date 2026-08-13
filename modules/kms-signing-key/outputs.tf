# Copyright 2026 BitWise Media Group Ltd
# SPDX-License-Identifier: MIT

output "key_arn" {
  description = "The signing key ARN — feed it to the artifact-store module's signing_kms_key_arn (grants the publishers kms:Sign) and to the cluster module's signed_identity.kms_key_arn (selects KMS verification)."
  value       = aws_kms_key.signing.arn
}

output "key_id" {
  description = "The signing key id."
  value       = aws_kms_key.signing.key_id
}

output "alias_name" {
  description = "The key's alias (alias/<name>) — a human-readable handle for consoles and same-account CLIs; wiring should use key_arn."
  value       = aws_kms_alias.signing.name
}

output "alias_arn" {
  description = "ARN of the key's alias."
  value       = aws_kms_alias.signing.arn
}

output "cosign_key_ref" {
  description = "The --key argument for cosign sign/verify (awskms:///<key-arn>; the ARN form encodes account and region, so it works from anywhere with KMS access)."
  value       = "awskms:///${aws_kms_key.signing.arn}"
}

output "public_key_pem" {
  description = "PEM-encoded public half of the signing key, for offline verification (cosign verify --key cosign.pub) or committing next to the artifacts it verifies. Not secret."
  value       = data.aws_kms_public_key.signing.public_key_pem
}
