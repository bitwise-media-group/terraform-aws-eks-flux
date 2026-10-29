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
    condition     = contains(aws_ecr_repository_creation_template.primary["platform"].applied_for, "CREATE_ON_PUSH")
    error_message = "the creation template must apply to CREATE_ON_PUSH"
  }

  assert {
    condition     = aws_ecr_repository_creation_template.primary["platform"].prefix == "platform"
    error_message = "the template must be keyed on the same prefix everything is published beneath"
  }

  assert {
    condition     = aws_ecr_repository_creation_template.primary["platform"].image_tag_mutability == "IMMUTABLE"
    error_message = "charts and images must be tag-immutable: a published tag never changes digest"
  }

  # The longer prefix wins, so this template alone governs every manifest image.
  assert {
    condition     = aws_ecr_repository_creation_template.primary["manifests"].prefix == "platform/manifests"
    error_message = "the manifests template must be keyed on <prefix>/manifests to take precedence there"
  }

  assert {
    condition     = contains(aws_ecr_repository_creation_template.primary["manifests"].applied_for, "CREATE_ON_PUSH")
    error_message = "the manifests template must apply to CREATE_ON_PUSH, or manifest pushes to new paths fail"
  }

  # Channel tags (staging, stable, edge) move between releases; version tags
  # must not.
  assert {
    condition     = aws_ecr_repository_creation_template.primary["manifests"].image_tag_mutability == "IMMUTABLE_WITH_EXCLUSION"
    error_message = "manifest images must be tag-immutable except for their channel tags"
  }

  assert {
    condition = (
      toset([for f in aws_ecr_repository_creation_template.primary["manifests"].image_tag_mutability_exclusion_filter : f.filter]) == toset(["edge", "stable", "staging"])
      && alltrue([for f in aws_ecr_repository_creation_template.primary["manifests"].image_tag_mutability_exclusion_filter : f.filter_type == "WILDCARD"])
    )
    error_message = "exactly the edge, stable and staging channel tags may move on manifest images"
  }

  # ECR fails repository creation outright if the template sets tags or KMS
  # without a role to assume. The template's custom_role_arn is a direct
  # reference to this role, so its existence is the part worth asserting (the
  # ARN itself is unknown until apply).
  assert {
    condition     = aws_iam_role.creation.name == "platform-ecr-repository-creation"
    error_message = "a creation template setting resource tags requires a role for ECR to assume"
  }

  # The same role serves the replicas' REPLICATION templates.
  assert {
    condition = alltrue([
      for principal in ["ecr.amazonaws.com", "replication.ecr.amazonaws.com"] :
      anytrue([
        for block in one(data.aws_iam_policy_document.creation_assume_role.statement).principals :
        contains(block.identifiers, principal)
      ])
    ])
    error_message = "the creation role must be assumable by every ECR principal that creates repositories"
  }
}

run "no_replicas_by_default" {
  command = plan

  assert {
    condition     = length(aws_ecr_replication_configuration.platform) == 0
    error_message = "without replica_regions the module must not claim the registry's replication configuration"
  }

  assert {
    condition     = length(aws_ecr_repository_creation_template.replica) == 0 && length(aws_ecr_registry_policy.replica) == 0
    error_message = "without replica_regions there are no replica templates or registry policies"
  }

  assert {
    condition     = keys(output.platform_registries) == ["eu-west-2"]
    error_message = "without replicas the only registry is the primary"
  }
}

run "replicas_mirror_the_primary" {
  command = plan

  variables {
    replica_regions = ["us-east-1", "ap-southeast-2"]
  }

  # Repository settings are not replicated: a replica repository gets its tag
  # mutability (and the channel-tag exclusions) only from a REPLICATION
  # template in its own region.
  assert {
    condition = alltrue([
      for region in ["us-east-1", "ap-southeast-2"] : alltrue([
        for name in ["platform", "manifests"] : (
          aws_ecr_repository_creation_template.replica["${region}/${name}"].region == region
          && aws_ecr_repository_creation_template.replica["${region}/${name}"].applied_for == toset(["REPLICATION"])
          && aws_ecr_repository_creation_template.replica["${region}/${name}"].prefix == aws_ecr_repository_creation_template.primary[name].prefix
          && aws_ecr_repository_creation_template.replica["${region}/${name}"].image_tag_mutability == aws_ecr_repository_creation_template.primary[name].image_tag_mutability
          && aws_ecr_repository_creation_template.replica["${region}/${name}"].lifecycle_policy == aws_ecr_repository_creation_template.primary[name].lifecycle_policy
        )
      ])
    ])
    error_message = "every replica region needs a REPLICATION copy of each primary template with the same prefix, mutability and lifecycle"
  }

  assert {
    condition = alltrue([
      for region in ["us-east-1", "ap-southeast-2"] :
      toset([for f in aws_ecr_repository_creation_template.replica["${region}/manifests"].image_tag_mutability_exclusion_filter : f.filter]) == toset(["edge", "stable", "staging"])
    ])
    error_message = "a replica's manifest images must keep exactly the primary's movable channel tags, or a moved tag fails to replicate"
  }

  assert {
    condition = (
      toset([for d in one(one(aws_ecr_replication_configuration.platform).replication_configuration).rule[0].destination : d.region]) == toset(["us-east-1", "ap-southeast-2"])
      && alltrue([for d in one(one(aws_ecr_replication_configuration.platform).replication_configuration).rule[0].destination : d.registry_id == "123456789012"])
    )
    error_message = "the store must replicate to exactly replica_regions, within its own account"
  }

  assert {
    condition = (
      one(one(one(aws_ecr_replication_configuration.platform).replication_configuration).rule[0].repository_filter).filter == "platform/"
      && one(one(one(aws_ecr_replication_configuration.platform).replication_configuration).rule[0].repository_filter).filter_type == "PREFIX_MATCH"
    )
    error_message = "replication must cover exactly the <prefix>/ namespace"
  }

  assert {
    condition = alltrue([
      for region in ["us-east-1", "ap-southeast-2"] : (
        aws_ecr_registry_policy.replica[region].region == region
        && jsondecode(aws_ecr_registry_policy.replica[region].policy).Statement[0].Resource == "arn:aws:ecr:${region}:123456789012:repository/platform/*"
        && jsondecode(aws_ecr_registry_policy.replica[region].policy).Statement[0].Condition.StringEquals["aws:PrincipalOrgID"] == "o-abcdefghij"
      )
    ])
    error_message = "every replica region must grant the same org-wide read on its own repositories"
  }

  assert {
    condition     = output.platform_registries["ap-southeast-2"].url == "123456789012.dkr.ecr.ap-southeast-2.amazonaws.com/platform"
    error_message = "a replica's url must be its regional registry host plus the prefix, ready to pass to a cluster there"
  }

  assert {
    condition     = output.replication_backfill_commands["us-east-1"] == "aws ecr start-replication-backfill --region eu-west-2 --registry-id 123456789012 --destination region=us-east-1,registryId=123456789012"
    error_message = "each replica region needs a backfill command run against the primary"
  }

  # The creation role creates repositories in every region.
  assert {
    condition = toset(one(data.aws_iam_policy_document.creation.statement).resources) == toset([
      for region in ["eu-west-2", "us-east-1", "ap-southeast-2"] : "arn:aws:ecr:${region}:123456789012:repository/platform/*"
    ])
    error_message = "the creation role must be allowed to create repositories beneath the prefix in every region"
  }
}

run "replica_regions_reject_primary" {
  command = plan

  variables {
    replica_regions = ["eu-west-2"]
  }

  expect_failures = [aws_ecr_replication_configuration.platform]
}

run "kms_keys_cover_every_region" {
  command = plan

  variables {
    replica_regions = ["us-east-1"]
    kms_key_arns = {
      eu-west-2 = "arn:aws:kms:eu-west-2:123456789012:key/1234abcd-12ab-4bcd-8def-1234567890ab"
    }
  }

  expect_failures = [aws_ecr_repository_creation_template.primary]
}

run "kms_keys_are_regional" {
  command = plan

  variables {
    replica_regions = ["us-east-1"]
    kms_key_arns = {
      eu-west-2 = "arn:aws:kms:eu-west-2:123456789012:key/1234abcd-12ab-4bcd-8def-1234567890ab"
      us-east-1 = "arn:aws:kms:us-east-1:123456789012:key/5678abcd-12ab-4bcd-8def-1234567890ab"
    }
  }

  assert {
    condition = (
      one(aws_ecr_repository_creation_template.replica["us-east-1/manifests"].encryption_configuration).kms_key == "arn:aws:kms:us-east-1:123456789012:key/5678abcd-12ab-4bcd-8def-1234567890ab"
      && one(aws_ecr_repository_creation_template.primary["manifests"].encryption_configuration).kms_key == "arn:aws:kms:eu-west-2:123456789012:key/1234abcd-12ab-4bcd-8def-1234567890ab"
    )
    error_message = "each region's templates must encrypt with that region's key"
  }
}

run "reads_are_org_wide" {
  command = plan

  # One statement, no account list: aws:PrincipalOrgID matches every cluster's
  # readers, and every future member account is covered without touching this
  # module.
  assert {
    condition     = length(jsondecode(aws_ecr_registry_policy.platform.policy).Statement) == 1
    error_message = "the registry policy is exactly the org-wide read grant"
  }

  assert {
    condition     = jsondecode(aws_ecr_registry_policy.platform.policy).Statement[0].Condition.StringEquals["aws:PrincipalOrgID"] == "o-abcdefghij"
    error_message = "the read grant must be conditioned on the organization id, not on a per-account principal list"
  }

  # Pull, plus the tag listing the flux ECRArtifactTag providers resolve
  # application versions with - and nothing that writes.
  assert {
    condition = toset(jsondecode(aws_ecr_registry_policy.platform.policy).Statement[0].Action) == toset([
      "ecr:BatchGetImage",
      "ecr:GetDownloadUrlForLayer",
      "ecr:BatchCheckLayerAvailability",
      "ecr:DescribeImages",
      "ecr:ListImages",
    ])
    error_message = "the org-wide grant is read and list only"
  }

  assert {
    condition     = jsondecode(aws_ecr_registry_policy.platform.policy).Statement[0].Principal.AWS == "*"
    error_message = "the principal is wildcard-with-org-condition; naming accounts is exactly what this avoids"
  }
}

run "reads_narrow_to_accounts" {
  command = plan

  variables {
    account_ids = ["999988887777", "111122223333"]
  }

  # Still one statement and still conditioned on the org: the account list is
  # ANDed with it under the same StringEquals, never a replacement for it.
  assert {
    condition     = length(jsondecode(aws_ecr_registry_policy.platform.policy).Statement) == 1
    error_message = "narrowing to accounts must not add a statement beside the read grant"
  }

  assert {
    condition     = jsondecode(aws_ecr_registry_policy.platform.policy).Statement[0].Condition.StringEquals["aws:PrincipalOrgID"] == "o-abcdefghij"
    error_message = "the account list narrows the organization grant; the org condition must stay"
  }

  assert {
    condition     = jsondecode(aws_ecr_registry_policy.platform.policy).Statement[0].Condition.StringEquals["aws:PrincipalAccount"] == ["111122223333", "999988887777"]
    error_message = "account_ids must become a sorted aws:PrincipalAccount condition on the read grant"
  }
}

run "account_ids_must_be_account_ids" {
  command = plan

  variables {
    account_ids = ["o-abcdefghij"]
  }

  expect_failures = [var.account_ids]
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

run "registry_output_is_cluster_ready" {
  command = plan

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
