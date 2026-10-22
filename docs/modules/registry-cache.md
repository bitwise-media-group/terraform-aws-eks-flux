# registry-cache

An ECR pull-through cache of the platform [artifact store](artifact-store.md), applied in a cluster's own account and
region. This is the default way a cluster reaches the store. Images come from a registry beside the nodes, and the store
stays closed to direct reads.

```hcl
module "cache" {
  source = "git::https://github.com/bitwise-media-group/terraform-aws-eks-flux.git//modules/registry-cache?ref=vX.Y.Z"

  name = "platform"
  upstream = {
    registry_id       = "111122223333" # the store's registry_id output
    region            = "eu-west-2"
    repository_prefix = "platform"
  }
}

module "cluster" {
  source            = "git::https://github.com/bitwise-media-group/terraform-aws-eks-flux.git?ref=vX.Y.Z"
  platform_registry = module.cache.platform_registry
  # ...
}
```

The runnable version is [`examples/registry-cache`](../getting-started/examples.md#registry-cache).

## What it creates

| Resource                     | Purpose                                                                                                                                 |
| ---------------------------- | --------------------------------------------------------------------------------------------------------------------------------------- |
| Pull-through cache rule      | Maps the local prefix onto the store's prefix                                                                                           |
| Upstream role                | The role ECR assumes to fetch from the store. Required cross-account; created unconditionally so the module behaves the same either way |
| Repository creation template | Settings for the repositories ECR creates as the cache fills: **mutable** tags, encryption, an untagged-expiry lifecycle                |
| Consumer policy              | A managed policy for pullers outside the cluster module, such as CI runners and bastions                                                |

## How it works

**Nothing changes in the store.** Its registry policy admits every pull-through cache in the organization by
`aws:PrincipalOrgID`. Onboarding an account means applying this module there and nothing else.

**Repositories appear on first pull.** The cache creates each repository the first time something pulls it. Every puller
therefore needs `ecr:CreateRepository` and `ecr:BatchImportUpstreamImage` as well as read access. The
`platform_registry` output carries `is_pull_through_cache = true`, which is what makes the cluster module grant those to
the kubelet, the flux controllers and Kyverno. Anything else that pulls can attach `consumer_policy_arn`.

**Paths match the store.** `repository_prefix` defaults to the upstream prefix, so image paths are the same on both
sides. You can move a cluster between the cache and the store by changing one variable.

**Tags must stay mutable.** The channel tags (`staging`, `stable`, `edge`) move upstream. An immutable cache repository
could never take the updated tag.

**Signatures pull through.** Digests are preserved end to end, and cosign signatures are ordinary tagged manifests
(`sha256-<digest>.sig`). Verification works through the cache just as it does against the store.

**Untagged manifests expire** after `untagged_expiry_days`. They're cached again on the next pull, so this controls
cost, not retention.

!!! warning "Unvalidated for helm charts and signatures"

    ECR-to-ECR pull-through copies manifests and blobs, so OCI chart artifacts and `.sig` tags should pass through
    intact. The whole verification chain depends on it, though, so confirm both on a cluster's first apply.

--8<-- "modules/registry-cache/README.md:tf-docs"
