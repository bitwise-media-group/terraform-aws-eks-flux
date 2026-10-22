# Migrating from 3.x

4.0 is a breaking release. It removes everything application-specific from the cluster module and replaces it with
generic application inputs.

## What changed

| 3.x                                                              | 4.0                                                                                                |
| ---------------------------------------------------------------- | -------------------------------------------------------------------------------------------------- |
| `var.patchy`, `var.stack_components`                             | Removed. patchy moves to [patchy-app-manifests]; components are elected with `platform_components` |
| `workload_identity.patchy_egress_broker`                         | Removed. Application grants arrive through `workload_grants`                                       |
| The `patchy-status` dex client                                   | Removed. Applications register clients through `applications[*].dex_clients`                       |
| `PATCHY_*`, `CLAUDE_*`, `AGENT_*`, `KUBECTL_OIDC_*` cluster vars | Removed. Application values ride in `<key>-vars` through `application_vars`                        |
| `modules/secrets`                                                | Renamed `modules/sso-secrets`, holding dex connector containers only                               |
| artifact-store `github.manifests_id`                             | Replaced by `github.manifest_publishers`, one publisher per repo                                   |

## Migrating a root

patchy-app-manifests' `modules/aws` emits exactly the maps the new generic inputs take. A root migrates by composing
that module next to the cluster module, as [`examples/complete`](../getting-started/examples.md#complete) does. The IAM
role names, secret names and namespaces are unchanged, so nothing is replaced.

For the artifact store, the platform publisher's role is renamed from `<name>-manifest-publisher` to
`<name>-<repo>-publisher`. After applying, update the platform repo's `AWS_MANIFEST_PUBLISHER_ROLE` from the new
`manifest_publishers` output.

## Cutting over a running cluster

The ordered cut-over is documented in the platform README's "Migrating from 3.x":

1. a transitional 3.x manifests release
2. freezing the old optional tier
3. applying 4.0
4. re-pointing the sync through `FLUX_SYNC_URL`
5. removing the old tier

You can roll back through the re-point step with `kubectl patch fluxinstance` back to the old URL.

[patchy-app-manifests]: https://github.com/bitwise-media-group/patchy-app-manifests
