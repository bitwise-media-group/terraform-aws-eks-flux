# application

Publishes one application to an existing cluster's Flux instance from a root of its own: another state, another
repository, another team. The cluster root doesn't change. The module reads the cluster through the root's
`application_target` output and creates everything the cluster root would otherwise create for the application.

```hcl
module "patchy" {
  source = "git::https://github.com/bitwise-media-group/terraform-aws-eks-flux.git//modules/application?ref=vX.Y.Z"

  name    = "patchy"
  cluster = data.terraform_remote_state.cluster.outputs.application_target

  image = {
    url    = "oci://<registry>/manifests/patchy"
    semver = "<1.0.0 >=0.1.0"
    verify = { subject = "^https://github\\.com/bitwise-media-group/patchy-app-manifests/.+$" }
  }

  vars           = { PATCHY_DOMAIN = "patchy.example.com" }
  namespaces     = ["patchy", "patchy-agents"]
  secret_readers = [{ namespace = "patchy", service_account = "patchy-secrets" }]
}
```

The root needs an `aws` provider in the cluster's account and region, and a `helm` provider pointed at the cluster. Both
charts ship inside the module, so the helm provider needs no registry credentials. See
[`examples/application`](../getting-started/examples.md#application).

## What it creates

| Release / resource    | Contents                                                                                                         | Lifecycle            |
| --------------------- | ---------------------------------------------------------------------------------------------------------------- | -------------------- |
| `helm_release.seed`   | Local chart `charts/application` (shared with the cluster root): the `<name>-manifests` RSIP + `ResourceSet`     | Bootstrap-only       |
| `helm_release.inputs` | Local chart `charts/inputs`: the `<name>-vars` ConfigMap and the pre-created namespaces, only when there are any | Terraform-reconciled |
| Workload roles        | `<cluster>-<key>` per `workload_grants` entry, bound through Pod Identity                                        | Terraform-reconciled |
| Secret reader roles   | `<cluster>-secrets-<ns>-<sa>` per `secret_readers` pair, trusted through the cluster's IRSA provider             | Terraform-reconciled |
| Node groups           | `<cluster>-<name>-<key>` per `node_groups` entry, through [node-group](node-group.md)                            | Terraform-reconciled |

## How it works

### Same names as the cluster root

Every name matches what the cluster root mints for an application it seeds itself: release `application-<name>`,
ConfigMap `<name>-vars`, roles `<cluster>-<key>` and `<cluster>-secrets-<ns>-<sa>`. The manifests can't tell the two
apart, and `${SECRETS_ROLE_PREFIX}<ns>-<sa>` resolves either way.

The same names make collisions loud. An application lives in the cluster root **or** in its own root, never both: helm
refuses a release or a namespace another release owns, and IAM refuses a duplicate role.

### The cluster input

`cluster` is the cluster root's `application_target` output, verbatim:

| Field                                                           | Used for                                                                                                                                                                   |
| --------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `name`                                                          | The IAM role prefix and the Pod Identity associations                                                                                                                      |
| `namespace`                                                     | Where the seed and the vars live (the flux namespace)                                                                                                                      |
| `platform_registry`                                             | Picks the listing and pull dialect, as in [flux-operator](flux-operator.md)                                                                                                |
| `tree`                                                          | The default image path, `./deploy/<tree>`                                                                                                                                  |
| `issuer`, `keyed`                                               | The default keyless issuer, or KMS mode (null issuer, `cosign-pub` verification)                                                                                           |
| `oidc_provider_arn`, `oidc_issuer`                              | The secret reader roles' IRSA trust                                                                                                                                        |
| `secret_prefix`                                                 | The secret reader roles' `GetSecretValue` scope, `${SECRET_PREFIX}*`                                                                                                       |
| `node_role_arn`, `node_subnet_ids`, `cluster_security_group_id` | How `node_groups` join: the shared Linux node role, the node subnets and the cluster security group. Optional, so an older target still plans; `node_groups` requires them |

The image's validations run against it, so an ECR image outside `platform_registry`, a keyed image on a keyless cluster
and a pull secret on the platform registry all fail at plan.

### Node groups

`node_groups` is capacity the application brings with it: a static pool Karpenter can't express, such as another
architecture only the application's pods tolerate. Each group joins the way the cluster root's own `node_groups` do,
with the shared Linux node role (the root's `EC2_LINUX` access entry already admits it), the node subnets and the
EKS-managed cluster security group. It also gets the Cilium `agent-not-ready` bootstrap taint ahead of the application's
own taints. Add a taint of your own to keep everything else off the group. Groups are Linux only, because Windows nodes
need the root's Windows node role.

### Dex clients

The module has no dex input. An application ships `DexClient` objects in its own image, and the platform's
dex-client-controller registers them. See [Applications](../concepts/applications.md#dex-clients).

--8<-- "modules/application/README.md:tf-docs"
