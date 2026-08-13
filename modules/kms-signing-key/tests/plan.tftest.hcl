# Copyright 2026 BitWise Media Group Ltd
# SPDX-License-Identifier: MIT

# Plan-time contract tests with a mocked provider. These assert what makes the
# key cosign-appropriate (SIGN_VERIFY usage, a spec cosign supports, no
# hair-trigger deletion) and the key-policy shape the platform's onboarding
# story rests on (org-wide verification, opt-in cross-account signing).

mock_provider "aws" {
  mock_data "aws_caller_identity" {
    defaults = {
      account_id = "123456789012"
    }
  }

  mock_data "aws_partition" {
    defaults = {
      partition = "aws"
    }
  }

  mock_data "aws_kms_public_key" {
    defaults = {
      public_key_pem = "-----BEGIN PUBLIC KEY-----\nMFkw\n-----END PUBLIC KEY-----\n"
    }
  }
}

run "key_is_cosign_appropriate" {
  command = plan

  # Both of these are immutable after creation, and both are what "appropriate
  # for cosign" means: an ENCRYPT_DECRYPT key (the KMS default) cannot sign,
  # and the default spec matches cosign's own default algorithm.
  assert {
    condition     = aws_kms_key.signing.key_usage == "SIGN_VERIFY"
    error_message = "the key must be a SIGN_VERIFY key — an encryption key cannot sign"
  }

  assert {
    condition     = aws_kms_key.signing.customer_master_key_spec == "ECC_NIST_P256"
    error_message = "the default spec must be ECC_NIST_P256, cosign's default algorithm"
  }

  # Deleting a signing key permanently breaks verification of everything it
  # ever signed, so the window defaults to the KMS maximum.
  assert {
    condition     = aws_kms_key.signing.deletion_window_in_days == 30
    error_message = "the deletion window must default to the maximum"
  }

  assert {
    condition     = aws_kms_alias.signing.name == "alias/platform-artifact-signing"
    error_message = "the alias must be alias/<name>"
  }
}

run "secp256k1_is_rejected" {
  command = plan

  # KMS offers ECC_SECG_P256K1 for signing, but sigstore does not accept
  # secp256k1 — a key created with it would sign artifacts nothing verifies.
  variables {
    key_spec = "ECC_SECG_P256K1"
  }

  expect_failures = [var.key_spec]
}

run "policy_is_owner_only_by_default" {
  command = plan

  # With no organization and no cross-account signers, the policy is exactly
  # the owning-account root statement — which both prevents lockout and
  # delegates to IAM identity policies (how artifact-store grants its
  # publishers kms:Sign without touching this key policy).
  assert {
    condition     = length(jsondecode(aws_kms_key.signing.policy).Statement) == 1
    error_message = "the default policy is exactly the owning-account root statement"
  }

  assert {
    condition     = jsondecode(aws_kms_key.signing.policy).Statement[0].Principal.AWS == "arn:aws:iam::123456789012:root"
    error_message = "the root statement must name the owning account"
  }
}

run "verification_is_org_wide" {
  command = plan

  variables {
    organization_id = "o-abcdefghij"
  }

  # Wildcard principal conditioned on the org id, exactly like the artifact
  # store's read grant: a new cluster account onboards without editing this
  # module. Verification is not a privilege — the public key is public.
  assert {
    condition = anytrue([
      for statement in jsondecode(aws_kms_key.signing.policy).Statement :
      statement.Sid == "OrganizationVerify" &&
      statement.Principal.AWS == "*" &&
      statement.Condition.StringEquals["aws:PrincipalOrgID"] == "o-abcdefghij"
    ])
    error_message = "the verify grant must be wildcard-with-org-condition, not a per-account principal list"
  }

  # GetPublicKey serves the cluster module's plan-time read and the bootstrap
  # Secret; Verify serves kyverno's admission-time calls.
  assert {
    condition = alltrue([
      for action in ["kms:GetPublicKey", "kms:DescribeKey", "kms:Verify"] :
      anytrue([
        for statement in jsondecode(aws_kms_key.signing.policy).Statement :
        statement.Sid == "OrganizationVerify" && contains(statement.Action, action)
      ])
    ])
    error_message = "org-wide verification needs kms:GetPublicKey, kms:DescribeKey and kms:Verify"
  }

  # The org grant must never leak signing.
  assert {
    condition = !anytrue([
      for statement in jsondecode(aws_kms_key.signing.policy).Statement :
      statement.Sid == "OrganizationVerify" && contains(statement.Action, "kms:Sign")
    ])
    error_message = "the organization may verify, never sign"
  }
}

run "cross_account_signing_is_opt_in" {
  command = plan

  variables {
    signer_principals = ["arn:aws:iam::999988887777:role/platform-chart-publisher"]
  }

  # Cross-account KMS needs a key-policy grant on top of the caller's identity
  # policy; naming a signer must add exactly that.
  assert {
    condition = anytrue([
      for statement in jsondecode(aws_kms_key.signing.policy).Statement :
      statement.Sid == "Sign" &&
      contains(statement.Action, "kms:Sign") &&
      contains(statement.Principal.AWS, "arn:aws:iam::999988887777:role/platform-chart-publisher")
    ])
    error_message = "named signer principals must get a key-policy kms:Sign grant"
  }
}
