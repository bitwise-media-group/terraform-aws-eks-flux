# Copyright 2026 BitWise Media Group Ltd
# SPDX-License-Identifier: MIT

# Plan-time contract tests with a mocked aws provider: no credentials, no API
# calls. These assert the secret-sync contract -- which secrets each election
# creates. The names are flux-manifests' half of the contract; a mismatch
# here is exactly the drift this module exists to prevent. There is no grant
# to assert: read access is identity-side, in the cluster module's reader
# roles.

mock_provider "aws" {}

run "default_election" {
  command = plan

  assert {
    condition     = sort(keys(aws_secretsmanager_secret.main)) == tolist(["patchy-anthropic-token", "patchy-github-app-id", "patchy-github-app-private-key", "patchy-webhook-secret"])
    error_message = "the default election (patchy elected, claude on anthropic) must create exactly the GitHub App trio plus the anthropic token"
  }

  assert {
    condition     = aws_secretsmanager_secret.main["patchy-github-app-id"].name == "patchy-github-app-id"
    error_message = "an unset secret_prefix must keep the unprefixed secret names"
  }
}

run "bedrock_needs_no_anthropic_secret" {
  command = plan

  variables {
    claude_provider = "bedrock"
  }

  assert {
    condition     = !contains(keys(aws_secretsmanager_secret.main), "patchy-anthropic-token")
    error_message = "a bedrock cluster's broker authenticates with its Pod Identity: no anthropic secret may exist for a sync to wedge on"
  }
}

run "harness_election" {
  command = plan

  variables {
    agent_harnesses = ["claude", "codex", "copilot"]
  }

  assert {
    condition = alltrue([
      for name in ["patchy-openai-token", "patchy-copilot-token"] :
      contains(keys(aws_secretsmanager_secret.main), name)
    ])
    error_message = "the codex and copilot harnesses must each bring their credential secret"
  }
}

run "prefix_applies_to_every_secret" {
  command = plan

  variables {
    secret_prefix = "patchy-x-"
  }

  assert {
    condition = alltrue([
      for secret in values(aws_secretsmanager_secret.main) : startswith(secret.name, "patchy-x-")
    ])
    error_message = "secret_prefix must prefix every secret name (the manifests sync <prefix><name>, and the reader roles scope to it)"
  }

  assert {
    condition     = output.secrets["patchy-github-app-id"].name == "patchy-x-patchy-github-app-id"
    error_message = "the secrets output keys stay unprefixed; the prefixed name rides in name"
  }
}

run "no_patchy_no_secrets" {
  command = plan

  variables {
    stack_components = ["flux-web"]
  }

  assert {
    condition     = length(aws_secretsmanager_secret.main) == 0
    error_message = "without the patchy component there is no out-of-band credential to hold (dex's rides in the cluster module on AWS)"
  }
}
