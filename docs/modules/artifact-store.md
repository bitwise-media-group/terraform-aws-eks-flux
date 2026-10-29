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

| Resource                                | Purpose                                                                                                                                                                         |
| --------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Repository creation templates           | `CREATE_ON_PUSH` in the primary and `REPLICATION` in each replica region: lifecycle policy, immutable tags (`manifests/` exempts `edge`, `stable`, `staging`), encryption, tags |
| Template service role                   | The role ECR assumes when it creates a repository, in any region                                                                                                                |
| Replication configuration               | Copies every push beneath the prefix to each of `replica_regions`, in the same account (only when `replica_regions` is set)                                                     |
| Registry policies                       | Org-wide read (pull and tag listing) in every region                                                                                                                            |
| Enhanced scanning configurations        | Scanning across the platform prefix in every region (`enhanced_scanning`)                                                                                                       |
| Chart publisher role                    | flux-containers: push to `charts/*` and `images/*` from its default branch                                                                                                      |
| One manifest publisher role per repo    | Push to the declared `paths`, from release tags, `main` and the promotion environment                                                                                           |
| GitHub Actions OIDC provider (optional) | Created only when `oidc_provider_arn` isn't passed                                                                                                                              |

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

Reads are granted **org-wide** (`aws:PrincipalOrgID`, optionally narrowed by `organization_paths` or `account_ids`), not
per account, in every region. A new cluster account onboards without editing this module.

`aws_ecr_registry_policy` is a singleton per account and region, and this module owns it in every region it manages. If
the account needs other registry policy statements, merge them in through `additional_registry_statements`.

### Replicas

Publishers push to the primary region only. `replica_regions` lists the regions, in the same account, that ECR
replication copies every push to, including channel-tag moves. A cluster passes the `platform_registries` entry for its
own region as its `platform_registry`, so it keeps reconciling while the primary region is down.

ECR doesn't replicate repository settings, deletes or lifecycle expiry. Each replica region therefore gets its own
`REPLICATION` copy of every creation template, and expires its own untagged images under the same rules. KMS keys are
regional, so `kms_key_arns` needs one per region when set.

Replication only carries pushes made after a region is added. Run the region's `replication_backfill_commands` entry
once to copy what the store already holds.

### Upgrading from 3.x

Before 4.0 the store had a single manifests publisher (`github.manifests_id`). The platform publisher's role is renamed
on upgrade, from `<name>-manifest-publisher` to `<name>-<repo>-publisher`. After applying, update the platform repo's
`AWS_MANIFEST_PUBLISHER_ROLE` from the new output.

--8<-- "modules/artifact-store/README.md:tf-docs"
