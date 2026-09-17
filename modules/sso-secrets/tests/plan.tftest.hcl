# Copyright 2026 BitWise Media Group Ltd
# SPDX-License-Identifier: MIT

# Plan-time contract tests with a mocked aws provider: no credentials, no API
# calls. These assert the dex secret-sync contract -- which containers each
# sso declaration creates. The names are platform-manifests' half of the
# contract; a mismatch here is exactly the drift this module exists to
# prevent. There is no grant to assert: read access is identity-side, in the
# cluster module's reader roles.

mock_provider "aws" {}

run "nothing_by_default" {
  command = plan

  assert {
    condition     = length(aws_secretsmanager_secret.main) == 0
    error_message = "without sso there is no out-of-band credential to hold -- application credentials belong to the application's own module"
  }
}

run "sso_adds_dex_connector_credentials" {
  command = plan

  variables {
    sso = {
      enabled = true
      connector = {
        type    = "google"
        secrets = ["client-id", "client-secret", "admin-email"]
      }
    }
  }

  assert {
    condition     = sort(keys(aws_secretsmanager_secret.main)) == tolist(["dex-google-admin-email", "dex-google-client-id", "dex-google-client-secret"])
    error_message = "each declared connector secrets field must create exactly one dex-<id>-<field> container"
  }

  assert {
    condition     = aws_secretsmanager_secret.main["dex-google-client-id"].name == "dex-google-client-id"
    error_message = "an unset secret_prefix must keep the unprefixed secret names"
  }
}

run "sso_connector_mechanism_is_generic" {
  command = plan

  variables {
    sso = {
      enabled   = true
      connector = { id = "okta", type = "oidc" }
    }
  }

  assert {
    condition = alltrue([
      for name in ["dex-okta-client-id", "dex-okta-client-secret"] :
      contains(keys(aws_secretsmanager_secret.main), name)
    ])
    error_message = "a non-google connector id must create the same dex-<id>-<field> container shape as google, defaulting to the client-id/client-secret pair"
  }

  assert {
    condition     = !contains(keys(aws_secretsmanager_secret.main), "dex-google-client-id")
    error_message = "a connector not declared in sso.connector must create no container -- no connector exists by default"
  }
}

run "prefix_applies_to_every_secret" {
  command = plan

  variables {
    secret_prefix = "platform-x-"
    sso = {
      enabled   = true
      connector = { type = "google" }
    }
  }

  assert {
    condition = alltrue([
      for secret in values(aws_secretsmanager_secret.main) : startswith(secret.name, "platform-x-")
    ])
    error_message = "secret_prefix must prefix every secret name (the manifests sync <prefix><name>, and the reader roles scope to it)"
  }

  assert {
    condition     = output.secrets["dex-google-client-id"].name == "platform-x-dex-google-client-id"
    error_message = "the secrets output keys stay unprefixed; the prefixed name rides in name"
  }
}

run "sso_enabled_no_connector_no_containers" {
  command = plan

  variables {
    sso = {
      enabled = true
    }
  }

  assert {
    condition     = length(aws_secretsmanager_secret.main) == 0
    error_message = "sso.enabled alone (no connector) must create no dex credential containers -- no connector exists by default"
  }
}
