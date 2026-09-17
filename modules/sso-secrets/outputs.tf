# Copyright 2026 BitWise Media Group Ltd
# SPDX-License-Identifier: MIT

output "secrets" {
  description = <<-EOT
    The created secrets, keyed by unprefixed name: the ARN and the (prefixed) Secrets Manager name, for wiring further
    IAM in the caller (e.g. a maintainer's PutSecretValue rotation grant). Every secret's versions are added out of
    band: aws secretsmanager put-secret-value --secret-id <name>.
  EOT
  value = {
    for name in keys(local.containers) : name => {
      arn  = aws_secretsmanager_secret.main[name].arn
      name = aws_secretsmanager_secret.main[name].name
    }
  }
}
