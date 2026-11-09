# Registry & signing

Clusters never pull from a public registry. Every chart, image and manifest image comes from one ECR prefix, is
cosign-signed by the workflow that published it, and is verified before it runs. A Kyverno policy enforces the
no-public-registry rule.

## The artifact store

[artifact-store](../modules/artifact-store.md) is applied once, in the platform account. Everything the clusters consume
lives beneath one repository prefix:

| Path                               | Contents                         | Published by            |
| ---------------------------------- | -------------------------------- | ----------------------- |
| `<prefix>/charts/<name>`           | Helm charts                      | flux-containers         |
| `<prefix>/images/<original-path>`  | Digest-pinned mirrored images    | flux-containers         |
| `<prefix>/manifests/platform`      | The platform entrypoint          | the platform repo       |
| `<prefix>/manifests/<component>`   | One image per platform component | the platform repo       |
| `<prefix>/manifests/<application>` | One image per application        | that application's repo |

### Create-on-push

ECR has no arbitrary-path model. Every one of those paths is a real repository that must exist before a push. A
**repository creation template** with `CREATE_ON_PUSH` solves that: publishers push to a path that doesn't exist yet,
and ECR creates the repository with the template's lifecycle policy, tag mutability, encryption and tags. Without a
matching template, ECR refuses to create on push at all.

Tags are **immutable**, so a published tag can never be re-pointed at a different digest, and no tag ever moves. A
channel is its newest immutable build: every merge to `main` publishes
`<base>-edge.<UTC yyyymmddhhmmss>.g<short commit>` (`0.1.0-edge.20261109153012.g70d3589`), every release
`X.Y.Z-staging.<UTC yyyymmddhhmmss>.g<short commit>`, and promotion adds the plain `vX.Y.Z` to a staging build.
Consumers follow a channel as a semver range narrowed to its builds (see [the contract](contract.md)). Every build also
carries `sha-<commit>`.

Every template also sets the lifecycle policy, in priority order: keep promoted releases (`v*`, shielded far beyond any
real count), keep the newest 20 staging and the newest 20 edge builds, expire `sha-*` images on no release or channel
build 30 days after push, and expire untagged manifests after 14 days. ECR never lets a rule expire an image a
higher-priority rule's tags select, so a promoted release (which also carries its staging and sha tags) and the newest
channel builds are never aged out. A creation template only applies to repositories ECR creates after it changes:
existing repositories keep their mutability and lifecycle policy until updated separately.

### Who can push

The publishers are the platform's only long-lived identities. They assume roles through the account's GitHub Actions
OIDC provider, and each role can push only to its own paths:

- **The chart publisher** (flux-containers) pushes `charts/*` and `images/*`, from its default branch only. Pull request
  validation never gets push credentials.
- **One manifest publisher per repo** in `github.manifest_publishers`. Each is trusted from three contexts: release
  tags, which publish staging builds; merges to `main`, which publish edge builds; and the protected promotion
  environment, which adds the stable `vX.Y.Z` tag to a staging build. The platform repo keeps `manifests/*` because it's
  the platform authority. An application repo gets `manifests/<app>` only, so it can never overwrite the platform or
  another application.

GitHub's OIDC subjects for repos created after 2026-07-15 embed numeric ids:
`repo:<org>@<org id>/<repo>@<repo id>:<context>`. The trust policies pin those ids. Until a publisher's `repository_id`
is set, its subject falls back to the name-only form, which such a repo never presents.

### Who can pull

**Every account in the organization, read-only, in every region**, matched on `aws:PrincipalOrgID` and optionally
narrowed by `organization_paths` or `account_ids`. The grant covers pulls and tag listing, which the flux
`ECRArtifactTag` providers resolve application versions with. A new cluster account onboards without anyone editing the
store.

!!! note "The registry policy is a singleton"

    `aws_ecr_registry_policy` is one per account per region, and the artifact store owns it in every region it
    manages. If the account uses registry policies for anything else, merge those statements in through
    `additional_registry_statements`.

## Regional replicas

Publishers push to the store's primary region only. ECR replication copies every push to each of the store's
`replica_regions`, all in the store's own account. A cluster reads the replica in its own region, so a primary-region
outage stops new releases from arriving but never stops a cluster reconciling what it already runs, or bootstrapping.

ECR doesn't replicate repository settings. A replica repository gets its tag mutability, encryption and lifecycle only
from a creation template in its own region, so the store keeps a REPLICATION copy of each template in every replica
region. Deletes and lifecycle expiry don't replicate either: each region expires its own untagged images under the same
rules.

Replication only carries pushes made after a region is added. Adding a region is a store change, plus one run of that
region's `replication_backfill_commands` entry to copy what the store already holds.

## Choosing a registry

`platform_registry` takes a `{ url }` object. Wire it from the store's `platform_registries` output, which is keyed by
region, rather than writing it by hand:

```hcl
module "cluster" {
  source            = ".../terraform-aws-eks-flux"
  platform_registry = module.store.platform_registries["eu-west-2"] # the replica beside the cluster
}
```

Digests are preserved by replication, so cosign verification works against a replica just as it does against the
primary.

Every registry grant in the cluster module is scoped to the platform prefix (`repository/<prefix>/*`), never the whole
registry.

## Signing and verification

`signed_identity` picks one of two modes. You can't use both.

=== "Keyless (default)"

    Artifacts are signed by GitHub Actions OIDC identities through Fulcio and Rekor. No key material exists anywhere.

    - `manifests_subject` and `containers_subject` are Go regexps matched against the signing certificate's subject.
      The artifact store's `signed_identity_subjects` output provides them.
    - A dev cluster tracking the `edge` channel passes `signed_identity_subjects.manifests_edge` as
      `manifests_subject` instead, since edge images are signed by a different workflow.
    - `issuer` defaults to GitHub Actions' token issuer.
    - Because GitHub is the signer, the same values work for clusters on any cloud.

    ```hcl
    signed_identity = {
      manifests_subject  = module.store.signed_identity_subjects.manifests
      containers_subject = module.store.signed_identity_subjects.containers
    }
    ```

=== "KMS"

    Publishers sign with an asymmetric KMS key: `cosign sign --key awskms:///<arn>`.

    - Create the key with [kms-signing-key](../modules/kms-signing-key.md).
    - Pass its ARN to the store's `signing_kms_key_arn`, which grants the publisher roles `kms:Sign`.
    - Pass the same ARN to the cluster's `signed_identity.kms_key_arn`, and leave the subjects unset.

    The cluster reads the key's public half when it plans. The bootstrap distributes it as the `flux-system`
    `cosign-pub` Secret. The ARN is published as `SIGNED_IDENTITY_KMS_KEY`, and Kyverno's controllers get
    `kms:GetPublicKey` and `kms:Verify` to resolve it. The private key never leaves KMS.

    ```hcl
    signed_identity = {
      kms_key_arn = module.signing_key.key_arn
    }
    ```

### What gets verified

| Artifact                | Verified by                                                                                                     |
| ----------------------- | --------------------------------------------------------------------------------------------------------------- |
| The platform entrypoint | A kustomize patch on the generated `flux-system` `OCIRepository` (`matchOIDCIdentity`, or the `cosign-pub` key) |
| Every component image   | The `OCIRepository` the entrypoint emits for it                                                                 |
| Every application image | The `OCIRepository` its seed emits (keyless subject or `verify.keyed`)                                          |
| Every container image   | Kyverno's image verification policy at admission                                                                |

`FluxInstance.spec.sync` has no verify field, which is why the entrypoint's verification arrives as a patch.
