# Applications

An application is a signed OCI image of manifests that its own repo publishes to `oci://<registry>/manifests/<app>`. The
publishing repo needs an entry in the artifact store's `github.manifest_publishers`, scoped to that path. The cluster
module **seeds** the application once. After that the image owns itself.

## The seed

For `applications["<key>"]`, Terraform creates these objects in `flux-system` once, through the `application-<key>` helm
release:

| Object                     | Name              | What it does                                                                                                                                    |
| -------------------------- | ----------------- | ----------------------------------------------------------------------------------------------------------------------------------------------- |
| `ResourceSetInputProvider` | `<key>-manifests` | Lists the image's tags (`ECRArtifactTag` under the platform registry, `OCIArtifactTag` elsewhere) and resolves the newest tag matching `semver` |
| `ResourceSet`              | `<key>-manifests` | Waits for `FluxInstance/flux`, then emits the two objects below from the resolved `{tag, digest}`                                               |
| `OCIRepository` (emitted)  | `<key>-manifests` | Pulls and verifies the image: `provider: aws` or `generic`, optional `secretRef`, cosign keyless or keyed                                       |
| `Kustomization` (emitted)  | `<key>`           | Applies `path` (default `./deploy/<PLATFORM_TREE>`) with `dependsOn` and `substituteFrom` `cluster-vars` + `<key>-vars`                         |

```mermaid
sequenceDiagram
    participant TF as terraform
    participant Seed as seed (RSIP + ResourceSet)
    participant K as Kustomization &lt;key&gt;
    participant Img as manifests/&lt;app&gt; image
    TF->>Seed: helm release application-&lt;key&gt; (once)
    Seed->>Img: resolve newest tag in semver, verify signature
    Seed->>K: emit OCIRepository + Kustomization
    K->>Img: apply deploy/&lt;tree&gt; (includes ../../flux)
    K->>Seed: server-side apply the same RSIP + ResourceSet
    Note over Seed,K: the image now owns its own seed,<br/>terraform ignores it from here on
```

### The hand-over

The image's `flux/` directory ships the **same** `ResourceSetInputProvider` and `ResourceSet` under the same names. They
read `${ARTIFACT_TAG_PROVIDER}`, `${PLATFORM_REGISTRY}`, `${OCI_PROVIDER}` and `${SIGNED_IDENTITY_*}` from
`cluster-vars`, and the image's own semver range and signing subject from `<key>-vars`. The image's
`deploy/<tree>/kustomization.yaml` includes `../../flux`.

On its first reconcile, `Kustomization <key>` server-side applies both objects and takes ownership of them. The seed
release has `ignore_changes = all`, so Terraform never fights back. From then on the image can change anything about
itself: its semver range, its `dependsOn`, its path, its verification. **Releasing an application never needs a
`terraform apply`.**

Both objects carry `kustomize.toolkit.fluxcd.io/prune: disabled`, in the seed and in the image. If a release drops
`flux/` by mistake, the application's Kustomization can't prune its own parent and delete itself.

### Removing and resetting

- **To remove an application**, delete its key. The seed release uninstalls. The `ResourceSet` finalizer
  garbage-collects the `Kustomization`, whose finalizer prunes the application.
- **To re-point or reset a seed**, remove the key, apply, then add it back. Changing an existing entry does nothing,
  because the image owns it.

!!! danger "A semver range that matches no tag prunes the application"

    If no tag matches, the input set is empty, which empties the `ResourceSet`. That garbage-collects the
    `Kustomization`, which prunes everything it applied. Keep ranges bounded, for example `<1.0.0 >=0.1.0`.

## Composition

Everything an application needs outside the cluster comes from **a module in the application's own repo**. The root
wires that module's outputs into the cluster module's generic inputs:

```hcl
module "patchy" {
  source = "git::https://github.com/bitwise-media-group/patchy-app-manifests.git//modules/aws?ref=v0.1.0"

  name              = var.name
  platform_registry = var.platform_registry.url # the store replica in this region
  secret_prefix     = var.secret_prefix
  domain            = var.dns.host
  harnesses         = ["claude"]
  claude            = { provider = "anthropic" }
  sso_enabled       = var.sso.enabled
}

module "cluster" {
  source = "github.com/bitwise-media-group/terraform-aws-eks-flux"

  platform_components = ["flux-web", "arc"]
  workload_grants     = module.patchy.workload_grants                     # IAM roles + Pod Identity
  workload_identity   = { secret_readers = module.patchy.secret_readers } # podless IRSA readers
  flux                = { namespaces = module.patchy.namespaces, sync = { ref = "staging" } }
  applications        = { patchy = module.patchy.application }            # url, semver, verify, …
  application_vars    = { patchy = module.patchy.vars }                   # the patchy-vars ConfigMap
  # ...
}
```

| Cluster input                      | What the application module emits                                                                                                  |
| ---------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------- |
| `workload_grants`                  | `{ <key> = { namespace, service_account, policy } }`: one role `<cluster>-<key>` and Pod Identity association each                 |
| `workload_identity.secret_readers` | `[{ namespace, service_account }]`: the service accounts its SecretSyncs run as, each getting a role `<cluster>-secrets-<ns>-<sa>` |
| `flux.namespaces`                  | Namespaces created up front, so out-of-band secrets can land before the application deploys                                        |
| `applications[<key>]`              | `url`, `semver`, `path`, `depends_on`, `verify`, `pull_secret`, plus `interval`, `prune`, `wait`, `timeout`                        |
| `application_vars[<key>]`          | A `SCREAMING_SNAKE_CASE` map, rendered as the Terraform-reconciled `<key>-vars` ConfigMap                                          |

!!! warning "Application modules must not consume cluster outputs"

    The root wires application outputs **into** the cluster module, so an application module taking a cluster output
    would create a cycle. Derive cluster-minted names from the static naming rules (`secret_prefix`,
    `secrets_role_prefix`). If something truly needs a cluster-minted value, publish the application from
    [its own root](#from-another-root) instead, which reads the cluster's outputs across the state boundary.

`application_vars` is keyed separately from `applications`, so a composite image's inner applications can each have
their own ConfigMap.

## From another root

[`modules/application`](../modules/application.md) publishes one application to an existing cluster from a root of its
own: another state, another repository, another team. The cluster root doesn't change. It exports everything the module
needs as the `application_target` output, and the application root passes that through (with `terraform_remote_state` or
any other channel), beside a `helm` provider for the cluster and an `aws` provider in its account and region:

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

| Cluster root input                 | `modules/application` equivalent                                                                     |
| ---------------------------------- | ---------------------------------------------------------------------------------------------------- |
| `applications[<key>]`              | `name` + `image`: the same seed, release `application-<name>`, from the same chart                   |
| `application_vars[<key>]`          | `vars`: the `<name>-vars` ConfigMap, in the terraform-reconciled `application-<name>-inputs` release |
| `flux.namespaces`                  | `namespaces`, in the same inputs release                                                             |
| `workload_grants`                  | `workload_grants`: role `<cluster>-<key>` and a Pod Identity association each                        |
| `workload_identity.secret_readers` | `secret_readers`: role `<cluster>-secrets-<ns>-<sa>`, trusted through the cluster's IRSA provider    |

The names are identical on purpose, so the manifests can't tell the two apart. It also means an application lives in the
cluster root **or** in its own root, never both: a collision fails loudly, because helm refuses a release or a namespace
another release owns and IAM refuses a duplicate role. [`examples/application`](../getting-started/examples.md) is a
complete application root.

## Registry and verification

- **An ECR url must live under `platform_registry.url`.** The flux controllers have pull rights on that prefix only.
  They list its tags through the ECR API with the same Pod Identity.
- **Any other registry** (ghcr.io, a GAR mirror) is listed and pulled generically. If it needs credentials,
  `pull_secret` names a `kubernetes.io/dockerconfigjson` Secret in `flux-system`. The registry decides how an image is
  pulled, not the cloud: a ghcr-hosted image on an AWS cluster is still a generic pull.
- **Keyless verification** pins the application repo's publish workflow. The artifact store exports it as
  `manifest_publishers[<repo>].subjects.release`. The issuer defaults to the platform's.
- **Keyed verification** (`verify.keyed = true`) uses the same `cosign-pub` Secret as the platform, and needs KMS mode.

## Dex clients

An application registers its OIDC clients itself, by shipping `DexClient` objects in its own image. The platform's dex
component runs dex-client-controller, which registers each client with dex and writes its credentials to a Secret beside
it (`<name>-dex-client`, keys `clientID`, `clientSecret` and `issuer`). No Secrets Manager secret, reader role or
cluster apply is involved, so this works the same from the cluster root and [from another root](#from-another-root).

- The client id is `<namespace>-<name>`. An explicit `spec.clientID` must start with `<namespace>-`; a platform kyverno
  policy rejects anything else, so no application can claim another's client.
- A **public** client (`public: true`, PKCE) gets no secret.
- The platform's own clients (`flux-web`, kubectl) stay static in `DEX_CLIENTS`, and the controller can't take them
  over.

The full recipe is in the platform docs'
[Applications](https://oss.bitwisemedia.uk/flux-manifests/applications/#an-identity).

## What the image has to do itself

The cluster module provides the wiring. The application image is responsible for:

- labelling the namespace that hosts its HTTPRoutes `platform.bitwisemedia.uk/gateway-access: "true"`, and attaching
  routes by hostname under `*.${PLATFORM_DOMAIN}`
- shipping a Kyverno `PolicyException` (in the `kyverno` namespace) for its namespaces, plus its own `ClusterPolicy`
  that verifies its images
- binding its RBAC as `RoleBindings` on `${RBAC_GROUP_*}`
- syncing its secrets with a `SecretProviderClass` + `SecretSync`, whose service account is annotated
  `eks.amazonaws.com/role-arn: ${SECRETS_ROLE_PREFIX}<ns>-<sa>`
- for GitHub Actions runners, deploying a `gha-runner-scale-set` `HelmRelease` against the elected `arc` component with
  `controllerServiceAccount { arc-systems, arc-gha-rs-controller }` and `dependsOn: [arc, secret-sync]`

The exact recipes are in the [flux-manifests] README.

[flux-manifests]: https://github.com/bitwise-media-group/flux-manifests
