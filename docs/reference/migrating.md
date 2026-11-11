# Migrating

## Application seeds under Terraform

`modules/application` keeps its seed (`application-<name>`: the `<name>-manifests` ResourceSetInputProvider and
ResourceSet) under Terraform on every apply. It no longer hands the seed to the image (`ignore_changes` is gone), so the
semver range or channel moves in the same apply as the infrastructure the application's next release needs.
`image.semver` now combines with `channel = "edge"` to bound it (`^1.0.0-0`: every edge build up to the next breaking
change), and `stable` with `semver` is rejected. The cluster root's `applications` are unchanged.

For an application root built on `modules/application`, in this order:

1. Release an image without the `flux/` copies of the two seed objects (drop `../../flux` from each deploy tree). They
   carry `kustomize.toolkit.fluxcd.io/prune: disabled`, so the next reconcile leaves them in place, unowned.
2. Bump the module and apply. The release keeps its address, so nothing is reinstalled or pruned. The first apply that
   changes the seed's values upgrades `application-<name>` in place and takes both objects back; until then they keep
   what the image last applied.

Applying the module while the image still ships `flux/` makes the two fight: every apply re-points the objects and the
image's Kustomization puts its own copy back on its next reconcile.

## Release channels: edge and stable

Every tag is immutable, and there is no `staging` channel any more. A repository's release workflow publishes on `main`
only: an edge build (`<next version>-edge.<UTC yyyymmddhhmmss>.g<short commit>`) on every push that cuts no release,
and, when a release is cut, the stable `vX.Y.Z` added to the newest edge build of that version. Edge builds and stable
releases carry the same signer, the repository's `release.yaml` on `main`.

| Before                                                                     | Now                                                                                                                 |
| -------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------- |
| `flux.sync.ref = "staging"`, `image.channel = "staging"`                   | Rejected. Use `edge` (trunk) or `stable`                                                                            |
| `signed_identity_subjects.manifests_edge` for an edge cluster              | Removed. `signed_identity_subjects.manifests` verifies both channels                                                |
| `signed_identity_subjects.manifests`: the platform repo's `publish.yaml`   | The `release.yaml` on `main` of every repo `github.manifest_signers` matches (default `[^/]+`, every org repo)      |
| `manifest_publishers[*].subjects.release`, `.subjects.edge`                | `manifest_publishers[*].subject`, the repo's `release.yaml` on `main`                                               |
| publisher roles trusted from `main`, `v*` tags and `promotion_environment` | Trusted from `main` only; `promotion_environment` is removed                                                        |
| `staging_retention_count` and the `*-staging.*` lifecycle rule             | Removed. Re-apply each existing repository's lifecycle policy (`aws ecr put-lifecycle-policy`) to drop the old rule |

Apply the artifact store and the clusters before the publishing repos switch to their release workflow, or the clusters
reject the new signatures and stay on the builds they have.

## Application node groups

`modules/application` no longer takes `node_groups`: an application root calls
[`modules/node-group`](../modules/node-group.md) beside it, fed from the same `application_target`. See
[Capacity for an application](../concepts/capacity.md#capacity-for-an-application). To keep existing groups without a
replacement, give each call the name the application module used (`<name>-<key>`) and move its state:

```hcl
module "node_group" {
  source   = "git::https://github.com/bitwise-media-group/terraform-aws-eks-flux.git//modules/node-group?ref=vX.Y.Z"
  for_each = local.node_groups # the map node_groups used to take

  cluster_name              = local.cluster.name
  name                      = "patchy-${each.key}"
  node_role_arn             = local.cluster.node_role_arn
  subnet_ids                = local.cluster.node_subnet_ids
  cluster_security_group_id = local.cluster.cluster_security_group_id

  # instance_types, sizes, ami_type / ami, labels and taints as before. The
  # Cilium bootstrap taint is added by the module (cilium_agent_taint), so
  # don't list it.
}

moved {
  from = module.patchy.module.node_group
  to   = module.node_group
}
```

## From 4.x

5.0 is a breaking release: `applications[*].dex_clients` leaves the cluster module. Applications register their OIDC
clients as `DexClient` objects in their own images, which the dex-client-controller in the platform's dex component
reconciles. 5.0 also adds [`modules/application`](../modules/application.md) and the `application_target` output, for
publishing an application from a root of its own.

| 4.x                                                   | 5.0                                                                                      |
| ----------------------------------------------------- | ---------------------------------------------------------------------------------------- |
| `applications[*].dex_clients`                         | Removed. Ship a `DexClient` in the application image                                     |
| `${SECRET_PREFIX}dex-client-<id>` for application ids | Deleted on apply. The controller writes `<name>-dex-client` in the application namespace |
| `DEX_CLIENTS`: platform and application clients       | Platform clients only (`flux-web`, kubectl)                                              |
| an application seeded only from the cluster root      | Either the cluster root or its own root (`modules/application`), never both              |

### Order

1. **Platform first.** Roll out the flux-manifests release that runs dex-client-controller. It keeps honouring
   `DEX_CLIENTS`, so existing clients keep working.
2. **Ship the `DexClient`.** Release the application image with a `DexClient` whose `<namespace>-<name>` equals the old
   client id, and read the generated Secret instead of syncing the old container. patchy's `patchy-status` becomes a
   `DexClient` named `status` in `patchy`: the platform policy requires the `<namespace>-` prefix, so the id stays
   `patchy-status`, and the application reads the `status-dex-client` Secret instead of syncing
   `dex-client-patchy-status`. The secret is regenerated, so sessions sign in again once.
3. **Apply 5.0** with `dex_clients` dropped from every application entry (or its module's `application` output). The
   application clients' Secrets Manager secrets, their reader policies and their `DEX_CLIENTS` rows go away; dex keeps
   serving them through the controller.

The platform's own clients, their secrets and their `DEX_CLIENTS` rows are unchanged.

### Moving an application to its own root

Removing an `applications` key uninstalls the seed and prunes the application, so moving one from the cluster root to
[`modules/application`](../modules/application.md) is a reinstall: remove the key (and its `application_vars`,
`flux.namespaces`, `workload_grants` and `secret_readers` entries), apply the cluster root, then apply the application
root. The helm releases and IAM roles can't be held by both roots at once.

## From 3.x

4.0 is a breaking release. It removes everything application-specific from the cluster module and replaces it with
generic application inputs.

### What changed

| 3.x                                                              | 4.0                                                                                                    |
| ---------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------ |
| `var.patchy`, `var.stack_components`                             | Removed. patchy moves to [patchy-app-manifests]; components are elected with `platform_components`     |
| `workload_identity.patchy_egress_broker`                         | Removed. Application grants arrive through `workload_grants`                                           |
| The `patchy-status` dex client                                   | Removed. Applications registered clients through `applications[*].dex_clients` (itself removed in 5.0) |
| `PATCHY_*`, `CLAUDE_*`, `AGENT_*`, `KUBECTL_OIDC_*` cluster vars | Removed. Application values ride in `<key>-vars` through `application_vars`                            |
| `modules/secrets`                                                | Renamed `modules/sso-secrets`, holding dex connector containers only                                   |
| artifact-store `github.manifests_id`                             | Replaced by `github.manifest_publishers`, one publisher per repo                                       |

### Migrating a root

patchy-app-manifests' `modules/aws` emits exactly the maps the new generic inputs take. A root migrates by composing
that module next to the cluster module, as [`examples/complete`](../getting-started/examples.md#complete) does. The IAM
role names, secret names and namespaces are unchanged, so nothing is replaced.

For the artifact store, the platform publisher's role is renamed from `<name>-manifest-publisher` to
`<name>-<repo>-publisher`. After applying, update the platform repo's `AWS_MANIFEST_PUBLISHER_ROLE` from the new
`manifest_publishers` output.

### Cutting over a running cluster

The ordered cut-over is documented in the platform README's "Migrating from 3.x":

1. a transitional 3.x manifests release
2. freezing the old optional tier
3. applying 4.0
4. re-pointing the sync through `FLUX_SYNC_URL`
5. removing the old tier

You can roll back through the re-point step with `kubectl patch fluxinstance` back to the old URL.

[patchy-app-manifests]: https://github.com/bitwise-media-group/patchy-app-manifests
