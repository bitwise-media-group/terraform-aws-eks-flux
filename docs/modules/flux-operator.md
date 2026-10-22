# flux-operator

!!! info "Internal submodule"

    The root module calls this one from `flux.tf`. You don't call it directly. Configure it through the cluster
    module's `flux`, `applications`, `application_vars` and `signed_identity` inputs.

The flux bootstrap chain. Three helm releases, plus one per application, take an empty cluster to a reconciling GitOps
platform in a single apply. Using helm releases rather than `kubernetes_manifest` avoids plan-time CRD problems.

## What it creates

| Release / resource            | Contents                                                                                                                    | Lifecycle            |
| ----------------------------- | --------------------------------------------------------------------------------------------------------------------------- | -------------------- |
| `helm_release.flux_operator`  | The operator and its CRDs                                                                                                   | Bootstrap-only       |
| `helm_release.cluster_inputs` | Local chart `charts/cluster-inputs`: `cluster-vars`, each `<key>-vars`, the pre-created namespaces, `cosign-pub` (KMS mode) | Terraform-reconciled |
| `helm_release.flux_instance`  | The `FluxInstance`, syncing the platform entrypoint image                                                                   | Bootstrap-only       |
| `helm_release.application`    | Local chart `charts/application`, one per key: the `ResourceSetInputProvider` + `ResourceSet` named `<key>-manifests`       | Bootstrap-only       |
| Pod Identity roles            | Registry read for `source-controller` and `flux-operator`                                                                   | Terraform-reconciled |

The two local charts ship inside the module under `charts/`.

## How it works

### Hand-over

The operator, instance and application releases are **bootstrap-only** (`ignore_changes`):

- The platform's flux component adopts `flux-operator` and `flux-instance` by release name, and follows the newest
  mirrored charts from then on. A flux-containers publish, not a `terraform apply`, upgrades flux on a running cluster.
- Each application image ships its own copy of its seed objects and owns them from its first reconcile. See
  [Applications](../concepts/applications.md#the-hand-over).

`cluster-inputs` stays Terraform-reconciled, so changes to `cluster-vars` and `<key>-vars` go through applies.

### Verification

`FluxInstance.spec.sync` has no verify field. Signature checking on the platform entrypoint is therefore added as a
kustomize patch on the generated `flux-system` `OCIRepository`: keyless (issuer and subject) or keyed against the
`cosign-pub` Secret. Each application seed verifies its own image in the `OCIRepository` its `ResourceSet` emits.

### How images are listed and pulled

The **registry** decides, never the cloud:

| Image location               | Tag listing                       | Pull                                                 |
| ---------------------------- | --------------------------------- | ---------------------------------------------------- |
| under the platform prefix    | `ECRArtifactTag`, via the ECR API | `provider: aws`, with the controllers' Pod Identity  |
| anywhere else (ghcr.io, GAR) | `OCIArtifactTag`                  | `provider: generic`, optionally with a `pull_secret` |

### Registry permissions

`source-controller` pulls the sync artifact and every chart `OCIRepository`. `flux-operator` lists chart tags for
`ECRArtifactTag` input providers. Both get Pod Identity roles scoped to the platform registry prefix, never the whole
registry. When the registry is a pull-through cache, they also get `ecr:CreateRepository` and
`ecr:BatchImportUpstreamImage`, because a cache creates each repository on its first pull.

### Placement

Platform controllers run on the always-on system node group, never on Karpenter capacity. The operator is pinned through
chart values, and the flux controllers through a kustomize patch on the generated `flux-system` Deployments.

--8<-- "modules/flux-operator/README.md:tf-docs"
