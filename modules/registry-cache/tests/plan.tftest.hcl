# Copyright 2026 BitWise Media Group Ltd
# SPDX-License-Identifier: MIT

# Plan-time contract tests with a mocked provider. The cache's job is to be
# indistinguishable from the store at the point of use, so these assert the
# wiring that makes a cluster's platform_registry swap a one-line change.

mock_provider "aws" {
  mock_data "aws_caller_identity" {
    defaults = {
      account_id = "999988887777"
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
  # rejects. Assertions below read the action list from a local rather than the
  # rendered document, so an empty stand-in costs nothing.
  mock_data "aws_iam_policy_document" {
    defaults = {
      json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}"
    }
  }
}

variables {
  upstream = {
    registry_id       = "123456789012"
    region            = "eu-west-2"
    repository_prefix = "platform"
  }
}

run "cache_rule" {
  command = plan

  assert {
    condition     = aws_ecr_pull_through_cache_rule.platform.upstream_registry_url == "123456789012.dkr.ecr.eu-west-2.amazonaws.com"
    error_message = "the upstream must be the store's ECR registry, composed from its account and region"
  }

  # Mandatory for a cross-account ECR upstream; kept unconditional so the module
  # behaves identically same-account. The rule's custom_role_arn is a direct
  # reference to this role, so its existence and trust are what a plan can check
  # (the ARN itself is unknown until apply).
  assert {
    condition     = aws_iam_role.cache.name == "platform-ecr-pull-through-cache"
    error_message = "a cross-account ECR upstream requires a role for ECR to assume"
  }

  assert {
    condition = anytrue([
      for block in one(data.aws_iam_policy_document.cache_assume_role.statement).principals :
      block.identifiers == toset(["pullthroughcache.ecr.amazonaws.com"])
    ])
    error_message = "only the ECR pull-through cache service may assume the fetch role"
  }

  assert {
    condition     = aws_ecr_pull_through_cache_rule.platform.upstream_repository_prefix == "platform"
    error_message = "the upstream prefix must match the store's, or nothing resolves"
  }
}

run "local_prefix_mirrors_upstream" {
  command = plan

  # Identical paths on both sides mean a cluster moves between store and cache
  # by swapping one variable.
  assert {
    condition     = local.repository_prefix == "platform"
    error_message = "the local prefix defaults to the upstream one so image paths are identical on both sides"
  }

  assert {
    condition     = output.platform_registry.url == "999988887777.dkr.ecr.eu-west-2.amazonaws.com/platform"
    error_message = "the cache's url must point at THIS account's registry — pulls stay local, which is the whole point"
  }
}

run "consumers_are_told_it_is_a_cache" {
  command = plan

  # This flag is what adds CreateRepository/BatchImportUpstreamImage to every
  # puller's grant in the cluster module. A cache materialises each repository
  # on its FIRST pull, so getting it wrong fails the first image pull of a fresh
  # cluster.
  assert {
    condition     = output.platform_registry.is_pull_through_cache == true
    error_message = "the cache must announce itself so the cluster grants its pullers first-pull create/import permissions"
  }

  assert {
    condition = alltrue([
      for action in ["ecr:CreateRepository", "ecr:BatchImportUpstreamImage"] :
      contains(local.consumer_actions, action)
    ])
    error_message = "the consumer policy must carry the first-pull permissions, not just read"
  }
}

run "creation_template_keeps_tags_mutable" {
  command = plan

  # Channel tags (staging, stable, edge) move upstream; an immutable cache
  # repository could never take the updated tag.
  assert {
    condition     = aws_ecr_repository_creation_template.cache.image_tag_mutability == "MUTABLE"
    error_message = "cached repositories must accept moved tags"
  }

  assert {
    condition     = contains(aws_ecr_repository_creation_template.cache.applied_for, "PULL_THROUGH_CACHE")
    error_message = "the template must apply to pull-through cache creation"
  }
}

run "distinct_local_prefix" {
  command = plan

  variables {
    repository_prefix = "platform-mirror"
  }

  assert {
    condition     = aws_ecr_pull_through_cache_rule.platform.ecr_repository_prefix == "platform-mirror"
    error_message = "the local prefix must be overridable for registries where the upstream name is taken"
  }

  assert {
    condition     = aws_ecr_pull_through_cache_rule.platform.upstream_repository_prefix == "platform"
    error_message = "overriding the local prefix must not change which upstream prefix is cached"
  }
}
