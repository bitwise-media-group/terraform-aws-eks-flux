# Copyright 2026 BitWise Media Group Ltd
# SPDX-License-Identifier: MIT

# Plan-time contract tests with a mocked provider. These assert the two things
# the store's design rests on: create-on-push (without which ECR has no
# arbitrary-path model at all) and an org-wide read grant that needs no editing
# as accounts come online.

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

  mock_data "aws_region" {
    defaults = {
      region = "eu-west-2"
    }
  }

  # A mocked json attribute is a random string, which every policy argument then
  # rejects. The registry policy under test is built from plain structures
  # rather than a policy document, so it is unaffected by this stand-in.
  mock_data "aws_iam_policy_document" {
    defaults = {
      json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}"
    }
  }
}

variables {
  organization_id = "o-abcdefghij"

  github = {
    manifest_publishers = {
      flux-manifests = { repository_id = 987654321, paths = ["manifests/*"] }
    }
  }
}

run "create_on_push" {
  command = plan

  # Without a matching template ECR refuses to create a repository on push at
  # all, so publishers could not push charts/images to paths that do not exist
  # yet. This single value is what makes the whole layout work.
  assert {
    condition     = contains(aws_ecr_repository_creation_template.platform.applied_for, "CREATE_ON_PUSH")
    error_message = "the creation template must apply to CREATE_ON_PUSH"
  }

  assert {
    condition     = aws_ecr_repository_creation_template.platform.prefix == "platform"
    error_message = "the template must be keyed on the same prefix everything is published beneath"
  }

  # Channel tags (staging, stable, edge) move between releases.
  assert {
    condition     = aws_ecr_repository_creation_template.platform.image_tag_mutability == "MUTABLE"
    error_message = "tags must stay mutable: the manifests artifact's channel tags move"
  }

  # ECR fails repository creation outright if the template sets tags or KMS
  # without a role to assume. The template's custom_role_arn is a direct
  # reference to this role, so its existence is the part worth asserting (the
  # ARN itself is unknown until apply).
  assert {
    condition     = aws_iam_role.creation.name == "platform-ecr-repository-creation"
    error_message = "a creation template setting resource tags requires a role for ECR to assume"
  }

  # Trusted for pull-through cache and replication too, so the same template can
  # later serve those without a trust-policy change.
  assert {
    condition = alltrue([
      for principal in ["ecr.amazonaws.com", "pullthroughcache.ecr.amazonaws.com", "replication.ecr.amazonaws.com"] :
      anytrue([
        for block in one(data.aws_iam_policy_document.creation_assume_role.statement).principals :
        contains(block.identifiers, principal)
      ])
    ])
    error_message = "the creation role must be assumable by every ECR principal that creates repositories"
  }
}

run "reads_are_org_wide" {
  command = plan

  variables {
    direct_pull_principals = []
  }

  # One statement, no account list: the downstream account's pull-through-cache
  # role is the actual caller, so aws:PrincipalOrgID matches it and every future
  # member account is covered without touching this module.
  assert {
    condition     = length(jsondecode(aws_ecr_registry_policy.platform.policy).Statement) == 1
    error_message = "with no direct pull principals the registry policy is exactly the org-wide pull-through-cache grant"
  }

  assert {
    condition     = jsondecode(aws_ecr_registry_policy.platform.policy).Statement[0].Condition.StringEquals["aws:PrincipalOrgID"] == "o-abcdefghij"
    error_message = "the pull-through-cache grant must be conditioned on the organization id, not on a per-account principal list"
  }

  assert {
    condition = contains(
      jsondecode(aws_ecr_registry_policy.platform.policy).Statement[0].Action,
      "ecr:BatchImportUpstreamImage",
    )
    error_message = "a pull-through cache needs BatchImportUpstreamImage on the upstream, not just read"
  }

  assert {
    condition     = jsondecode(aws_ecr_registry_policy.platform.policy).Statement[0].Principal.AWS == "*"
    error_message = "the principal is wildcard-with-org-condition; naming accounts is exactly what this avoids"
  }
}

run "direct_pull_is_opt_in" {
  command = plan

  variables {
    direct_pull_principals = ["arn:aws:iam::999988887777:role/patchy-x-nodes"]
  }

  assert {
    condition     = length(jsondecode(aws_ecr_registry_policy.platform.policy).Statement) == 2
    error_message = "naming direct pull principals must add a second statement beside the org-wide one"
  }
}

run "publisher_trust_pins_numeric_ids" {
  command = plan

  # GitHub mints immutable subjects (repo:<org>@<id>/<repo>@<id>:...) for
  # post-2026-07-15 repos. The name-only form never matches, so a trust policy
  # without the ids silently fails at AssumeRoleWithWebIdentity.
  assert {
    condition     = local.containers_subject_repo == "bitwise-media-group@282673588/flux-containers@1303643498"
    error_message = "the chart publisher's subject must pin the numeric org and repo ids"
  }

  assert {
    condition     = local.manifest_subject_repos["flux-manifests"] == "bitwise-media-group@282673588/flux-manifests@987654321"
    error_message = "a manifest publisher's subject must pin the numeric ids once repository_id is known"
  }

  # main publishes edge, tags publish releases and move staging, the protected
  # environment moves stable.
  assert {
    condition     = length(local.manifest_publisher_subjects["flux-manifests"]) == 3
    error_message = "a manifest publisher is trusted from exactly three contexts: main, release tags and the promotion environment"
  }

  assert {
    condition     = length(local.chart_publisher_subjects) == 1
    error_message = "the chart publisher is trusted from main only - PR validation never gets push credentials"
  }
}

run "repository_id_may_lag" {
  command = plan

  variables {
    github = {
      manifest_publishers = {
        flux-manifests = { paths = ["manifests/*"] }
      }
    }
  }

  # The repo may not exist on GitHub when the store is first applied.
  assert {
    condition     = local.manifest_subject_repos["flux-manifests"] == "bitwise-media-group/flux-manifests"
    error_message = "without repository_id the subject falls back to the name-only form (which a post-cutoff repo never presents - set the id and re-apply)"
  }
}

run "one_role_per_manifest_publisher" {
  command = plan

  variables {
    github = {
      manifest_publishers = {
        flux-manifests       = { repository_id = 987654321, paths = ["manifests/*"] }
        patchy-app-manifests = { paths = ["manifests/patchy"] }
      }
    }
  }

  assert {
    condition     = length(aws_iam_role.manifest_publisher) == 2 && length(aws_iam_role_policy.manifest_publisher) == 2
    error_message = "every manifest_publishers key must get its own role and policy"
  }

  assert {
    condition     = aws_iam_role.manifest_publisher["patchy-app-manifests"].name == "platform-patchy-app-manifests-publisher"
    error_message = "manifest publisher roles are named <name>-<repo>-publisher"
  }

  # The platform repo keeps the wide manifests/* because it is the platform
  # authority; an application repo gets exactly its own path, so it can never
  # overwrite the platform entrypoint or another application.
  assert {
    condition = (
      one([for statement in data.aws_iam_policy_document.publisher["patchy-app-manifests"].statement : statement if statement.sid == "PushAndCreate"]).resources
      == toset(["arn:aws:ecr:eu-west-2:123456789012:repository/platform/manifests/patchy"])
    )
    error_message = "an application publisher's push must be scoped to exactly its declared paths"
  }

  assert {
    condition = contains(
      one([for statement in data.aws_iam_policy_document.publisher["flux-manifests"].statement : statement if statement.sid == "PushAndCreate"]).resources,
      "arn:aws:ecr:eu-west-2:123456789012:repository/platform/manifests/*",
    )
    error_message = "the platform publisher's push must cover the whole manifests namespace"
  }

  assert {
    condition = (
      one([for statement in data.aws_iam_policy_document.publisher["chart"].statement : statement if statement.sid == "PushAndCreate"]).resources
      == toset([
        "arn:aws:ecr:eu-west-2:123456789012:repository/platform/charts/*",
        "arn:aws:ecr:eu-west-2:123456789012:repository/platform/images/*",
        "arn:aws:ecr:eu-west-2:123456789012:repository/platform/artifacts/*",
      ])
    )
    error_message = "the chart publisher's push must be scoped to the mirror namespaces, never manifests/*"
  }

  assert {
    condition     = output.manifest_publishers["patchy-app-manifests"].subjects.release == "^https://github\\.com/bitwise-media-group/patchy-app-manifests/\\.github/workflows/publish\\.yaml@refs/tags/v.+$"
    error_message = "each publisher's release subject must be exported for the cluster module's applications[*].verify.subject"
  }

  assert {
    condition     = output.signed_identity_subjects.manifests == "^https://github\\.com/bitwise-media-group/flux-manifests/\\.github/workflows/publish\\.yaml@refs/tags/v.+$"
    error_message = "signed_identity_subjects.manifests must follow the platform publisher (github.platform), not any application"
  }

  assert {
    condition     = output.platform_manifests_url == "oci://123456789012.dkr.ecr.eu-west-2.amazonaws.com/platform/manifests/platform"
    error_message = "the platform entrypoint url is <registry>/<prefix>/manifests/platform"
  }
}

run "platform_publisher_must_be_declared" {
  command = plan

  variables {
    github = {
      platform = "platform-manifests"
      manifest_publishers = {
        flux-manifests = { paths = ["manifests/*"] }
      }
    }
  }

  expect_failures = [var.github]
}

run "registry_output_is_not_a_cache" {
  command = plan

  assert {
    condition     = output.platform_registry.is_pull_through_cache == false
    error_message = "this IS the store, so a cluster wired here reads it directly and must appear in direct_pull_principals"
  }

  assert {
    condition     = output.platform_registry.url == "123456789012.dkr.ecr.eu-west-2.amazonaws.com/platform"
    error_message = "the url must be the registry host plus the repository prefix, ready to pass straight to a cluster"
  }
}

run "kms_signing_grants_publishers" {
  command = plan

  variables {
    signing_kms_key_arn = "arn:aws:kms:eu-west-2:123456789012:key/1234abcd-12ab-4bcd-8def-1234567890ab"
  }

  assert {
    condition = alltrue([
      for publisher in values(data.aws_iam_policy_document.publisher) : anytrue([
        for statement in publisher.statement :
        statement.sid == "CosignSign" && contains(statement.actions, "kms:Sign")
      ])
    ])
    error_message = "KMS signing mode must grant every publisher kms:Sign on the signing key"
  }

  assert {
    condition     = output.signing_kms_key_arn == "arn:aws:kms:eu-west-2:123456789012:key/1234abcd-12ab-4bcd-8def-1234567890ab"
    error_message = "the signing key must be exported for wiring into the cluster module's signed_identity"
  }
}

run "keyless_signing_grants_no_kms" {
  command = plan

  assert {
    condition = !anytrue(flatten([
      for publisher in values(data.aws_iam_policy_document.publisher) : [
        for statement in publisher.statement : statement.sid == "CosignSign"
      ]
    ]))
    error_message = "keyless mode must grant the publishers no KMS access"
  }
}
