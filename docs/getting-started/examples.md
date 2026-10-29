# Examples

Every directory under `examples/` is a runnable root configuration. `make lint` validates and tflints each one. The code
on this page is pulled from those files when the site is built, so it always matches the release you're reading.

| Example                             | Apply in             | Shows                                                   |
| ----------------------------------- | -------------------- | ------------------------------------------------------- |
| [`artifact-store`](#artifact-store) | the platform account | The central store with one publisher per manifest repo. |
| [`minimal`](#minimal)               | a cluster account    | The smallest cluster that reconciles.                   |
| [`complete`](#complete)             | a cluster account    | Every surface on, with an application composed in.      |
| [`application`](#application)       | an application root  | An application published to an existing cluster.        |

Each example takes its account-specific values (VPC ids, subnet ids, the store's registry id, signing subjects) as
variables. See `variables.tf` beside each `main.tf`.

## artifact-store

The store is applied once, in the platform account. `manifest_publishers` declares one push role per repo that publishes
manifests. Each role can push only to the paths it lists, and `replica_regions` lists the regions clusters read a
replica from. See [artifact-store](../modules/artifact-store.md).

```hcl title="examples/artifact-store/main.tf"
--8<-- "examples/artifact-store/main.tf"
```

## minimal

The smallest cluster that reconciles: Cilium, Karpenter's IAM surface, the flux bootstrap and nothing else. It has no
DNS, Gateway, SSO or RBAC. The optional cluster vars are published as empty strings, and the platform skips the
components that need them. To reach anything running here you need `kubectl port-forward`.

```hcl title="examples/minimal/main.tf"
--8<-- "examples/minimal/main.tf"
```

## complete

Every surface turned on:

- the store's replica in the cluster's region
- DNS/TLS wiring and reserved Gateway addresses
- RBAC access entries and SSO
- the `staging` sync channel and the electable platform components
- one seeded application (patchy), composed the way a real root composes it

The application's maps are spelled out in `locals` here so the example plans on its own. A real root gets them from the
application repo's module. See [Applications](../concepts/applications.md).

```hcl title="examples/complete/main.tf"
--8<-- "examples/complete/main.tf"
```

!!! note "The helm provider block"

    Both cluster examples configure the helm provider with an `exec` plugin that runs `aws eks get-token`, not
    `data.aws_eks_cluster_auth`. A first apply takes much longer than that data source's 15-minute token lasts. See
    [Caveats](../reference/caveats.md#the-helm-provider-needs-the-aws-cli).

## application

An application published from a root of its own, with nothing changed in the cluster root: the seed, its vars, a
namespace and a secret reader role, all keyed to the cluster through the cluster root's `application_target` output. It
takes that output as a variable so it plans on its own; a real root reads it with `terraform_remote_state`. See
[application](../modules/application.md).

```hcl title="examples/application/main.tf"
--8<-- "examples/application/main.tf"
```
