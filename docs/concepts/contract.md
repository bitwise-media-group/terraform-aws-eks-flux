# The flux contract

Terraform and the platform manifests meet in exactly one place: the **`cluster-vars` ConfigMap** in `flux-system`. Every
platform `Kustomization` substitutes from it through `postBuild.substituteFrom`, and applications can read it too. This
page covers how the bootstrap gets flux running, and what the contract carries.

## The bootstrap chain

The [flux-operator](../modules/flux-operator.md) submodule installs helm releases in a fixed order. Helm releases rather
than `kubernetes_manifest` because they avoid plan-time CRD problems: the CRDs don't exist until the first release
installs them.

| #   | Release             | Contents                                                                                                             | After bootstrap               |
| --- | ------------------- | -------------------------------------------------------------------------------------------------------------------- | ----------------------------- |
| 1   | `flux-operator`     | The operator and its CRDs (`FluxInstance`, `ResourceSet`, …)                                                         | Adopted by the flux component |
| 2   | `cluster-inputs`    | A local chart: `cluster-vars`, each `<key>-vars` ConfigMap, the pre-created namespaces, and `cosign-pub` in KMS mode | **Terraform-reconciled**      |
| 3   | `flux-instance`     | The `FluxInstance`, from which the operator creates the controllers and the sync `OCIRepository`                     | Adopted by the flux component |
| 4   | `application-<key>` | A local chart: one application's seed (see [Applications](applications.md))                                          | Adopted by the application    |

All charts and controller images come from the platform registry: `charts/flux-operator`, `charts/flux-instance` and the
mirrored fluxcd images. flux-containers must have populated the store before the first bootstrap.

Releases 1, 3 and 4 are **bootstrap-only** (`ignore_changes`). The platform's flux component adopts the operator and
instance by release name and follows the newest mirrored charts. So a flux-containers publish upgrades flux on a running
cluster, never a `terraform apply`. `cluster-inputs` stays Terraform-reconciled, so changes to the cluster vars flow
through applies.

The platform controllers run on the system node group. The operator is pinned there through chart values, and the flux
controllers through a kustomize patch on the generated `flux-system` Deployments. Add your own patches with
`flux.kustomize_patches`.

## What the FluxInstance syncs

The instance has a single sync: the platform entrypoint image.

| Input            | Default                                        | Published as        |
| ---------------- | ---------------------------------------------- | ------------------- |
| `flux.sync.url`  | `oci://<platform_registry>/manifests/platform` | `FLUX_SYNC_URL`     |
| `flux.sync.ref`  | `stable` (or `staging`, `edge`, `vX.Y.Z`)      | `FLUX_SYNC_CHANNEL` |
| `flux.sync.path` | `aws`                                          | `PLATFORM_TREE`     |

The entrypoint pins every component to the same channel unless a `<NAME>_MANIFESTS_REF` cluster var overrides one. The
manifests are per-cloud trees, and `flux.sync.path` selects the `aws` tree (flux-manifests 4.0.0 or later).

!!! tip "Re-pointing a running cluster"

    The platform's flux component re-renders the `FluxInstance` from the cluster vars, including `FLUX_SYNC_URL`.
    Changing `flux.sync.url` and applying moves the sync. You don't need a `kubectl patch`.

## Component election

`PLATFORM_COMPONENTS` is the electable tier, and the entrypoint's `ResourceSet` ranges over it. It's
`platform_components` plus `dex` when `sso.enabled`, sorted and comma-joined.

| Tier      | Components                                                                                                                                          | Controlled by         |
| --------- | --------------------------------------------------------------------------------------------------------------------------------------------------- | --------------------- |
| Core      | flux, cilium, kyverno, kyverno-policies, cert-manager, cert-manager-issuers, external-dns, gateway, aws-load-balancer-controller, rbac, secret-sync | always on             |
| Electable | `flux-web` (the default), `arc`                                                                                                                     | `platform_components` |
| Electable | `dex`                                                                                                                                               | `sso.enabled`         |

To elect nothing, set `platform_components = []`. The module then publishes the reserved name `none`, because an empty
string would trigger the manifests' elect-everything default.

## The cluster vars

Keys are cloud-neutral wherever the meaning is shared. Facts that only exist on AWS get an `AWS_` prefix or an
AWS-specific name, and nothing in the manifests branches on a cloud var. Optional surfaces publish an empty string when
they're off, so substitution never fails and the manifests can check for empties.

### Cloud-neutral

| Key(s)                                                                                                    | Value                                                                      |
| --------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------- |
| `CLUSTER_NAME`                                                                                            | `name`                                                                     |
| `PLATFORM_REGISTRY`, `CONTAINER_REGISTRY`                                                                 | Where charts, manifests and mirrored images are pulled from                |
| `SIGNED_IDENTITY_ISSUER`, `SIGNED_IDENTITY_CHARTS`, `SIGNED_IDENTITY_IMAGES`, `SIGNED_IDENTITY_MANIFESTS` | The keyless cosign identities (empty in KMS mode)                          |
| `FLUX_SYNC_URL`, `FLUX_SYNC_CHANNEL`, `PLATFORM_TREE`                                                     | The sync, as above                                                         |
| `PLATFORM_COMPONENTS`                                                                                     | The election, as above                                                     |
| `PLATFORM_DOMAIN`, `DNS_ZONE_NAME`, `DNS_DOMAIN`, `ACME_EMAIL`                                            | The served host (`dns.host` or the zone apex) and DNS/TLS wiring           |
| `GATEWAY_IP`                                                                                              | The Gateway's reserved addresses (informational)                           |
| `SECRET_PREFIX`                                                                                           | The Secrets Manager name prefix                                            |
| `DEX_CONNECTORS`, `DEX_CLIENTS`                                                                           | JSON: the normalised connector, and every relying party (`[]` without SSO) |
| `RBAC_GROUP_VIEWERS`, `…_DEVELOPERS`, `…_DEVOPS`, `…_ADMINS`                                              | The Kubernetes group names bound per role                                  |

### AWS-specific

| Key(s)                                                                                        | Value                                                                                                   |
| --------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------- |
| `AWS_ACCOUNT_ID`, `AWS_REGION`, `AWS_PARTITION`                                               |                                                                                                         |
| `VPC_ID`, `NODE_SECURITY_GROUP_ID`                                                            | For the load-balancer controller and Karpenter                                                          |
| `CLUSTER_DISCOVERY_TAG`, `CLUSTER_DISCOVERY_VALUE`                                            | `karpenter.sh/discovery` and its value                                                                  |
| `OCI_PROVIDER`, `ARTIFACT_TAG_PROVIDER`                                                       | `aws` / `ECRArtifactTag`: how images in the platform registry are authenticated and listed              |
| `SIGNED_IDENTITY_KMS_KEY`, `COSIGN_PUBLIC_KEY`                                                | KMS mode: the key ARN, and its public half as base64 PEM (empty in keyless mode)                        |
| `DNS_PUBLIC_ZONE_ID`, `DNS_PRIVATE_ZONE_ID`                                                   | One external-dns instance per zone; cert-manager's DNS-01 solver uses the public one                    |
| `GATEWAY_NLB_SCHEME`, `GATEWAY_EIP_ALLOCATIONS`, `GATEWAY_SUBNETS`, `GATEWAY_NLB_TARGET_TYPE` | The Gateway's NLB shape (see [Networking](networking.md#the-gateway))                                   |
| `GATEWAY_API_CRDS`                                                                            | `"true"`/`"false"` from `gateway.install_crds`                                                          |
| `CILIUM_K8S_SERVICE_HOST`, `CILIUM_POD_SUBNET_IDS`                                            | The two cluster-specific Cilium values the adopting component must keep                                 |
| `OTEL_REGION`, `OTEL_AMP_ENDPOINT`                                                            | Telemetry: CloudWatch/X-Ray always, AMP when configured                                                 |
| `SECRETS_ROLE_PREFIX`                                                                         | The IRSA reader roles' ARN prefix (see [Identity & secrets](identity.md#irsa-for-podless-secret-syncs)) |

### Karpenter

| Group     | Keys                                                                                                                                              |
| --------- | ------------------------------------------------------------------------------------------------------------------------------------------------- |
| Wiring    | `KARPENTER_NODE_ROLE`, `KARPENTER_INTERRUPTION_QUEUE`, `KARPENTER_SERVICE_ACCOUNT`, `KARPENTER_NODE_POOL_NAME`                                    |
| Selection | `KARPENTER_INSTANCE_CATEGORIES`, `KARPENTER_INSTANCE_FAMILIES`, `KARPENTER_INSTANCE_SIZES`, `KARPENTER_CAPACITY_TYPES`, `KARPENTER_ARCHITECTURES` |
| Ceilings  | `KARPENTER_MAX_NODES`, `KARPENTER_CPU_LIMIT`, `KARPENTER_MEMORY_LIMIT`, `KARPENTER_NODE_DISK_GIB`                                                 |
| Lifecycle | `KARPENTER_AMI_ALIAS`, `KARPENTER_CONSOLIDATION_POLICY`, `KARPENTER_CONSOLIDATE_AFTER`, `KARPENTER_EXPIRE_AFTER`                                  |

Selection lists are comma-joined. See [Capacity](capacity.md#the-nodepool-shape).

### Adding your own

`flux.cluster_vars` adds extra keys: a `<NAME>_MANIFESTS_REF` pin, `ARC_SEMVER`, or a component's chart range such as
`CERT_MANAGER_SEMVER`. **Reserved keys always win** over extras with the same name.

The `flux` output exports the full published map, so you can inspect what a cluster sends to the manifests.

Nothing application-specific belongs in `cluster-vars`. An application's own values go in its `<key>-vars` ConfigMap,
through `application_vars`.
