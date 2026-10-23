# Migrating

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
