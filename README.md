# terraform-aws-eks-flux

A generic EKS cluster that bootstraps [flux-operator] and syncs a cosign-signed **platform** from ECR, running
**Cilium in ENI mode** as the CNI and **Karpenter** for workload capacity. The module creates the cluster, deploys
Cilium, the Flux Operator and one `FluxInstance`, elects which platform components that instance deploys, and seeds
the **applications** the cluster runs - each an independently published manifest image that owns itself after its
first reconcile. Nothing application-specific lives here.

Four kinds of repo make a deployment:

| repo                              | role                                                                                   |
| --------------------------------- | -------------------------------------------------------------------------------------- |
| **terraform-aws-eks-flux** (this) | the cluster, the artifact store and the flux bootstrap                                 |
| [flux-containers]                 | vendors, scans, mirrors and keyless-signs charts + images into the artifact store      |
| [flux-manifests] (the platform)   | the platform entrypoint and one image per component every cluster syncs               |
| an application repo (e.g. [patchy-app-manifests]) | the application's manifest image plus its out-of-cluster terraform (secrets, IAM) |

## Design

- **Cilium in ENI mode, no AWS VPC CNI.** `bootstrap_self_managed_addons = false` means EKS never installs `vpc-cni` or
  `kube-proxy`; Cilium is both the CNI and the kube-proxy replacement, and pods hold routable VPC addresses exactly as
  they would under `vpc-cni`. This is also what makes raw `CiliumNetworkPolicy` / `FQDNNetworkPolicy` usable, which
  managed Cilium distributions typically reject.
- **Karpenter for workload capacity.** Terraform owns the IAM roles, the interruption queue, the discovery tags **and
  the NodePool shape** (`var.karpenter`, published as `KARPENTER_*` cluster vars); the platform's karpenter component
  owns the chart and renders the `EC2NodeClass`/`NodePool` from those vars. A small always-on **system node group**
  (`role=system`) carries the platform controllers.
- **One entrypoint, two tiers.** The `FluxInstance` syncs one small image, `oci://<registry>/manifests/platform`, whose
  `ResourceSet` ranges over `PLATFORM_COMPONENTS` and emits an `OCIRepository` + `Kustomization` per component from
  `oci://<registry>/manifests/<component>`. The **core tier** (flux, cilium, kyverno, kyverno-policies, cert-manager,
  cert-manager-issuers, external-dns, gateway, aws-load-balancer-controller, rbac, secret-sync) always deploys; the
  **electable tier** (`var.platform_components`: `flux-web`, `arc`; `dex` rides `sso.enabled`) is opt-in. Every
  component is its own image, so one can be pinned (`<NAME>_MANIFESTS_REF`), soaked or rolled back on its own.
- **Applications are their own images.** `var.applications` seeds each one: a `ResourceSetInputProvider` + `ResourceSet`
  named `<key>-manifests` in `flux-system` that follow a semver range, verify the image's signature and apply it as
  `Kustomization <key>`. The image ships the same two objects and adopts them on its first reconcile, so an application
  release is never a terraform apply, and removing the key uninstalls the seed and prunes the application. What an
  application needs outside the cluster (Secrets Manager containers, IAM policy documents, dex clients, its own
  substitution vars) is emitted by a module in the application's repo and wired into this module's generic inputs
  (`workload_grants`, `workload_identity.secret_readers`, `applications`, `application_vars`, `flux.namespaces`) by
  the root - see [Applications](#applications).
- **Terraform deploys no Helm chart that flux does not go on to manage.** Everything AWS offers managed is an add-on
  (see `var.addons`); everything else is a platform component or an application. The exceptions are bootstrap-only
  hand-overs, applied once and then ignored: **Cilium**, which must exist before the first node can report `Ready`
  (the platform's `cilium` component adopts the release), `flux-operator`/`flux-instance` (the `flux` component adopts
  them), and each **application seed** (the image adopts it).
- **One ECR prefix, create-on-push.** ECR has no arbitrary-path model, so a **repository creation template** with
  `CREATE_ON_PUSH` restores Artifact Registry's ergonomics: publishers push to `<prefix>/charts/<name>`,
  `<prefix>/images/<path>` or `<prefix>/manifests/<name>` and ECR creates each repository with the template's lifecycle
  policy, tag mutability, encryption and tags. Push is scoped per publisher: the platform repo owns `manifests/*`, an
  application repo owns exactly `manifests/<app>`.
- **Reads are org-wide, not per-account.** The store admits only the ECR pull-through cache service, matched on
  `aws:PrincipalOrgID`, so onboarding a cluster account means applying `modules/registry-cache` there - never editing
  the store. `direct_pull_principals` is the escape hatch for clusters allowed to read it straight.
- **Cosign everywhere - keyless by default, KMS as the alternative.** Keyless: artifacts are signed by GitHub Actions
  OIDC identities (Fulcio/Rekor), the generated `flux-system` OCIRepository verifies the platform entrypoint via
  `matchOIDCIdentity`, every component and application `OCIRepository` and the Kyverno policy verify the same way, and
  no key material is distributed anywhere - because the signer is GitHub, the `signed_identity` values are
  cloud-agnostic. KMS: set `signed_identity.kms_key_arn` (and the store's `signing_kms_key_arn`) instead of the
  subjects; the publishers sign with `awskms:///<arn>`, the bootstrap distributes the key's public half as the
  `flux-system` `cosign-pub` Secret, and the ARN is published as `SIGNED_IDENTITY_KMS_KEY` for Kyverno. One mode or
  the other, never both.
- **EKS Pod Identity for every workload with a pod.** The one exception is the secret-sync reader KSAs: the
  secrets-store-sync-controller materialises SecretSyncs podlessly, and a token with no pod behind it fails Pod
  Identity's `AssumeRoleForPodIdentity`, so those roles trust the cluster's IRSA OIDC provider instead and the
  manifests annotate the sync KSAs via the `SECRETS_ROLE_PREFIX` cluster var. `var.workload_identity` keeps the
  platform's namespace/service-account shape cloud-neutral; `var.workload_grants` carries application grants.
- **DNS/TLS survives cluster recreation.** The delegated Route53 zone lives upstream, and the Gateway's Elastic IPs are
  reserved outside the cluster's lifecycle - destroy/recreate serves the same addresses with no manual action. The
  platform Gateway carries one wildcard `https` listener on `*.<PLATFORM_DOMAIN>` (`Certificate platform-wildcard`),
  and routes - platform and application alike - attach by hostname from any namespace labelled
  `platform.bitwisemedia.uk/gateway-access: "true"`.

### Bootstrap order

This ordering is what makes a single `terraform apply` work against an empty account, and every `depends_on` in the
module exists to hold it:

1. `aws_eks_cluster` with **no self-managed add-ons** - no `vpc-cni`, no `kube-proxy`, no `coredns`.
2. Access entries for the node roles (`EC2_LINUX`) and the RBAC principals.
3. **Cilium** (`helm_release`, `wait = false`) - there are no nodes yet, so the objects simply land in the API server
   and agents start the instant a node registers. Waiting here would deadlock against step 4.
4. The **system node group**, tainted `node.cilium.io/agent-not-ready=true:NoExecute`. Cilium tolerates all taints and
   its operator removes this one once the agent is ready. Because Cilium is already installed, nodes reach `Ready`
   promptly instead of failing with `NodeCreationFailure`.
5. **Add-ons** - `eks-pod-identity-agent` first, then the rest.
6. **Pod Identity associations**, then the **flux bootstrap chain**: `flux-operator`, `cluster-inputs` (the
   `cluster-vars` and `<key>-vars` ConfigMaps, pre-created namespaces), `flux-instance`, then one `application-<key>`
   seed per application.

> **Why Cilium's ENI permissions sit on the node role.** In ENI mode the agent cannot report ready until the operator
> has attached ENIs, so the operator needs credentials during step 4 - while the pod-identity-agent add-on is a step 5
> artefact. Pod Identity there is a genuine cycle. This is also what the AWS VPC CNI does by default. Set
> `cilium.operator_pod_identity` against a running cluster to move it.

## Choosing a registry

`platform_registry` takes a `{ url, is_pull_through_cache }` object, and both registry modules emit exactly that shape -
so wire it from a module output rather than composing it by hand:

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

The flag is not cosmetic: a cache materialises each repository on its **first** pull, so a cluster wired to one without
`ecr:CreateRepository` + `ecr:BatchImportUpstreamImage` fails on its first image. Passing
`module.store.platform_registry` instead reads the store directly (`is_pull_through_cache = false`) and additionally
requires that store to admit the cluster's `registry_reader_principals`.

## Bootstrap sequence

1. **Upstream account setup** (created outside this repo): the account, VPC, private node subnets and public subnets,
   NAT or the ECR/S3/STS/EKS VPC endpoints, the delegated Route53 zone, and the GitHub Actions OIDC provider. Subnets
   need the `kubernetes.io/role/{internal-,}elb` tags; the cluster module adds `karpenter.sh/discovery` itself.
2. **Artifact store** (`examples/artifact-store`) in the platform account, with one entry in
   `github.manifest_publishers` per manifest-publishing repo. Feed its outputs to the publishing repos as the
   `AWS_CHART_PUBLISHER_ROLE` (flux-containers), `AWS_MANIFEST_PUBLISHER_ROLE` (one value per manifest repo, from
   `manifest_publishers`), `AWS_PLATFORM_REGISTRY` and `AWS_REGION` Actions variables.
3. **flux-containers**: publish every chart + image - including `cilium`, `karpenter` and, for `arc`, the runner
   scale-set controller chart and runner image.
4. **flux-manifests**: cut a release; its publish workflow pushes every component image, then the platform entrypoint
   (`manifests/platform`), and moves the `staging` tag on each.
5. **Application images**: each application repo publishes `manifests/<app>` the same way.
6. **Registry cache** (`examples/registry-cache`) in the cluster's account, then the **cluster** (`examples/complete` is
   the shape, applications composed in). One apply bootstraps Cilium, flux-operator, the platform and the seeds.

## The terraform ↔ flux contract

The `cluster-vars` ConfigMap publishes these to the platform; applications may read any of them, but nothing
application-specific is published here (an application's own values ride in its `<key>-vars` ConfigMap). Keys are
deliberately cloud-neutral wherever the meaning is shared; the manifests are per-cloud trees (`flux.sync.path` selects
`aws`, published as `PLATFORM_TREE` so applications select the same tree; flux-manifests >= 4.0.0), so aws-only facts
publish as AWS-prefixed keys and nothing branches on a cloud var. Optional surfaces use the empty-string convention.

Cloud-neutral: `CLUSTER_NAME`, `PLATFORM_REGISTRY`, `CONTAINER_REGISTRY`, `SIGNED_IDENTITY_ISSUER`,
`SIGNED_IDENTITY_CHARTS`, `SIGNED_IDENTITY_IMAGES`, `SIGNED_IDENTITY_MANIFESTS`, `FLUX_SYNC_CHANNEL`, `FLUX_SYNC_URL`,
`PLATFORM_TREE`, `PLATFORM_COMPONENTS`, `PLATFORM_DOMAIN`, `DNS_ZONE_NAME`, `DNS_DOMAIN`, `ACME_EMAIL`, `GATEWAY_IP`,
`SECRET_PREFIX`, `DEX_CONNECTORS`, `DEX_CLIENTS`, `RBAC_GROUP_*`.

| key                   | notes                                                                                                        |
| --------------------- | ------------------------------------------------------------------------------------------------------------ |
| `PLATFORM_COMPONENTS` | `platform_components` plus `dex` when `sso.enabled`, sorted and comma-joined; the reserved `none` when empty. The entrypoint's `ResourceSet` ranges over it |
| `PLATFORM_TREE`       | `flux.sync.path` - the per-cloud tree the platform and every application select                              |
| `PLATFORM_DOMAIN`     | the served host (`dns.host` or the zone apex): the wildcard listener's apex, every route hangs off it        |
| `FLUX_SYNC_URL`       | the entrypoint the `FluxInstance` syncs; the platform's flux component asserts it, which is how a running cluster is re-pointed |
| `FLUX_SYNC_CHANNEL`   | `flux.sync.ref`; the entrypoint pins every component to it unless a `<NAME>_MANIFESTS_REF` caller var overrides one |
| `DEX_CLIENTS`         | JSON: every dex relying party - `flux-web` when elected, the public kubectl client (`sso.kubectl`), and each `applications[*].dex_clients` entry - as `{id, name, public, redirectURIs}`; `[]` when sso is off. Confidential clients get a generated `${SECRET_PREFIX}dex-client-<id>` secret |

AWS-specific:

| key                                                | notes                                                    |
| -------------------------------------------------- | -------------------------------------------------------- |
| `AWS_ACCOUNT_ID`, `AWS_REGION`, `AWS_PARTITION`    |                                                          |
| `VPC_ID`, `NODE_SECURITY_GROUP_ID`                 | for the load-balancer controller and Karpenter           |
| `CLUSTER_DISCOVERY_TAG`, `CLUSTER_DISCOVERY_VALUE` | `karpenter.sh/discovery` and its value                   |
| `DNS_PUBLIC_ZONE_ID`, `DNS_PRIVATE_ZONE_ID`        | per-flavour Route53 hosted zone ids: one external-dns instance per flavour (`--zone-id-filter`), cert-manager's DNS-01 solver pinned to the public id. Public always set with `dns.zone_name`; private set under split-horizon (`dns.private_zone`) |
| `GATEWAY_NLB_SCHEME`                               | `internet-facing`, or `internal` when `gateway.private`  |
| `GATEWAY_EIP_ALLOCATIONS`, `GATEWAY_SUBNETS`       | bound to the Gateway's NLB by annotation (the EIP var is empty for a private Gateway, whose NLB spans the node subnets) |
| `GATEWAY_NLB_TARGET_TYPE`                          | `instance` - see the caveat below                        |
| `GATEWAY_API_CRDS`                                 | `gateway.install_crds`, default `"true"` - see the caveat below |
| `CILIUM_K8S_SERVICE_HOST`, `CILIUM_POD_SUBNET_IDS` | the two `local.cilium_values` (`cilium.tf`) that are cluster-specific rather than fixed chart defaults - the platform's `cilium` component reproduces the rest verbatim and needs these to avoid diffing them away on adoption. The latter is JSON-encoded (a cluster var is a flat string) |
| `OCI_PROVIDER`, `ARTIFACT_TAG_PROVIDER`            | `aws` / `ECRArtifactTag` - registry auth and tag-listing dialects for images in the platform registry (the google tree relies on the manifests' gcp defaults instead) |
| `OTEL_REGION`, `OTEL_AMP_ENDPOINT`                 | CloudWatch/X-Ray always; AMP when configured             |
| `SIGNED_IDENTITY_KMS_KEY`                          | the KMS signing key ARN (empty in keyless mode, when the `SIGNED_IDENTITY_*` subjects are set instead) |
| `SECRETS_ROLE_PREFIX`                              | the IRSA reader roles' ARN prefix: a `workload_identity.secret_readers` pair `<ns>/<sa>` assumes `${SECRETS_ROLE_PREFIX}<ns>-<sa>` |
| `DEX_CONNECTORS`                                   | JSON-encoded dex connector declaration (`sso.connector`, normalized; `[]` when sso is off) |

Karpenter's NodePool shape travels the same way, since `cluster-vars` is a flat string map:

- **wiring** - `KARPENTER_NODE_ROLE`, `KARPENTER_INTERRUPTION_QUEUE`, `KARPENTER_SERVICE_ACCOUNT`
- **selection** - `KARPENTER_INSTANCE_CATEGORIES`, `KARPENTER_INSTANCE_FAMILIES`, `KARPENTER_INSTANCE_SIZES`,
  `KARPENTER_CAPACITY_TYPES`, `KARPENTER_ARCHITECTURES`. These are **comma-joined lists**, expanded manifests-side with
  `splitList` - the same pattern `PLATFORM_COMPONENTS` uses, so no new mechanism is involved.
- **ceilings** (`spec.limits`) - `KARPENTER_MAX_NODES`, `KARPENTER_CPU_LIMIT`, `KARPENTER_MEMORY_LIMIT`,
  `KARPENTER_NODE_DISK_GIB`
- **lifecycle** - `KARPENTER_AMI_ALIAS`, `KARPENTER_CONSOLIDATION_POLICY`, `KARPENTER_CONSOLIDATE_AFTER`,
  `KARPENTER_EXPIRE_AFTER`

Callers may add extras via `flux.cluster_vars` (a `<NAME>_MANIFESTS_REF` pin, `ARC_SEMVER`, a component's chart
range); reserved keys always win. The published contract is exported as `flux.cluster_vars` for inspection.

The SSO connector's out-of-band credentials (`dex-<id>-<field>`) come from [`modules/sso-secrets`](modules/sso-secrets/),
instantiated in a **durable** root with the same `sso` value as the cluster module call - the versions are added with
`aws secretsmanager put-secret-value` and must survive cluster destroy/recreate with no manual re-entry.

## Applications

An application is a signed OCI image of manifests, published by its own repo to `oci://<registry>/manifests/<app>`
(an entry in the artifact store's `github.manifest_publishers` scoped to that path). The cluster module seeds it;
after that the image owns itself.

**The seed contract.** For `applications["<key>"]` terraform creates, once, in `flux-system`:

| object                                    | name              | notes                                                                 |
| ----------------------------------------- | ----------------- | --------------------------------------------------------------------- |
| `ResourceSetInputProvider`                | `<key>-manifests` | `ECRArtifactTag` under the platform registry, `OCIArtifactTag` elsewhere; `filter.semver`, `limit: 1` |
| `ResourceSet`                             | `<key>-manifests` | waits for `FluxInstance/flux`; emits the two objects below from the resolved `{tag, digest}` |
| `OCIRepository` (emitted)                 | `<key>-manifests` | `provider: aws` / `generic`, optional `secretRef` (`pull_secret`), cosign verify keyless or keyed |
| `Kustomization` (emitted)                 | `<key>`           | `path` (default `./deploy/<PLATFORM_TREE>`), `dependsOn`, `substituteFrom` `cluster-vars` + `<key>-vars` (optional) |

The image's `flux/` directory ships the **same** `ResourceSetInputProvider` and `ResourceSet` under the same names
(reading `${ARTIFACT_TAG_PROVIDER}`, `${PLATFORM_REGISTRY}`, `${OCI_PROVIDER}`, `${SIGNED_IDENTITY_*}` from
`cluster-vars` and its own semver/subject from `<key>-vars`), and `deploy/<tree>/kustomization.yaml` includes
`../../flux`. On its first reconcile `Kustomization <key>` server-side applies both objects and takes ownership; the
seed release is `ignore_changes = all`, so terraform never fights back. Both objects carry
`kustomize.toolkit.fluxcd.io/prune: disabled` in the seed **and** in the image: should a release drop `flux/`, the
application's own Kustomization can never prune its parent and cascade itself away.

After hand-over the image may change anything: its semver range, its `dependsOn`, its path, its verification. To
**remove** an application, delete the key: the seed release uninstalls, the `ResourceSet` finalizer garbage-collects
the `Kustomization`, whose finalizer prunes the application. To **re-point** or **reset** a seed, remove and re-add the
key.

**Composition.** Everything the application needs outside the cluster is emitted by a module in the application's
repo and wired by the root; the application module consumes static root inputs only, never cluster outputs (that
would be a cycle):

```hcl
module "patchy" {
  source = "git::https://github.com/bitwise-media-group/patchy-app-manifests.git//modules/aws?ref=v0.1.0"

  name              = var.name
  platform_registry = module.cache.platform_registry.url
  secret_prefix     = var.secret_prefix
  domain            = var.dns.host
  harnesses         = ["claude"]
  claude            = { provider = "anthropic" }
  sso_enabled       = var.sso.enabled
}

module "cluster" {
  source = "github.com/bitwise-media-group/terraform-aws-eks-flux"

  platform_components = ["flux-web", "arc"]
  workload_grants     = module.patchy.workload_grants          # IAM roles + Pod Identity, policy JSON per key
  workload_identity   = { secret_readers = module.patchy.secret_readers }  # podless IRSA readers
  flux                = { namespaces = module.patchy.namespaces, sync = { ref = "staging" } }
  applications        = { patchy = module.patchy.application } # url, semver, verify, depends_on, dex_clients
  application_vars    = { patchy = module.patchy.vars }        # the patchy-vars ConfigMap
  # ...
}
```

| input                              | what the application module emits                                                                  |
| ---------------------------------- | -------------------------------------------------------------------------------------------------- |
| `workload_grants`                  | `{ <key> = { namespace, service_account, policy } }` - one role `<cluster>-<key>` + Pod Identity association each |
| `workload_identity.secret_readers` | `[{ namespace, service_account }]` - the KSAs its SecretSyncs run as, roles `<cluster>-secrets-<ns>-<sa>` |
| `flux.namespaces`                  | namespaces pre-created so out-of-band secrets can land before the application deploys              |
| `applications[<key>]`              | `url`, `semver`, `path`, `depends_on`, `verify` (`subject` or `keyed`), `pull_secret`, `dex_clients` |
| `application_vars[<key>]`          | `SCREAMING_SNAKE_CASE` map, rendered as the `<key>-vars` ConfigMap (terraform-reconciled)          |

**Registry and verification.** An ECR url must live under `platform_registry.url` - the flux controllers hold pull
rights on that prefix alone, and its tags are listed with the same Pod Identity through the ECR API. Any other registry
(ghcr.io, a GAR mirror) is listed and pulled generically; `pull_secret` names a `kubernetes.io/dockerconfigjson` Secret
in `flux-system` when it needs credentials. Keyless verification pins the application repo's publish workflow (the
artifact store exports it as `manifest_publishers[<repo>].subjects.release`; the issuer defaults to the platform's);
keyed verification (`verify.keyed`) reads the same `cosign-pub` Secret the platform uses and needs KMS mode.

**Dex clients.** `applications[<key>].dex_clients` registers OIDC relying parties with the platform's dex (requires
`sso.enabled`). A confidential client mints `${SECRET_PREFIX}dex-client-<id>` (rotated by bumping `version`),
readable by dex and by the `readers` the client names (`<ns>/<sa>` pairs from `workload_identity.secret_readers`), so
the application's secret-sync recipe can place it beside its config; a `public` client (PKCE) mints nothing. Every
client is published in `DEX_CLIENTS`; ids must be unique across applications and must not reuse the platform's
(`flux-web`, `sso.kubectl.client_id`).

**What the image must do itself.** Label the namespace that hosts its HTTPRoutes
`platform.bitwisemedia.uk/gateway-access: "true"` and attach routes by hostname under `*.${PLATFORM_DOMAIN}`; ship a
kyverno `PolicyException` (in the `kyverno` namespace) for its namespaces plus its own `ClusterPolicy` verifying its
images; bind its RBAC as `RoleBindings` on `${RBAC_GROUP_*}`; sync its secrets with a `SecretProviderClass` +
`SecretSync` whose KSA is annotated `eks.amazonaws.com/role-arn: ${SECRETS_ROLE_PREFIX}<ns>-<sa>`; and, for GitHub
Actions runners, deploy a `gha-runner-scale-set` `HelmRelease` with `controllerServiceAccount { arc-systems,
arc-gha-rs-controller }` against the elected `arc` component (`dependsOn: [arc, secret-sync]`). The exact recipes
live in the platform README.

## Caveats

- **Application seeds are bootstrap-only.** After the first apply the image owns `<key>-manifests`; changing an
  `applications` entry in terraform does nothing until the key is removed and re-added. Never lift `ignore_changes`.
- **A semver range matching no tag prunes the application.** An empty input set empties the `ResourceSet`, which
  garbage-collects the `Kustomization`, which prunes what it applied. Keep ranges bounded (`<1.0.0 >=0.1.0`).
- **Application modules must not consume cluster outputs.** The root wires application outputs into the cluster
  module; anything that needs a cluster-minted value (a config document embedding `dex-client-<id>`) is derived from
  the static naming rule (`secret_prefix`, `secrets_role_prefix`) or becomes a second-stage module in the application
  repo.
- **Karpenter is not an EKS add-on.** It appears in neither the AWS nor the community catalogue. The only AWS-managed
  Karpenter is **EKS Auto Mode**, which owns networking with the AWS VPC CNI on AWS-managed AMIs and therefore cannot
  run Cilium in ENI mode.
- **The AWS Load Balancer Controller is not an ingress path here.** Cilium is the Gateway API implementation and owns
  all L7 routing; the controller exists solely to turn the one `Service type=LoadBalancer` that Cilium's Gateway
  materialises into an NLB bound to the reserved EIPs. EKS's built-in legacy controller could do that too, but AWS
  ships it critical fixes only and advises against new NLBs on it.
- **NLB target type is `instance`, not `ip`.** The controller can only register IP targets when the AWS VPC CNI is the
  datapath; under any alternate CNI it is limited to instance targets, whatever the pods' addresses look like.
- **The Gateway API CRDs are installed by the manifests, not by EKS.** EKS ships no `gateway.networking.k8s.io` CRDs
  and Cilium implements the API without owning them, so `GATEWAY_API_CRDS` (from `gateway.install_crds`, default on)
  has the platform's gateway component install the standard-channel set Cilium requires. Cilium only enables its
  Gateway API controller when the CRDs are present at agent/operator startup - on a fresh bootstrap they land after
  terraform's cilium release, and the first Cilium rollout (upgrade or restart) after they establish activates the
  implementation. If AWS ever installs the CRDs as managed cluster furniture, flip `gateway.install_crds` off: the
  manifests orphan them (never prune - deleting a CRD deletes every Gateway and HTTPRoute with it) and EKS takes over.
- **Karpenter has no minimum-node concept.** It scales from zero on pending pods and offers only ceilings
  (`spec.limits`). The cluster's floor is `system_node_group.min_size`.
- **Managed node group counts are cluster-wide totals**, not per-availability-zone.
- **The helm provider must use an exec plugin, not `data.aws_eks_cluster_auth`.** That data source mints a presigned
  STS token valid for roughly 15 minutes and resolves it once, while a first apply spans cluster creation, the node
  group, the add-ons and only then the flux chain - comfortably longer, so the token expires mid-apply. The examples
  use `aws eks get-token`, which runs when credentials are actually needed. **This makes the AWS CLI a prerequisite on
  whatever runs terraform**, and the `--region` argument is passed explicitly so the CLI does not have to infer it from
  an environment that may not match the provider's. ECR authorization tokens are valid for 12 hours, so those stay
  ordinary data sources.
- **EKS has no `deletion_protection`.** Guard production clusters with policy or a state-level `prevent_destroy`.
- **`cert-manager` and `external-dns` stay flux-managed** despite being available as community add-ons: those are
  community tier (AWS supports only lifecycle operations), and taking them as add-ons would pull images from AWS's
  registry, breaking the "clusters never pull from a public registry" invariant and the Kyverno policy enforcing it.
- **Pull-through cache coverage is unvalidated for helm charts and cosign signatures.** ECR→ECR pull-through is a
  manifest/blob copy, so OCI chart artifacts and `sha256-<digest>.sig` tags should pass through intact - but the whole
  verification chain depends on it, so confirm both on first apply.
- **`aws_ecr_registry_policy` is a per-account, per-region singleton.** `modules/artifact-store` owns it; an account
  using registry policies for anything else must merge those statements via `additional_registry_statements`.

## Migrating from 3.x

4.0 is a breaking release: `var.patchy`, `var.stack_components`, `workload_identity.patchy_egress_broker`, the
`patchy-status` client and every `PATCHY_*` / `CLAUDE_*` / `AGENT_*` / `KUBECTL_OIDC_*` cluster var leave the module;
`modules/secrets` becomes `modules/sso-secrets` (dex connector containers only); the artifact store's single
`github.manifests_id` becomes `github.manifest_publishers`. patchy moves to [patchy-app-manifests], whose
`modules/aws` emits exactly the maps the new generic inputs take, so a root migrates by composing that module
(`examples/complete`) - the IAM role names, secret names and namespaces are unchanged, so nothing churns. The ordered
cut-over of a running cluster (a transitional 3.x manifests release, freezing the old optional tier, applying 4.0,
re-pointing the sync through `FLUX_SYNC_URL`, removing the old tier) is documented in the platform README's
"Migrating from 3.x"; rollback through the re-point step is `kubectl patch fluxinstance` back to the old url.

## Development

`make help` lists tasks (`fmt`, `lint`, `validate`, `test`, `docs`, `pr`). The toolchain submodule (`.mise/`) pins every
tool; `git submodule update --init` and `mise trust --all` once per clone.

Everything in `make lint` / `make test` runs against mocked providers, so no credentials are needed to develop here.
Applying a cluster additionally needs the **AWS CLI** on the machine running terraform - the helm provider's exec plugin
shells out to `aws eks get-token` (see the caveat above).

[flux-operator]: https://github.com/controlplaneio-fluxcd/flux-operator
[patchy-app-manifests]: https://github.com/bitwise-media-group/patchy-app-manifests
[flux-containers]: https://github.com/bitwise-media-group/flux-containers
[flux-manifests]: https://github.com/bitwise-media-group/flux-manifests

<!-- BEGIN_TF_DOCS -->
## Requirements

| Name | Version |
| ---- | ------- |
| terraform | >= 1.11, != 1.16.0, < 2.0 |
| aws | >= 6.0, < 7.0 |
| helm | ~> 3.0 |
| random | >= 3.7, < 4.0 |
| tls | >= 4.0, < 5.0 |

## Providers

| Name | Version |
| ---- | ------- |
| aws | >= 6.0, < 7.0 |
| helm | ~> 3.0 |
| terraform | n/a |
| tls | >= 4.0, < 5.0 |

## Modules

| Name | Source | Version |
| ---- | ------ | ------- |
| flux\_operator | ./modules/flux-operator | n/a |
| node\_group | ./modules/node-group | n/a |
| system\_node\_group | ./modules/node-group | n/a |

## Resources

| Name | Type |
| ---- | ---- |
| [aws_cloudwatch_event_rule.karpenter](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudwatch_event_rule) | resource |
| [aws_cloudwatch_event_target.karpenter](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudwatch_event_target) | resource |
| [aws_ec2_tag.cluster_security_group_discovery](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/ec2_tag) | resource |
| [aws_ec2_tag.discovery](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/ec2_tag) | resource |
| [aws_eip.gateway](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/eip) | resource |
| [aws_eks_access_entry.cluster_admins](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/eks_access_entry) | resource |
| [aws_eks_access_entry.karpenter_node](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/eks_access_entry) | resource |
| [aws_eks_access_entry.nodes](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/eks_access_entry) | resource |
| [aws_eks_access_entry.nodes_windows](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/eks_access_entry) | resource |
| [aws_eks_access_entry.rbac](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/eks_access_entry) | resource |
| [aws_eks_access_policy_association.cluster_admins](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/eks_access_policy_association) | resource |
| [aws_eks_addon.main](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/eks_addon) | resource |
| [aws_eks_addon.pod_identity_agent](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/eks_addon) | resource |
| [aws_eks_cluster.main](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/eks_cluster) | resource |
| [aws_eks_identity_provider_config.dex](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/eks_identity_provider_config) | resource |
| [aws_eks_pod_identity_association.cilium_operator](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/eks_pod_identity_association) | resource |
| [aws_eks_pod_identity_association.ebs_csi](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/eks_pod_identity_association) | resource |
| [aws_eks_pod_identity_association.karpenter_controller](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/eks_pod_identity_association) | resource |
| [aws_eks_pod_identity_association.workload](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/eks_pod_identity_association) | resource |
| [aws_iam_instance_profile.nodes](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_instance_profile) | resource |
| [aws_iam_openid_connect_provider.irsa](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_openid_connect_provider) | resource |
| [aws_iam_role.cilium_operator](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role) | resource |
| [aws_iam_role.cluster](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role) | resource |
| [aws_iam_role.ebs_csi](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role) | resource |
| [aws_iam_role.karpenter_controller](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role) | resource |
| [aws_iam_role.karpenter_node](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role) | resource |
| [aws_iam_role.nodes](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role) | resource |
| [aws_iam_role.nodes_windows](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role) | resource |
| [aws_iam_role.workload](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role) | resource |
| [aws_iam_role_policy.cilium_eni](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy) | resource |
| [aws_iam_role_policy.cilium_operator](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy) | resource |
| [aws_iam_role_policy.karpenter_controller](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy) | resource |
| [aws_iam_role_policy.karpenter_node_cilium_eni](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy) | resource |
| [aws_iam_role_policy.workload](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy) | resource |
| [aws_iam_role_policy_attachment.cluster](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy_attachment) | resource |
| [aws_iam_role_policy_attachment.ebs_csi](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy_attachment) | resource |
| [aws_iam_role_policy_attachment.karpenter_node](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy_attachment) | resource |
| [aws_iam_role_policy_attachment.nodes](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy_attachment) | resource |
| [aws_iam_role_policy_attachment.nodes_windows](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy_attachment) | resource |
| [aws_secretsmanager_secret.dex_client](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/secretsmanager_secret) | resource |
| [aws_secretsmanager_secret.flux_web_auth_config](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/secretsmanager_secret) | resource |
| [aws_secretsmanager_secret_policy.readers](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/secretsmanager_secret_policy) | resource |
| [aws_secretsmanager_secret_version.dex_client](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/secretsmanager_secret_version) | resource |
| [aws_secretsmanager_secret_version.flux_web_auth_config](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/secretsmanager_secret_version) | resource |
| [aws_sqs_queue.karpenter_interruption](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/sqs_queue) | resource |
| [aws_sqs_queue_policy.karpenter_interruption](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/sqs_queue_policy) | resource |
| [aws_vpc_security_group_egress_rule.default_self](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/vpc_security_group_egress_rule) | resource |
| [helm_release.cilium](https://registry.terraform.io/providers/hashicorp/helm/latest/docs/resources/release) | resource |
| [terraform_data.revoke_default_egress](https://registry.terraform.io/providers/hashicorp/terraform/latest/docs/resources/data) | resource |
| [aws_caller_identity.current](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/caller_identity) | data source |
| [aws_eip.gateway](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/eip) | data source |
| [aws_iam_policy_document.cilium_eni](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy_document) | data source |
| [aws_iam_policy_document.cluster_assume_role](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy_document) | data source |
| [aws_iam_policy_document.irsa_assume_role](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy_document) | data source |
| [aws_iam_policy_document.karpenter_controller](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy_document) | data source |
| [aws_iam_policy_document.karpenter_interruption](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy_document) | data source |
| [aws_iam_policy_document.kyverno](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy_document) | data source |
| [aws_iam_policy_document.load_balancer_controller](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy_document) | data source |
| [aws_iam_policy_document.node_assume_role](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy_document) | data source |
| [aws_iam_policy_document.otel_collector](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy_document) | data source |
| [aws_iam_policy_document.pod_identity_assume_role](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy_document) | data source |
| [aws_iam_policy_document.registry_read](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy_document) | data source |
| [aws_iam_policy_document.route53](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy_document) | data source |
| [aws_iam_policy_document.secret_read](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy_document) | data source |
| [aws_iam_policy_document.secret_readers](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy_document) | data source |
| [aws_kms_public_key.signing](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/kms_public_key) | data source |
| [aws_partition.current](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/partition) | data source |
| [aws_region.current](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/region) | data source |
| [aws_route53_zone.cluster](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/route53_zone) | data source |
| [tls_certificate.cluster](https://registry.terraform.io/providers/hashicorp/tls/latest/docs/data-sources/certificate) | data source |

## Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| name | Cluster name. Also prefixes the IAM roles, the Karpenter discovery tag and the default gateway EIP names. | `string` | n/a | yes |
| network | Existing VPC wiring, created upstream and never owned here.<br/>node\_subnet\_ids are the private subnets nodes launch into; pod\_subnet\_ids narrows the subnets Cilium<br/>allocates pod ENIs from (defaults to the node subnets); public\_subnet\_ids carry the public Gateway's NLB and its<br/>reserved EIPs (a private Gateway spans the node subnets instead, so they may be omitted then).<br/>manage\_discovery\_tags lets this module apply the karpenter.sh/discovery tag to those subnets - turn it off<br/>where the VPC owner tags them instead.<br/>security\_group\_ids attach to the control-plane ENIs alongside the EKS-managed cluster security group - use<br/>them for caller-owned rules (e.g. API access from a bastion or VPN range).<br/>restrict\_default\_security\_group revokes the allow-all egress rules (0.0.0.0/0 and ::/0) on the EKS-managed<br/>cluster security group and pins the documented minimum self-rules there instead. The revoke runs the AWS CLI<br/>on the apply host (it must be installed and authenticated as the provider identity, with<br/>ec2:DescribeSecurityGroupRules and ec2:RevokeSecurityGroupEgress), fires once per cluster after bootstrap,<br/>and is drift-blind: a manually re-added rule is not re-revoked, and toggling back off restores nothing.<br/>Nodes wear that group, so only enable this where node egress (ECR and S3 pulls, the EKS and SSM APIs)<br/>arrives through VPC endpoints or caller-added rules. | <pre>object({<br/>    vpc_id                          = string<br/>    node_subnet_ids                 = set(string)<br/>    pod_subnet_ids                  = optional(set(string), [])<br/>    public_subnet_ids               = optional(set(string), [])<br/>    manage_discovery_tags           = optional(bool, true)<br/>    security_group_ids              = optional(set(string), [])<br/>    restrict_default_security_group = optional(bool, false)<br/>  })</pre> | n/a | yes |
| platform\_registry | Where the cluster consumes charts, images and the manifests artifact from. Pass a module output rather than<br/>composing this by hand - `module.cache.platform_registry` (a pull-through cache in the cluster's own account, the<br/>default posture) or `module.store.platform_registry` (reading a central store directly, which additionally requires<br/>the store to admit this cluster's registry\_reader\_principals). Both modules emit exactly this shape, so the<br/>is\_pull\_through\_cache flag is never guessed.<br/><br/>url is <account>.dkr.ecr.<region>.amazonaws.com/<prefix>. is\_pull\_through\_cache adds ecr:CreateRepository and<br/>ecr:BatchImportUpstreamImage to every puller's grant - a cache materialises each repository on its FIRST pull, so<br/>without them the first image pull of a fresh cluster fails. | <pre>object({<br/>    url                   = string<br/>    is_pull_through_cache = bool<br/>  })</pre> | n/a | yes |
| signed\_identity | Cosign verification identity for every platform artifact - exactly one of two modes.<br/><br/>KEYLESS (subjects set, kms\_key\_arn null): Go regexps matched against the Fulcio certificate of GitHub Actions OIDC<br/>signatures. The artifact-store module's signed\_identity\_subjects output provides the subjects; the issuer default<br/>matches GitHub Actions. Cloud agnostic - the signing identities are GitHub's, not AWS's, so the same values serve<br/>clusters on any cloud.<br/><br/>KMS (kms\_key\_arn set, subjects null): the publish workflows sign with an asymmetric SIGN\_VERIFY KMS key<br/>(cosign sign --key awskms:///<arn>; the artifact-store module's signing\_kms\_key\_arn grants the publishers kms:Sign).<br/>The key's public half is distributed to the cluster as the flux-system cosign-pub Secret for the bootstrap verify<br/>patch, the ARN is published as the SIGNED\_IDENTITY\_KMS\_KEY cluster var, and kyverno's controllers get<br/>kms:GetPublicKey / kms:Verify to resolve it at admission time. | <pre>object({<br/>    issuer             = optional(string, "^https://token\\.actions\\.githubusercontent\\.com$")<br/>    manifests_subject  = optional(string)<br/>    containers_subject = optional(string)<br/>    kms_key_arn        = optional(string)<br/>  })</pre> | n/a | yes |
| addons | EKS add-ons. Everything AWS offers managed is taken managed, and only the rest reaches the cluster through flux.<br/>vpc-cni and kube-proxy are absent by construction - Cilium replaces both, and<br/>bootstrap\_self\_managed\_addons is off so EKS never installs them.<br/><br/>aws-secrets-store-csi-driver-provider bundles the Secrets Store CSI driver alongside the AWS provider, so only the<br/>secrets-store-sync-controller (the SecretSync CRD) remains a flux component. metrics-server is a COMMUNITY add-on:<br/>AWS supports its lifecycle, not the software. cert-manager and external-dns are community add-ons too but stay<br/>flux-managed on purpose - as add-ons they would pull images from AWS's registry, breaking the invariant that<br/>clusters never pull from a public registry and the Kyverno policy that enforces it. | <pre>map(object({<br/>    enabled              = optional(bool, true)<br/>    version              = optional(string)<br/>    configuration_values = optional(string)<br/>  }))</pre> | <pre>{<br/>  "aws-ebs-csi-driver": {},<br/>  "aws-secrets-store-csi-driver-provider": {},<br/>  "coredns": {},<br/>  "eks-node-monitoring-agent": {},<br/>  "eks-pod-identity-agent": {},<br/>  "metrics-server": {},<br/>  "snapshot-controller": {}<br/>}</pre> | no |
| application\_vars | Per-application substitution values, keyed by application short name: each entry is rendered as the <key>-vars<br/>ConfigMap in flux-system (terraform-reconciled through cluster-inputs, so changes flow through applies), which the<br/>application's Kustomization substitutes from beside cluster-vars. Keys are top-level rather than nested in<br/>applications so a composite image's inner applications can each have their own ConfigMap. Keys must be<br/>SCREAMING\_SNAKE\_CASE, matching the substitution syntax; an application's own module typically emits this map. | `map(map(string))` | `{}` | no |
| applications | Application manifest images this cluster seeds, keyed by the application's short name. Each entry creates a<br/>bootstrap-only seed in flux-system (a ResourceSetInputProvider and ResourceSet named <key>-manifests) that<br/>resolves the newest tag matching semver, verifies the image's cosign signature and applies path from it as<br/>Kustomization <key>; the image ships the same two seed objects under flux/ and owns them from its first<br/>reconcile, so a new application release never needs a terraform apply. Removing a key uninstalls the seed and<br/>prunes the application. The entry is applied once and then ignored (ignore\_changes), exactly like the<br/>flux-operator and flux-instance releases.<br/>  - url: the image without a tag or digest. An ECR url must live under platform\_registry.url (the flux<br/>    controllers pull it with their Pod Identity and list its tags through the ECR API); any other registry is<br/>    listed and pulled generically, optionally with pull\_secret (a kubernetes.io/dockerconfigjson Secret in<br/>    flux-system that both the tag listing and the pull read).<br/>  - semver: the tag range the seed follows (default >=0.0.0); a range matching no tag prunes the application.<br/>  - path: the Kustomization path inside the image (default ./deploy/<flux.sync.path>, the same per-cloud tree<br/>    selector the platform uses, published as PLATFORM\_TREE).<br/>  - depends\_on: platform Kustomizations the application waits for (default kyverno-policies).<br/>  - verify: keyless (subject, a Fulcio certificate-subject regexp; issuer defaults to signed\_identity.issuer)<br/>    XOR keyed (the cosign-pub public-key Secret, KMS mode only).<br/>  - dex\_clients: OIDC relying parties the application registers with the platform's dex, keyed by client id.<br/>    A confidential client (public = false) gets a generated secret in Secrets Manager<br/>    (<secret\_prefix>dex-client-<id>, rotated by bumping version) that dex and the client's readers (the<br/>    application's secret-sync KSAs, as <namespace>/<service-account>) may read; a public client (PKCE) gets<br/>    none. Every client is published in DEX\_CLIENTS. Requires sso.enabled.<br/>Application vars ride separately in application\_vars, so a composite image's inner applications can each have<br/>their own ConfigMap. | <pre>map(object({<br/>    url        = string<br/>    semver     = optional(string, ">=0.0.0")<br/>    path       = optional(string)<br/>    interval   = optional(string, "30m")<br/>    depends_on = optional(set(string), ["kyverno-policies"])<br/>    verify = object({<br/>      issuer  = optional(string)<br/>      subject = optional(string)<br/>      keyed   = optional(bool, false)<br/>    })<br/>    pull_secret = optional(string)<br/>    prune       = optional(bool, true)<br/>    wait        = optional(bool, true)<br/>    timeout     = optional(string, "5m")<br/>    dex_clients = optional(map(object({<br/>      name          = optional(string)<br/>      public        = optional(bool, false)<br/>      redirect_uris = optional(list(string), [])<br/>      readers       = optional(set(string), [])<br/>      version       = optional(number, 1)<br/>    })), {})<br/>  }))</pre> | `{}` | no |
| cilium | The CNI. Cilium runs in ENI mode with the AWS VPC CNI never installed, so pods hold routable VPC addresses exactly<br/>as they would under vpc-cni, and kube-proxy is replaced by Cilium's eBPF datapath. This is the one chart terraform<br/>installs: it must exist before the first node can report Ready, so flux cannot own the bootstrap. The release is<br/>bootstrap-only (ignore\_changes) and the stack's cilium component adopts it afterwards.<br/><br/>operator\_pod\_identity moves the ENI permissions off the node role and onto a Pod Identity association. Off by<br/>default: in ENI mode the agent cannot report Ready until the operator has attached ENIs, but the pod-identity-agent<br/>addon only installs once nodes exist - a bootstrap cycle. Turn it on against a running cluster if the node-role<br/>grant is unacceptable. helm\_values is merged OVER the computed values for anything not modelled here. | <pre>object({<br/>    chart_version         = optional(string)<br/>    repository            = optional(string)<br/>    operator_pod_identity = optional(bool, false)<br/>    helm_values           = optional(any, {})<br/>  })</pre> | `{}` | no |
| cluster\_admin\_principals | IAM principal ARNs granted AmazonEKSClusterAdminPolicy through an access entry - the break-glass and CI identities.<br/>The creating principal is admitted automatically (bootstrap\_cluster\_creator\_admin\_permissions), so this is for<br/>everyone else. | `set(string)` | `[]` | no |
| cluster\_log\_types | Control-plane log streams shipped to CloudWatch Logs. | `set(string)` | <pre>[<br/>  "api",<br/>  "audit",<br/>  "authenticator"<br/>]</pre> | no |
| dns | Existing delegated Route53 hosted zone (created upstream; never owned here, so cluster destroy/recreate never<br/>touches the zone or its NS delegation). zone\_name enables the DNS/TLS surface: the external-dns + cert-manager<br/>grants and the DNS\_* / PLATFORM\_DOMAIN cluster vars. The PUBLIC flavour of the zone is always required - Let's<br/>Encrypt resolves cert-manager's DNS-01 challenges over public DNS, so even a fully internal cluster keeps a<br/>public zone for certificate issuance. private\_zone adds the split-horizon flavour: a private zone under the<br/>same name, associated with the cluster VPC, shadowing the public one for in-VPC resolution - required when the<br/>Gateway is private (gateway.private), and equally valid alongside a public Gateway endpoint. host optionally<br/>narrows the served host below the zone apex - it is published as PLATFORM\_DOMAIN, the host the platform's<br/>wildcard Gateway listener and every application route hang off. | <pre>object({<br/>    zone_name    = optional(string)<br/>    private_zone = optional(bool, false)<br/>    host         = optional(string)<br/>    acme_email   = optional(string)<br/>  })</pre> | `{}` | no |
| encryption\_kms\_key\_arn | Optional customer-managed KMS key for Kubernetes secrets envelope encryption; null leaves EKS's default encryption in place. | `string` | `null` | no |
| flux | Flux bootstrap knobs. Chart repositories, the distribution registry and the sync url default onto platform\_registry<br/>(sync.url defaults to oci://<registry>/manifests/platform, the platform entrypoint image, and is published as<br/>FLUX\_SYNC\_URL - the platform's flux component asserts it on the FluxInstance, which is how a running cluster is<br/>re-pointed); sync.ref picks the release channel (stable, staging, or edge for dev clusters tracking trunk -- pair<br/>edge with the manifests\_edge signing subject), which the entrypoint pins every component to unless a<br/><NAME>\_MANIFESTS\_REF cluster var overrides one; sync.path selects the per-cloud tree ("aws" -- requires<br/>platform-manifests >= 4.0.0), published as PLATFORM\_TREE so applications select the same tree. | <pre>object({<br/>    operator_chart = optional(object({<br/>      repository = optional(string)<br/>      version    = optional(string)<br/>    }), {})<br/>    instance_chart = optional(object({<br/>      repository = optional(string)<br/>      version    = optional(string)<br/>    }), {})<br/>    distribution = optional(object({<br/>      version  = optional(string, "2.x")<br/>      registry = optional(string)<br/>      artifact = optional(string)<br/>    }), {})<br/>    sync = optional(object({<br/>      url      = optional(string)<br/>      ref      = optional(string, "stable")<br/>      path     = optional(string, "aws")<br/>      interval = optional(string, "5m")<br/>    }), {})<br/>    kustomize_patches = optional(list(any), [])<br/>    cluster_vars      = optional(map(string), {})<br/>    namespaces        = optional(list(string), [])<br/>  })</pre> | `{}` | no |
| gateway | The platform Gateway's static addresses. One Cilium Gateway materialises one LoadBalancer Service (an NLB), and<br/>every HTTPRoute hostname shares its address - so the EIPs are reserved once, one per public subnet the NLB spans,<br/>and new hosts are manifests-only. Reserving them here (default) keeps them outside the disposable cluster's<br/>lifecycle, so destroy/recreate serves the same addresses; alternatively reference existing allocations by id.<br/><br/>private flips the NLB internal: it spans the node subnets instead of the public ones and takes no Elastic IPs<br/>(internal NLBs cannot carry them), so the whole EIP surface above goes inert. A private Gateway is only<br/>reachable through in-VPC resolution, which is what requires dns.private\_zone - the public zone still exists,<br/>carrying only the cert-manager DNS-01 challenges that certificate issuance needs.<br/><br/>install\_crds publishes GATEWAY\_API\_CRDS, which has the flux-manifests gateway component install the Gateway API<br/>CRDs (the standard-channel set Cilium requires): EKS ships none today, and Cilium implements the API without<br/>owning its CRDs. Flip it off if the CRDs arrive some other way - most likely the day EKS installs them as managed<br/>cluster furniture - and the manifests orphan them rather than pruning (deleting a CRD deletes every Gateway and<br/>HTTPRoute with it). | <pre>object({<br/>    private           = optional(bool, false)<br/>    reserve_static_ip = optional(bool, true)<br/>    allocation_ids    = optional(set(string), [])<br/>    install_crds      = optional(bool, true)<br/>  })</pre> | `{}` | no |
| karpenter | Workload capacity, provisioned by Karpenter. Terraform owns the IAM roles, the interruption<br/>queue and the discovery tags; the chart and the EC2NodeClass/NodePool objects are a flux-manifests component,<br/>rendered from the KARPENTER\_* cluster vars this shape publishes (lists arrive comma-joined and are expanded with<br/>splitList, exactly as PLATFORM\_COMPONENTS already is).<br/><br/>There is deliberately no min\_nodes: Karpenter scales from zero on pending pods and offers only ceilings<br/>(spec.limits). The cluster's floor is system\_node\_group.min\_size. | <pre>object({<br/>    node_pool = optional(object({<br/>      name                 = optional(string, "default")<br/>      instance_categories  = optional(list(string), ["c", "m", "r"])<br/>      instance_families    = optional(list(string), [])<br/>      instance_sizes       = optional(list(string), ["large", "xlarge", "2xlarge"])<br/>      capacity_types       = optional(list(string), ["spot", "on-demand"])<br/>      architectures        = optional(list(string), ["amd64"])<br/>      ami_alias            = optional(string, "al2023@latest")<br/>      max_nodes            = optional(number, 20)<br/>      max_cpu              = optional(number, 64)<br/>      max_memory_gib       = optional(number, 256)<br/>      disk_size_gib        = optional(number, 100)<br/>      consolidation_policy = optional(string, "WhenEmptyOrUnderutilized")<br/>      consolidate_after    = optional(string, "1m")<br/>      expire_after         = optional(string, "720h")<br/>    }), {})<br/>  })</pre> | `{}` | no |
| kubernetes\_version | EKS control-plane version, e.g. 1.34. Null tracks whatever EKS defaults to at create and pins it in state. | `string` | `null` | no |
| node\_groups | Additional managed node groups, keyed by name ("system" is reserved for the platform tier). Most clusters need<br/>none - Karpenter provisions workload capacity - so this exists for capacity Karpenter cannot express: static<br/>pools with extra security groups, or Windows nodes.<br/>Each group takes the system\_node\_group sizing arguments plus: security\_group\_ids, attached to the group's nodes<br/>through its launch template alongside the EKS-managed cluster security group every node wears; ami\_type,<br/>selecting the AMI family (null is the EKS AL2023 default); labels and taints for scheduling.<br/>Linux groups get the Cilium agent-not-ready bootstrap taint automatically, exactly like the system group.<br/>WINDOWS\_* groups instead run the AMI's bundled vpc-shared-eni CNI (Cilium has no Windows datapath): they join<br/>through a dedicated windows node role and EC2\_WINDOWS access entry this module creates on demand, they skip the<br/>Cilium taint, and their pods are addressed by EKS's control-plane VPC resource controller - which only hands out<br/>addresses once Windows IPAM is enabled (the amazon-vpc-cni ConfigMap in kube-system with<br/>enable-windows-ipam: "true", a Kubernetes object this module does not manage; ship it through flux). | <pre>map(object({<br/>    instance_types     = optional(list(string), ["m7i.large"])<br/>    capacity_type      = optional(string, "ON_DEMAND")<br/>    min_size           = optional(number, 2)<br/>    max_size           = optional(number, 4)<br/>    desired_size       = optional(number, 2)<br/>    disk_size_gib      = optional(number, 50)<br/>    security_group_ids = optional(set(string), [])<br/>    ami_type           = optional(string)<br/>    labels             = optional(map(string), {})<br/>    taints = optional(list(object({<br/>      key    = string<br/>      value  = optional(string)<br/>      effect = string<br/>    })), [])<br/>  }))</pre> | `{}` | no |
| observability | Where the otel-collector ships telemetry. CloudWatch and X-Ray in the cluster's own account always; amp\_endpoint<br/>optionally adds an Amazon Managed Prometheus remote-write target (and the aps:RemoteWrite grant that goes with it).<br/>Pass the workspace's full remote-write URL (…/workspaces/ws-…/api/v1/remote\_write) - the manifests hand it to the<br/>prometheusremotewrite exporter verbatim. | <pre>object({<br/>    amp_endpoint = optional(string)<br/>  })</pre> | `{}` | no |
| platform\_components | The platform-manifests electable-tier components (short names: flux-web, arc) this cluster elects, published<br/>as the PLATFORM\_COMPONENTS cluster var. The platform entrypoint's ResourceSet ranges over the election: an<br/>elected component gets its own OCIRepository (oci://<registry>/manifests/<name>) and Kustomization. Electing<br/>none is explicit - set []. dex is not elected here: it deploys exactly when sso is enabled, and without it the<br/>elected components still run, just with no SSO auth and no human-facing HTTPRoute (kubectl port-forward to<br/>reach). The core tier (flux, cilium, kyverno, kyverno-policies, cert-manager, cert-manager-issuers,<br/>external-dns, gateway, aws-load-balancer-controller, rbac, secret-sync) is never electable. Applications are<br/>not components: they arrive through var.applications as their own images. | `set(string)` | <pre>[<br/>  "flux-web"<br/>]</pre> | no |
| public\_access | Public control-plane endpoint. Disabled by default, so the API is reachable only through the always-on private<br/>endpoint. When enabled, cidrs constrains who may reach the public endpoint; empty leaves it open to 0.0.0.0/0<br/>(PoC posture) - constrain it as soon as a stable egress CIDR exists. | <pre>object({<br/>    enable = optional(bool, false)<br/>    cidrs  = optional(set(string), [])<br/>  })</pre> | `{}` | no |
| rbac | Cluster RBAC subjects. Each role names the Kubernetes group its access entry (or OIDC federation) maps to. The<br/>group names are published as RBAC\_GROUP\_<ROLE> cluster vars, which flux-manifests' rbac component binds<br/>Role/ClusterRoleBindings against - the manifests contract carries only group names, never the subject type<br/>behind them.<br/>principal\_arn is optional: set it for an IAM Identity Center permission-set role (or any IAM role/user) that<br/>should get an EKS access entry mapping it onto the group. Leave it null when the group is populated purely<br/>through OIDC federation instead (sso.kubectl) - no access entry is created, and the group name only ever<br/>reaches Kubernetes via the groups claim dex asserts. A role can rely on both mechanisms at once by giving the<br/>IAM principal and the OIDC-asserted group the same literal group name. | <pre>object({<br/>    enabled = optional(bool, false)<br/>    groups = optional(object({<br/>      viewers    = optional(object({ principal_arn = optional(string), group = optional(string, "platform:viewers") }))<br/>      developers = optional(object({ principal_arn = optional(string), group = optional(string, "platform:developers") }))<br/>      devops     = optional(object({ principal_arn = optional(string), group = optional(string, "platform:devops") }))<br/>      admins     = optional(object({ principal_arn = optional(string), group = optional(string, "platform:admins") }))<br/>    }), {})<br/>  })</pre> | `{}` | no |
| secret\_prefix | Prefix for every Secrets Manager secret name the platform and its applications sync, published as the<br/>SECRET\_PREFIX cluster var. Lets multiple clusters share one account with distinct secrets; the modules/sso-secrets<br/>instantiation (a durable root, holding the out-of-band dex connector credentials) and every application module<br/>creating containers must use the same prefix. Include the trailing separator (e.g. 'platform-x-'); empty keeps<br/>the unprefixed names. | `string` | `null` | no |
| sso | Platform SSO: deploys dex as the OIDC identity provider and wires every elected relying party to it -- generated<br/>client pairs (sso.tf), the DEX\_CONNECTORS cluster var, and the human-facing HTTPRoutes. Upstream identity is<br/>arbitrary: connector declares the deployment's single upstream IdP -- which connector type a deployment federates<br/>isn't known ahead of time, but it only ever federates one --<br/>  - type: the dex connector type (oidc, saml, google, microsoft, github, ...), passed through verbatim, not<br/>    validated against dex's own supported list.<br/>  - id: the dex connector id, also the naming stem for the credential containers (dex-<id>-<field>) and env vars;<br/>    defaults to type -- set it when the type alone reads poorly (e.g. id = "okta" for an oidc connector).<br/>  - name: the display name shown on dex's login screen; defaults to the connector id when unset.<br/>  - config: the connector's own config: block, passed through near-verbatim (issuer, clientID, scopes,<br/>    claimMapping, adminEmail, ...) -- a redirectURI is injected by default (sso.tf) unless the caller sets one.<br/>    Values keep their native types (bools, lists, numbers) all the way into dex's rendered YAML, e.g.<br/>    fetchTransitiveGroupMembership = true stays a bool.<br/>  - secrets: the out-of-band credential fields this connector needs (default ["client-id", "client-secret"]).<br/>    Each field becomes a dex-<id>-<field> Secrets Manager container (modules/secrets, instantiated in a durable<br/>    root and fed this same sso value -- an OAuth client cannot be terraformed, so its credentials arrive out of<br/>    band) and a <ID>\_<FIELD> env var (uppercased, dashes -> underscores) dex expands<br/>    from its own process env at startup ($<ID>\_<FIELD>) -- reference it yourself, e.g.<br/>    config.clientID = "$GOOGLE\_CLIENT\_ID".<br/>Requires the DNS surface: the issuer and redirect URLs need the served domain.<br/>clients holds the per-client knobs for the platform's own generated relying-party pair (key: flux-web) -- today<br/>just version, the client secret's rotation counter (absent clients sit at 1): bump it to mint a new client secret;<br/>the raw dex-client-* secret and any config document embedding the same value rewrite in one apply, so the pair<br/>cannot drift (then restart dex: it reads client secrets from env at startup). Application clients carry their<br/>own version under applications[*].dex\_clients; every client, platform or application, is published in<br/>DEX\_CLIENTS for the dex component to render.<br/>kubectl federates the EKS API server itself to dex (an aws\_eks\_identity\_provider\_config), so kubectl can<br/>authenticate humans through Okta/whatever upstream connector without an IAM principal at all -- pair it with an<br/>rbac.groups entry that has no principal\_arn, just the OIDC-asserted group name. client\_id names dex's PUBLIC<br/>static client for this flow (no secret: kubectl's OIDC device/PKCE flow can't hold one), rendered by<br/>flux-manifests' dex component once elected. groups\_claim\_prefix is prepended to every group dex asserts before<br/>the API server evaluates RBAC (AWS requires a non-empty prefix, so a spoofed claim can't collide with system:<br/>or IAM-sourced group names) -- an rbac.groups.*.group value reached this way must carry the same prefix<br/>literally, e.g. group = "oidc:GRP\_PATCHY\_NONPROD\_ADMIN" when groups\_claim\_prefix is the default "oidc:".<br/>BOOTSTRAP ORDER: unlike the dex relying parties above, the identity provider config is validated by the EKS API<br/>at creation time -- it calls the issuer's discovery endpoint. On a cluster's first apply dex isn't deployed yet<br/>(flux installs it after the cluster exists), so this resource can only be created once dex is live and serving<br/>over its Gateway route: expect a first apply with sso.kubectl.enabled = false, then a second apply once flux<br/>has converged to turn it on. | <pre>object({<br/>    enabled = optional(bool, false)<br/>    connector = optional(object({<br/>      id      = optional(string)<br/>      type    = string<br/>      name    = optional(string)<br/>      config  = optional(any, {})<br/>      secrets = optional(set(string), ["client-id", "client-secret"])<br/>    }))<br/>    clients = optional(map(object({<br/>      version = number<br/>    })), {})<br/>    kubectl = optional(object({<br/>      enabled             = optional(bool, false)<br/>      client_id           = optional(string, "kubectl-oidc")<br/>      redirect_uris       = optional(list(string), ["http://localhost:8000/callback"])<br/>      groups_claim_prefix = optional(string, "oidc:")<br/>    }), {})<br/>  })</pre> | `{}` | no |
| system\_node\_group | The always-on managed node group platform controllers pin to (label role=system): flux, kyverno, cert-manager,<br/>external-dns, karpenter and the rest. These counts are CLUSTER-WIDE totals, not per-zone.<br/>Sizing must fit the whole platform tier - Karpenter only provisions workload capacity, never this. | <pre>object({<br/>    instance_types = optional(list(string), ["m7i.large"])<br/>    capacity_type  = optional(string, "ON_DEMAND")<br/>    min_size       = optional(number, 2)<br/>    max_size       = optional(number, 4)<br/>    desired_size   = optional(number, 2)<br/>    disk_size_gib  = optional(number, 50)<br/>  })</pre> | `{}` | no |
| tags | Tags applied to every resource this module creates. | `map(string)` | `{}` | no |
| upgrade\_policy | EKS support policy. STANDARD ends support at the end of standard support; EXTENDED keeps a version supported (at<br/>extra cost) past that date. | `string` | `"STANDARD"` | no |
| workload\_grants | Application workload IAM grants, keyed by a short name: each entry becomes one IAM role (<name>-<key>) carrying<br/>the given policy document, bound to its namespace/service-account pair through an EKS Pod Identity association.<br/>This is how an application module hands its cloud permissions to the cluster (e.g. a model-invoke grant for an<br/>egress broker): the module emits the map, the root wires it here, and nothing application-specific lives in this<br/>module. The platform's own pairs (external-dns, cert-manager, kyverno, the load-balancer controller, karpenter,<br/>otel-collector) are fixed by workload\_identity and are not declared here. Podless secret-sync readers are the<br/>one grant shape this map cannot express - list those under workload\_identity.secret\_readers instead. | <pre>map(object({<br/>    namespace       = string<br/>    service_account = string<br/>    policy          = string<br/>  }))</pre> | `{}` | no |
| workload\_identity | Namespace/service-account pairs the PLATFORM workload IAM roles bind to (EKS Pod Identity associations, except<br/>the podless secret\_readers which bind through IRSA) - the terraform <-> platform-manifests contract, cloud-neutral<br/>in shape so every cluster tracks the same manifests. Override the platform pairs only to follow a manifests<br/>change; application grants arrive through workload\_grants instead.<br/>secret\_readers lists the KSAs the secrets-store-sync-controller runs as when materialising a consumer's<br/>SecretSync objects (podless, so IRSA rather than Pod Identity): every application that syncs secrets names its<br/><namespace>/<service-account> pair here (an application module's secret\_readers output), on top of the pairs the<br/>SSO surface derives itself. Each becomes a <name>-secrets-<ns>-<sa> role, published as SECRETS\_ROLE\_PREFIX. | <pre>object({<br/>    external_dns = optional(object({<br/>      namespace       = optional(string, "external-dns")<br/>      service_account = optional(string, "external-dns")<br/>    }), {})<br/>    cert_manager = optional(object({<br/>      namespace       = optional(string, "cert-manager")<br/>      service_account = optional(string, "cert-manager")<br/>    }), {})<br/>    otel_collector = optional(object({<br/>      namespace       = optional(string, "otel-collector")<br/>      service_account = optional(string, "otel-collector")<br/>    }), {})<br/>    kyverno = optional(object({<br/>      namespace = optional(string, "kyverno")<br/>      # the controllers that fetch image signatures from the registry at<br/>      # admission/report time<br/>      service_accounts = optional(list(string), ["kyverno-admission-controller", "kyverno-reports-controller"])<br/>    }), {})<br/>    # NOT an ingress path: Cilium is the Gateway API implementation and owns all<br/>    # L7 routing. The AWS Load Balancer Controller exists only to turn the one<br/>    # Service type=LoadBalancer that Cilium's Gateway materialises into an NLB<br/>    # bound to the reserved EIPs. EKS's built-in legacy cloud provider could do<br/>    # that too, but AWS ships it critical fixes only and advises against new<br/>    # NLBs on it.<br/>    load_balancer = optional(object({<br/>      namespace       = optional(string, "aws-load-balancer-controller")<br/>      service_account = optional(string, "aws-load-balancer-controller")<br/>    }), {})<br/>    karpenter = optional(object({<br/>      namespace       = optional(string, "kube-system")<br/>      service_account = optional(string, "karpenter")<br/>    }), {})<br/>    # the KSAs the secrets-store-sync-controller runs as when materialising<br/>    # a consumer's SecretSync objects, beyond the pairs the SSO surface<br/>    # derives itself (sso.tf / iam.tf) - applications declare theirs here<br/>    secret_readers = optional(list(object({<br/>      namespace       = string<br/>      service_account = string<br/>    })), [])<br/>  })</pre> | `{}` | no |

## Outputs

| Name | Description |
| ---- | ----------- |
| arn | Cluster ARN. |
| ca\_certificate | Base64-encoded cluster CA certificate. |
| cilium | How Cilium is wired: the release terraform bootstraps (and the stack adopts), and where its ENI permissions live. |
| dns | Delegated zone wiring (null when dns.zone\_name is unset): zone name, per-flavour hosted zone ids (public always;<br/>private under split-horizon), apex domain, served host and the public zone's name servers. |
| endpoint | Control-plane endpoint (host for the helm/kubernetes providers). |
| flux | Flux bootstrap facts: the namespace, the platform entrypoint the FluxInstance syncs, the electable components in<br/>force, the application seeds (per key: the seed release, its tag-listing provider and the resolved path) and the<br/>exact cluster-vars contract this cluster publishes to the platform. |
| gateway | The Gateway's static addresses - reserved here or referenced from existing allocations (null when neither, and<br/>always null for a private Gateway, which carries no EIPs). One Cilium Gateway shares these across every HTTPRoute<br/>host. |
| karpenter | Karpenter wiring the flux-manifests component renders its EC2NodeClass/NodePool from: the node role, the<br/>interruption queue and the subnet/security-group discovery tag. |
| kubectl\_oidc | kubectl-via-dex wiring (null unless sso.kubectl.enabled): the EKS identity provider config name (null until the<br/>second, post-bootstrap apply that creates it -- see sso.kubectl's bootstrap-order note) plus the issuer, client<br/>id and groups prefix a kubelogin (int128/kubelogin, `kubectl oidc-login`) exec-plugin kubeconfig entry needs:<br/><br/>  kubectl oidc-login setup \<br/>    --oidc-issuer-url=<issuer> \<br/>    --oidc-client-id=<client\_id> \<br/>    --oidc-extra-scope=groups,email,profile<br/><br/>then wire the same three flags into a user's `kubectl config set-credentials --exec-command=kubectl<br/>--exec-arg=oidc-login --exec-arg=get-token ...` entry. rbac.groups.*.group for a role reached this way must<br/>carry groups\_prefix literally, e.g. "oidc:GRP\_PATCHY\_NONPROD\_ADMIN". |
| kubernetes\_version | Current control-plane version. |
| name | Cluster name. |
| node\_groups | Each var.node\_groups entry's actual node group name and ARN (the names carry generated suffixes). |
| node\_iam\_role | The IAM role shared by the Linux managed node groups (name and ARN); Windows node groups and Karpenter nodes use their own separate roles. |
| platform\_registry | The platform registry this cluster consumes from (pass-through of var.platform\_registry): its url and whether it is<br/>a pull-through cache. |
| rbac | Cluster RBAC subjects (null unless rbac.enabled): each role's IAM principal (null when the role is OIDC-only) and<br/>the Kubernetes group it maps onto, published as the RBAC\_GROUP\_* cluster vars flux-manifests binds against. |
| registry\_reader\_principals | Every identity that reads the platform registry (node roles, flux controllers, kyverno controllers). Covered<br/>automatically when platform\_registry is a pull-through cache in this account; feed these to the artifact-store<br/>module's direct\_pull\_principals when the cluster reads a central store directly instead. |
| secret\_prefix | The normalized Secrets Manager name prefix (var.secret\_prefix, or the empty string), published as SECRET\_PREFIX.<br/>Application modules and roots compose container names as <prefix><name> from this rather than re-deriving<br/>the rule. |
| secrets\_role\_prefix | The ARN prefix of the podless secret-sync reader roles (published as SECRETS\_ROLE\_PREFIX): a<br/>workload\_identity.secret\_readers pair <ns>/<sa> assumes <prefix><ns>-<sa>. Exported so an application's<br/>out-of-cluster wiring can name its reader roles without importing the naming rule. |
| sso | SSO facts this cluster owns (null unless sso.enabled): the dex issuer, every registered client (platform and<br/>application, as published in DEX\_CLIENTS), the generated dex-client-<id> secret names for the confidential ones<br/>and the composed config documents. The out-of-band dex-<id>-<field> connector containers live in<br/>modules/sso-secrets (a durable root), fed the same sso value. |
| system\_node\_group | The system node group's actual name and ARN (the name carries a generated suffix). |
| workload\_roles | Every workload IAM role this module mints, keyed as in iam.tf: the platform grants, each workload\_grants entry<br/>(by its key) and the secrets-<ns>-<sa> readers. Role ARNs, for roots that grant these identities further<br/>access (a bucket policy, a cross-account trust). |
<!-- END_TF_DOCS -->