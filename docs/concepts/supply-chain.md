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

Tags are **immutable**, so a published tag can never be re-pointed at a different digest. The one exception is the
channel tags (`staging`, `stable`, `edge`) on the manifest images, which must move between releases. ECR applies the
creation template with the longest matching prefix, so `<prefix>/manifests` gets its own template:
`IMMUTABLE_WITH_EXCLUSION`, exempting exactly those three tags. Version tags stay immutable everywhere.

### Who can push

The publishers are the platform's only long-lived identities. They assume roles through the account's GitHub Actions
OIDC provider, and each role can push only to its own paths:

- **The chart publisher** (flux-containers) pushes `charts/*` and `images/*`, from its default branch only. Pull request
  validation never gets push credentials.
- **One manifest publisher per repo** in `github.manifest_publishers`. Each is trusted from three contexts: release
  tags, which publish versions and move `staging`; merges to `main`, which publish `edge`; and the protected promotion
  environment, which moves `stable`. The platform repo keeps `manifests/*` because it's the platform authority. An
  application repo gets `manifests/<app>` only, so it can never overwrite the platform or another application.

GitHub's OIDC subjects for repos created after 2026-07-15 embed numeric ids:
`repo:<org>@<org id>/<repo>@<repo id>:<context>`. The trust policies pin those ids. Until a publisher's `repository_id`
is set, its subject falls back to the name-only form, which such a repo never presents.

### Who can pull

Nothing, by default, except **the ECR pull-through cache service, organization-wide**, matched on `aws:PrincipalOrgID`.
A new cluster account onboards by applying [registry-cache](../modules/registry-cache.md) in that account. Nobody edits
the store.

`direct_pull_principals` is the escape hatch for clusters allowed to read the store directly.

!!! note "The registry policy is a singleton"

    `aws_ecr_registry_policy` is one per account per region, and the artifact store owns it. If the account uses
    registry policies for anything else, merge those statements in through `additional_registry_statements`.

## The registry cache

[registry-cache](../modules/registry-cache.md) is a pull-through cache of the store, applied in each cluster's own
account and region. Images come from a registry beside the nodes, so there's no cross-account data path at pull time and
no cross-region egress. The local prefix defaults to the upstream one, so image paths are the same on both sides. You
can move a cluster between the cache and the store by changing one variable.

A cache creates each repository on its **first pull**. Every puller (the kubelet, the flux controllers, Kyverno)
therefore needs `ecr:CreateRepository` and `ecr:BatchImportUpstreamImage` as well as read access. Without them, a fresh
cluster fails on its first image.

Digests are preserved end to end, so cosign verification works through the cache just as it does against the store.
Signatures are ordinary tagged manifests (`sha256-<digest>.sig`) and pull through with everything else.

## Choosing a registry

`platform_registry` takes a `{ url, is_pull_through_cache }` object. Both registry modules emit exactly that shape, so
wire it from a module output rather than writing it by hand:

```hcl
module "cache" {
  source   = ".../modules/registry-cache"
  upstream = { registry_id = "…", region = "eu-west-2" }
}

module "cluster" {
  source            = ".../terraform-aws-eks-flux"
  platform_registry = module.cache.platform_registry # is_pull_through_cache = true
}
```

The flag matters. It's what grants the cluster's pullers the create and import permissions a cache needs.

To read the store directly, pass `module.store.platform_registry` instead (`is_pull_through_cache = false`). The store
must then admit the cluster's `registry_reader_principals` output in its `direct_pull_principals`.

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
