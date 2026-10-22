# artifact-store

The central platform artifact store on ECR. It's one repository prefix holding every artifact the clusters consume, plus
the GitHub Actions publishers allowed to write to it. Apply it **once**, in the platform account.

```hcl
module "store" {
  source = "git::https://github.com/bitwise-media-group/terraform-aws-eks-flux.git//modules/artifact-store?ref=vX.Y.Z"

  name              = "platform"
  repository_prefix = "platform"
  organization_id   = "o-…"

  github = {
    manifest_publishers = {
      flux-manifests       = { repository_id = 123456789, paths = ["manifests/*"] }
      patchy-app-manifests = { repository_id = 987654321, paths = ["manifests/patchy"] }
    }
  }
}
```

The runnable version is [`examples/artifact-store`](../getting-started/examples.md#artifact-store).

## What it creates

| Resource                                | Purpose                                                                                                                                                                |
| --------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Repository creation template            | `CREATE_ON_PUSH` for everything beneath the prefix: lifecycle policy, mutable tags, encryption, tags                                                                   |
| Template service role                   | The role ECR assumes when it creates a repository. It trusts all three ECR creation principals, so the template can later serve pull-through cache and replication too |
| Registry policy                         | Pull for the ECR pull-through cache service, org-wide, plus `direct_pull_principals`                                                                                   |
| Enhanced scanning configuration         | Scanning across the platform prefix (`enhanced_scanning`)                                                                                                              |
| Chart publisher role                    | flux-containers: push to `charts/*` and `images/*` from its default branch                                                                                             |
| One manifest publisher role per repo    | Push to the declared `paths`, from release tags, `main` and the promotion environment                                                                                  |
| GitHub Actions OIDC provider (optional) | Created only when `oidc_provider_arn` isn't passed                                                                                                                     |

The store holds no signing key. Artifacts are signed keylessly by the publishing workflows, or with the
[kms-signing-key](kms-signing-key.md) when `signing_kms_key_arn` is set, which grants the publisher roles `kms:Sign`.

## How it works

### Paths and publishers

| Path                                                            | Published by                                               |
| --------------------------------------------------------------- | ---------------------------------------------------------- |
| `<prefix>/charts/<name>`, `<prefix>/images/<original-path>`     | flux-containers (the chart publisher)                      |
| `<prefix>/manifests/platform`, `<prefix>/manifests/<component>` | the platform repo (`github.platform`, paths `manifests/*`) |
| `<prefix>/manifests/<application>`                              | that application's repo (paths `manifests/<application>`)  |

Each repo sets its role's ARN, from the `manifest_publishers["<repo>"].arn` output, as its `AWS_MANIFEST_PUBLISHER_ROLE`
variable. The same output carries each repo's signing subjects (`subjects.release`, `subjects.edge`). An application's
`release` subject is what the cluster module's `applications[*].verify.subject` pins.

### Trust contexts

Every manifest publisher is trusted from the same three GitHub contexts:

| Context                   | Publishes                                |
| ------------------------- | ---------------------------------------- |
| `v*` release tags         | versioned artifacts, and moves `staging` |
| merges to `main`          | the `edge` channel                       |
| the promotion environment | moves `stable` (`promotion_environment`) |

Repos created after 2026-07-15 present immutable subjects with numeric ids, so set each publisher's `repository_id` as
soon as the repo exists. Until then the subject falls back to the name-only form, which never matches such a repo.

### Reads

Reads are granted **org-wide** to the ECR pull-through cache service (`aws:PrincipalOrgID`, optionally narrowed by
`organization_paths`), not per account. A new cluster account onboards by applying [registry-cache](registry-cache.md)
there, never by editing this module. `direct_pull_principals` admits clusters that read the store directly. Wire those
from a cluster module's `registry_reader_principals` output.

`aws_ecr_registry_policy` is a singleton per account and region. If the account needs other registry policy statements,
merge them in through `additional_registry_statements`.

### Upgrading from 3.x

Before 4.0 the store had a single manifests publisher (`github.manifests_id`). The platform publisher's role is renamed
on upgrade, from `<name>-manifest-publisher` to `<name>-<repo>-publisher`. After applying, update the platform repo's
`AWS_MANIFEST_PUBLISHER_ROLE` from the new output.

--8<-- "modules/artifact-store/README.md:tf-docs"
