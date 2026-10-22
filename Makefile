# Copyright 2026 BitWise Media Group Ltd
# SPDX-License-Identifier: MIT
#
# terraform-aws-eks-flux — EKS cluster (Cilium ENI, Karpenter) + ECR artifact
# store + flux-operator bootstrap for a generic flux-managed platform.
#
# Everything lives in mise tasks: common/ plus the terraform archetype
# (fmt/lint/docs/init/plan + pinned tools) come from the shared toolchain
# submodule at .mise/, selected in the root mise.toml, which also includes the
# repo-local `test` fan-out and docs-site tasks (tasks.toml). This Makefile is
# only the thin forwarding shim — `make <task>` == `mise run <task>`.
#
# docs-build and sync are repo-local task names the archetype shim doesn't
# know; naming them here forwards them explicitly, so the docs/ directory (or
# any same-named path) can never shadow a target.
MISE_TASKS += docs-build sync
include .mise/archetypes/terraform/include.mk
