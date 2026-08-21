# terraform-aws-eks-flux

An EKS cluster that bootstraps [flux-operator] and syncs a cosign-signed OCI manifests artifact from ECR — the platform
substrate for deploying [patchy] to AWS, running **Cilium in ENI mode** as the CNI and **Karpenter** for workload
capacity.

Three repos make the platform:

| repo                              | role                                                                              |
| --------------------------------- | --------------------------------------------------------------------------------- |
| **terraform-aws-eks-flux** (this) | the cluster, the artifact store and the flux bootstrap                            |
| [flux-containers]                 | vendors, scans, mirrors and keyless-signs charts + images into the artifact store |
| [flux-manifests]                  | the GitOps stack every cluster syncs                                              |

## Design

- **Cilium in ENI mode, no AWS VPC CNI.** `bootstrap_self_managed_addons = false` means EKS never installs `vpc-cni` or
  `kube-proxy`; Cilium is both the CNI and the kube-proxy replacement, and pods hold routable VPC addresses exactly as
  they would under `vpc-cni`. This is also what makes raw `CiliumNetworkPolicy` / `FQDNNetworkPolicy` usable, which
  managed Cilium distributions typically reject.
- **Karpenter for workload capacity.** Terraform owns the IAM roles, the interruption queue, the discovery tags **and
  the NodePool shape** (`var.karpenter`, published as `KARPENTER_*` cluster vars); flux-manifests owns the chart and
  renders the `EC2NodeClass`/`NodePool` from those vars. A small always-on **system node group** (`role=system`) carries
  the platform controllers.
- **Terraform deploys no Helm chart that flux does not go on to manage.** Everything AWS offers managed is an add-on
  (see `var.addons`); everything else is a flux-manifests component. The single exception is **Cilium**, which must
  exist before the first node can report `Ready` — terraform bootstraps it `ignore_changes`-style and the stack's
  `cilium` component adopts the release, exactly as it already does for `flux-operator`/`flux-instance`.
- **One ECR prefix, create-on-push.** ECR has no arbitrary-path model, so a **repository creation template** with
  `CREATE_ON_PUSH` restores Artifact Registry's ergonomics: publishers push to `<prefix>/charts/<name>` or
  `<prefix>/images/<path>` and ECR creates each repository with the template's lifecycle policy, tag mutability,
  encryption and tags.
- **Reads are org-wide, not per-account.** The store admits only the ECR pull-through cache service, matched on
  `aws:PrincipalOrgID`, so onboarding a cluster account means applying `modules/registry-cache` there — never editing
  the store. `direct_pull_principals` is the escape hatch for clusters allowed to read it straight.
- **Cosign everywhere — keyless by default, KMS as the alternative.** Keyless: artifacts are signed by GitHub Actions
  OIDC identities (Fulcio/Rekor), the generated `flux-system` OCIRepository verifies the manifests artifact via
  `matchOIDCIdentity`, the stack's OCIRepositories and Kyverno policy verify charts and images the same way, and no key
  material is distributed anywhere — because the signer is GitHub, the `signed_identity` values are cloud-agnostic.
  KMS: set `signed_identity.kms_key_arn` (and the store's `signing_kms_key_arn`) instead of the subjects; the
  publishers sign with `awskms:///<arn>`, the bootstrap distributes the key's public half as the `flux-system`
  `cosign-pub` Secret, and the ARN is published as `SIGNED_IDENTITY_KMS_KEY` for Kyverno. One mode or the other, never
  both.
- **EKS Pod Identity for every workload.** No IRSA trust policies, no annotations. `var.workload_identity` keeps the
  namespace/service-account shape cloud-neutral, so every cluster consumes the same manifests.
- **DNS/TLS survives cluster recreation.** The delegated Route53 zone lives upstream, and the Gateway's Elastic IPs are
  reserved outside the cluster's lifecycle — destroy/recreate serves the same addresses with no manual action.

### Bootstrap order

This ordering is what makes a single `terraform apply` work against an empty account, and every `depends_on` in the
module exists to hold it:

1. `aws_eks_cluster` with **no self-managed add-ons** — no `vpc-cni`, no `kube-proxy`, no `coredns`.
2. Access entries for the node roles (`EC2_LINUX`) and the RBAC principals.
3. **Cilium** (`helm_release`, `wait = false`) — there are no nodes yet, so the objects simply land in the API server
   and agents start the instant a node registers. Waiting here would deadlock against step 4.
4. The **system node group**, tainted `node.cilium.io/agent-not-ready=true:NoExecute`. Cilium tolerates all taints and
   its operator removes this one once the agent is ready. Because Cilium is already installed, nodes reach `Ready`
   promptly instead of failing with `NodeCreationFailure`.
5. **Add-ons** — `eks-pod-identity-agent` first, then the rest.
6. **Pod Identity associations**, then the **flux bootstrap chain**.

> **Why Cilium's ENI permissions sit on the node role.** In ENI mode the agent cannot report ready until the operator
> has attached ENIs, so the operator needs credentials during step 4 — while the pod-identity-agent add-on is a step 5
> artefact. Pod Identity there is a genuine cycle. This is also what the AWS VPC CNI does by default. Set
> `cilium.operator_pod_identity` against a running cluster to move it.

## Choosing a registry

`platform_registry` takes a `{ url, is_pull_through_cache }` object, and both registry modules emit exactly that shape —
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

The flag is load-bearing: a cache materialises each repository on its **first** pull, so a cluster wired to one without
`ecr:CreateRepository` + `ecr:BatchImportUpstreamImage` fails on its first image. Passing
`module.store.platform_registry` instead reads the store directly (`is_pull_through_cache = false`) and additionally
requires that store to admit the cluster's `registry_reader_principals`.

## Bootstrap sequence

1. **Upstream account setup** (created outside this repo): the
   account, VPC, private node subnets and public subnets, NAT or the ECR/S3/STS/EKS VPC endpoints, the delegated Route53
   zone, and the GitHub Actions OIDC provider. Subnets need the `kubernetes.io/role/{internal-,}elb` tags; the cluster
   module adds `karpenter.sh/discovery` itself.
2. **Artifact store** (`examples/artifact-store`) in the platform account. Feed its outputs to the publishing repos as
   the `AWS_CHART_PUBLISHER_ROLE` / `AWS_MANIFEST_PUBLISHER_ROLE` / `PLATFORM_REGISTRY` org-level Actions variables.
3. **flux-containers**: publish every chart + image — including `cilium` and `karpenter`.
4. **flux-manifests**: cut a release; its publish workflow pushes the signed artifact and moves the `staging` tag.
5. **Registry cache** (`examples/registry-cache`) in the cluster's account, then the **cluster**
   (`examples/complete` is the shape). One apply bootstraps Cilium and flux-operator, which syncs the stack.

## The terraform ↔ flux contract

The `cluster-vars` ConfigMap publishes these to the stack. Keys are deliberately cloud-neutral wherever the meaning is
shared, so one manifests stack serves every cloud and branches only on `CLOUD`. Optional surfaces use the
empty-string convention.

Cloud-neutral: `CLUSTER_NAME`, `PLATFORM_REGISTRY`, `CONTAINER_REGISTRY`, `OCI_PROVIDER`, `ARTIFACT_TAG_PROVIDER`,
`SIGNED_IDENTITY_ISSUER`, `SIGNED_IDENTITY_CHARTS`, `SIGNED_IDENTITY_IMAGES`, `SIGNED_IDENTITY_MANIFESTS`,
`FLUX_SYNC_CHANNEL`, `DNS_ZONE_NAME`,
`DNS_DOMAIN`, `PATCHY_DOMAIN`, `ACME_EMAIL`, `GATEWAY_IP`, `SECRET_PREFIX`, `STACK_COMPONENTS`, `AGENT_HARNESSES`,
`PATCHY_EVALUATION`, `RBAC_GROUP_*`.

`AGENT_HARNESSES` (`patchy.harnesses`; `claude`, `codex`, `copilot`, sorted and comma-joined with the same reserved
`none` convention as `STACK_COMPONENTS`) gates the patchy chart's runners and the harness credential syncs. The
out-of-band credential secrets those syncs read (the patchy GitHub App, the elected harnesses' model credentials)
come from [`modules/secrets`](modules/secrets/), instantiated in a **durable** root with the same election values as
the cluster module call — the versions are added with `aws secretsmanager put-secret-value` and must survive cluster
destroy/recreate with no manual re-entry. This module derives the matching secret-reader Pod Identity roles from the
same election (`iam.tf`), so the containers upstream and the identities reading them cannot drift.

`PATCHY_EVALUATION` (`patchy.evaluation.enabled`, published as the literal `"true"`/`"false"`) deploys patchy's
evaluation controller — the evolve-facing remote-evaluation API and its runner fleet; it requires `sso` (evolve
authenticates through dex as a public PKCE client) and at least one harness.

AWS-specific:

| key                                                | notes                                                    |
| -------------------------------------------------- | -------------------------------------------------------- |
| `CLOUD`                                            | `aws` — the key the stack branches on                    |
| `AWS_ACCOUNT_ID`, `AWS_REGION`, `AWS_PARTITION`    |                                                          |
| `VPC_ID`, `NODE_SECURITY_GROUP_ID`                 | for the load-balancer controller and Karpenter           |
| `CLUSTER_DISCOVERY_TAG`, `CLUSTER_DISCOVERY_VALUE` | `karpenter.sh/discovery` and its value                   |
| `DNS_ZONE_ID`                                      | Route53 hosted zone id (external-dns `--zone-id-filter`) |
| `GATEWAY_EIP_ALLOCATIONS`, `GATEWAY_SUBNETS`       | bound to the Gateway's NLB by annotation                 |
| `GATEWAY_NLB_TARGET_TYPE`                          | `instance` — see the caveat below                        |
| `OTEL_REGION`, `OTEL_AMP_ENDPOINT`                 | CloudWatch/X-Ray always; AMP when configured             |
| `SIGNED_IDENTITY_KMS_KEY`                          | the KMS signing key ARN (empty in keyless mode, when the `SIGNED_IDENTITY_*` subjects are set instead) |
| `DEX_CONNECTORS`                                   | JSON-encoded dex connector declarations (`sso.connectors`, normalized; `[]` when sso is off) |

Karpenter's NodePool shape travels the same way, since `cluster-vars` is a flat string map:

- **wiring** — `KARPENTER_NODE_ROLE`, `KARPENTER_INTERRUPTION_QUEUE`, `KARPENTER_SERVICE_ACCOUNT`
- **selection** — `KARPENTER_INSTANCE_CATEGORIES`, `KARPENTER_INSTANCE_FAMILIES`, `KARPENTER_INSTANCE_SIZES`,
  `KARPENTER_CAPACITY_TYPES`, `KARPENTER_ARCHITECTURES`. These are **comma-joined lists**, expanded manifests-side with
  `splitList` — the same pattern `STACK_COMPONENTS` already uses, so no new mechanism is involved.
- **ceilings** (`spec.limits`) — `KARPENTER_MAX_NODES`, `KARPENTER_CPU_LIMIT`, `KARPENTER_MEMORY_LIMIT`,
  `KARPENTER_NODE_DISK_GIB`
- **lifecycle** — `KARPENTER_AMI_ALIAS`, `KARPENTER_CONSOLIDATION_POLICY`, `KARPENTER_CONSOLIDATE_AFTER`,
  `KARPENTER_EXPIRE_AFTER`

The claude runner's model provider (`var.patchy.claude.provider`, terminated by patchy's egress-broker) travels the
same way. Keys are harness-scoped (`CLAUDE_*`; a codex/copilot surface would publish `CODEX_*` siblings) and the knobs
provider-prefixed (`CLAUDE_BEDROCK_REGION`, never a generic `REGION`) — the same names on every cloud, so the vertex
pair exists here too and is simply always empty on AWS:

| key                            | notes                                                                             |
| ------------------------------ | --------------------------------------------------------------------------------- |
| `CLAUDE_PROVIDER`              | `anthropic` (default) or `bedrock`                                                |
| `CLAUDE_ANTHROPIC_AUTH`        | `key` or `token` (default)                                                        |
| `CLAUDE_BEDROCK_REGION`        | when the provider is bedrock: the configured region or the cluster's; else empty  |
| `CLAUDE_BEDROCK_REGION_PREFIX` | inference-profile geo prefix (us/eu/apac); empty when unset                       |
| `CLAUDE_VERTEX_REGION`         | always empty on AWS (vertex needs GCP ambient credentials)                        |
| `CLAUDE_VERTEX_PROJECT_ID`     | always empty on AWS                                                               |
| `CLAUDE_MODEL_MAP`             | comma-joined sorted `canonical=providerID` pairs; empty when unmapped             |

When the provider is bedrock the broker's KSA (`patchy`/`patchy-egress-broker`) additionally gets a Pod Identity
grant for `bedrock:InvokeModel*` on Anthropic foundation models and inference profiles (`iam.tf`).

Callers may add extras via `flux.cluster_vars`; reserved keys always win. The published contract is exported as
`flux.cluster_vars` for inspection.

## Caveats

- **Karpenter is not an EKS add-on.** It appears in neither the AWS nor the community catalogue. The only AWS-managed
  Karpenter is **EKS Auto Mode**, which owns networking with the AWS VPC CNI on AWS-managed AMIs and therefore cannot
  run Cilium in ENI mode.
- **The AWS Load Balancer Controller is not an ingress path here.** Cilium is the Gateway API implementation and owns
  all L7 routing; the controller exists solely to turn the one `Service type=LoadBalancer` that Cilium's Gateway
  materialises into an NLB bound to the reserved EIPs. EKS's built-in legacy controller could do that too, but AWS
  ships it critical fixes only and advises against new NLBs on it.
- **NLB target type is `instance`, not `ip`.** The controller can only register IP targets when the AWS VPC CNI is the
  datapath; under any alternate CNI it is limited to instance targets, whatever the pods' addresses look like.
- **Karpenter has no minimum-node concept.** It scales from zero on pending pods and offers only ceilings
  (`spec.limits`). The cluster's floor is `system_node_pool.min_size`.
- **Managed node group counts are cluster-wide totals**, not per-availability-zone.
- **The helm provider must use an exec plugin, not `data.aws_eks_cluster_auth`.** That data source mints a presigned
  STS token valid for roughly 15 minutes and resolves it once, while a first apply spans cluster creation, the node
  group, the add-ons and only then the flux chain — comfortably longer, so the token expires mid-apply. The examples
  use `aws eks get-token`, which runs when credentials are actually needed. **This makes the AWS CLI a prerequisite on
  whatever runs terraform**, and the `--region` argument is passed explicitly so the CLI does not have to infer it from
  an environment that may not match the provider's. ECR authorization tokens are valid for 12 hours, so those stay
  ordinary data sources.
- **EKS has no `deletion_protection`.** Guard production clusters with policy or a state-level `prevent_destroy`.
- **`cert-manager` and `external-dns` stay flux-managed** despite being available as community add-ons: those are
  community tier (AWS supports only lifecycle operations), and taking them as add-ons would pull images from AWS's
  registry, breaking the "clusters never pull from a public registry" invariant and the Kyverno policy enforcing it.
- **Pull-through cache coverage is unvalidated for helm charts and cosign signatures.** ECR→ECR pull-through is a
  manifest/blob copy, so OCI chart artifacts and `sha256-<digest>.sig` tags should pass through intact — but the whole
  verification chain depends on it, so confirm both on first apply.
- **`aws_ecr_registry_policy` is a per-account, per-region singleton.** `modules/artifact-store` owns it; an account
  using registry policies for anything else must merge those statements via `additional_registry_statements`.

## Development

`make help` lists tasks (`fmt`, `lint`, `validate`, `test`, `docs`, `pr`). The toolchain submodule (`.mise/`) pins every
tool; `git submodule update --init` and `mise trust --all` once per clone.

Everything in `make lint` / `make test` runs against mocked providers, so no credentials are needed to develop here.
Applying a cluster additionally needs the **AWS CLI** on the machine running terraform — the helm provider's exec plugin
shells out to `aws eks get-token` (see the caveat above).

[flux-operator]: https://github.com/controlplaneio-fluxcd/flux-operator
[patchy]: https://github.com/bitwise-media-group/patchy
[flux-containers]: https://github.com/bitwise-media-group/flux-containers
[flux-manifests]: https://github.com/bitwise-media-group/flux-manifests

<!-- BEGIN_TF_DOCS -->
## Requirements

| Name | Version |
| ---- | ------- |
| terraform | >= 1.11, < 2.0 |
| aws | >= 6.0, < 7.0 |
| helm | ~> 3.0 |
| random | >= 3.7, < 4.0 |

## Providers

| Name | Version |
| ---- | ------- |
| aws | >= 6.0, < 7.0 |
| helm | ~> 3.0 |

## Modules

| Name | Source | Version |
| ---- | ------ | ------- |
| flux\_operator | ./modules/flux-operator | n/a |

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
| [aws_eks_access_entry.rbac](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/eks_access_entry) | resource |
| [aws_eks_access_policy_association.cluster_admins](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/eks_access_policy_association) | resource |
| [aws_eks_addon.main](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/eks_addon) | resource |
| [aws_eks_addon.pod_identity_agent](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/eks_addon) | resource |
| [aws_eks_cluster.main](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/eks_cluster) | resource |
| [aws_eks_node_group.system](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/eks_node_group) | resource |
| [aws_eks_pod_identity_association.cilium_operator](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/eks_pod_identity_association) | resource |
| [aws_eks_pod_identity_association.ebs_csi](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/eks_pod_identity_association) | resource |
| [aws_eks_pod_identity_association.karpenter_controller](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/eks_pod_identity_association) | resource |
| [aws_eks_pod_identity_association.workload](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/eks_pod_identity_association) | resource |
| [aws_iam_instance_profile.nodes](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_instance_profile) | resource |
| [aws_iam_role.cilium_operator](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role) | resource |
| [aws_iam_role.cluster](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role) | resource |
| [aws_iam_role.ebs_csi](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role) | resource |
| [aws_iam_role.karpenter_controller](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role) | resource |
| [aws_iam_role.karpenter_node](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role) | resource |
| [aws_iam_role.nodes](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role) | resource |
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
| [aws_secretsmanager_secret.dex_client](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/secretsmanager_secret) | resource |
| [aws_secretsmanager_secret.flux_web_auth_config](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/secretsmanager_secret) | resource |
| [aws_secretsmanager_secret.patchy_status_auth_config](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/secretsmanager_secret) | resource |
| [aws_secretsmanager_secret_policy.readers](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/secretsmanager_secret_policy) | resource |
| [aws_secretsmanager_secret_version.dex_client](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/secretsmanager_secret_version) | resource |
| [aws_secretsmanager_secret_version.flux_web_auth_config](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/secretsmanager_secret_version) | resource |
| [aws_secretsmanager_secret_version.patchy_status_auth_config](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/secretsmanager_secret_version) | resource |
| [aws_sqs_queue.karpenter_interruption](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/sqs_queue) | resource |
| [aws_sqs_queue_policy.karpenter_interruption](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/sqs_queue_policy) | resource |
| [helm_release.cilium](https://registry.terraform.io/providers/hashicorp/helm/latest/docs/resources/release) | resource |
| [aws_caller_identity.current](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/caller_identity) | data source |
| [aws_eip.gateway](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/eip) | data source |
| [aws_iam_policy_document.bedrock_invoke](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy_document) | data source |
| [aws_iam_policy_document.cilium_eni](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy_document) | data source |
| [aws_iam_policy_document.cluster_assume_role](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy_document) | data source |
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

## Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| name | Cluster name. Also prefixes the IAM roles, the Karpenter discovery tag and the default gateway EIP names. | `string` | n/a | yes |
| network | Existing VPC wiring, created upstream and never owned here.<br/>node\_subnet\_ids are the private subnets nodes launch into; pod\_subnet\_ids narrows the subnets Cilium<br/>allocates pod ENIs from (defaults to the node subnets); public\_subnet\_ids carry the Gateway's NLB and its reserved<br/>EIPs. manage\_discovery\_tags lets this module apply the karpenter.sh/discovery tag to those subnets — turn it off<br/>where the VPC owner tags them instead. | <pre>object({<br/>    vpc_id                = string<br/>    node_subnet_ids       = set(string)<br/>    pod_subnet_ids        = optional(set(string), [])<br/>    public_subnet_ids     = optional(set(string), [])<br/>    manage_discovery_tags = optional(bool, true)<br/>  })</pre> | n/a | yes |
| platform\_registry | Where the cluster consumes charts, images and the manifests artifact from. Pass a module output rather than<br/>composing this by hand — `module.cache.platform_registry` (a pull-through cache in the cluster's own account, the<br/>default posture) or `module.store.platform_registry` (reading a central store directly, which additionally requires<br/>the store to admit this cluster's registry\_reader\_principals). Both modules emit exactly this shape, so the<br/>is\_pull\_through\_cache flag is never guessed.<br/><br/>url is <account>.dkr.ecr.<region>.amazonaws.com/<prefix>. is\_pull\_through\_cache adds ecr:CreateRepository and<br/>ecr:BatchImportUpstreamImage to every puller's grant — a cache materialises each repository on its FIRST pull, so<br/>without them the first image pull of a fresh cluster fails. | <pre>object({<br/>    url                   = string<br/>    is_pull_through_cache = bool<br/>  })</pre> | n/a | yes |
| signed\_identity | Cosign verification identity for every platform artifact — exactly one of two modes.<br/><br/>KEYLESS (subjects set, kms\_key\_arn null): Go regexps matched against the Fulcio certificate of GitHub Actions OIDC<br/>signatures. The artifact-store module's signed\_identity\_subjects output provides the subjects; the issuer default<br/>matches GitHub Actions. Cloud agnostic — the signing identities are GitHub's, not AWS's, so the same values serve<br/>clusters on any cloud.<br/><br/>KMS (kms\_key\_arn set, subjects null): the publish workflows sign with an asymmetric SIGN\_VERIFY KMS key<br/>(cosign sign --key awskms:///<arn>; the artifact-store module's signing\_kms\_key\_arn grants the publishers kms:Sign).<br/>The key's public half is distributed to the cluster as the flux-system cosign-pub Secret for the bootstrap verify<br/>patch, the ARN is published as the SIGNED\_IDENTITY\_KMS\_KEY cluster var, and kyverno's controllers get<br/>kms:GetPublicKey / kms:Verify to resolve it at admission time. | <pre>object({<br/>    issuer             = optional(string, "^https://token\\.actions\\.githubusercontent\\.com$")<br/>    manifests_subject  = optional(string)<br/>    containers_subject = optional(string)<br/>    kms_key_arn        = optional(string)<br/>  })</pre> | n/a | yes |
| addons | EKS add-ons. Everything AWS offers managed is taken managed, and only the rest reaches the cluster through flux.<br/>vpc-cni and kube-proxy are absent by construction — Cilium replaces both, and<br/>bootstrap\_self\_managed\_addons is off so EKS never installs them.<br/><br/>aws-secrets-store-csi-driver-provider bundles the Secrets Store CSI driver alongside the AWS provider, so only the<br/>secrets-store-sync-controller (the SecretSync CRD) remains a flux component. metrics-server is a COMMUNITY add-on:<br/>AWS supports its lifecycle, not the software. cert-manager and external-dns are community add-ons too but stay<br/>flux-managed on purpose — as add-ons they would pull images from AWS's registry, breaking the invariant that<br/>clusters never pull from a public registry and the Kyverno policy that enforces it. | <pre>map(object({<br/>    enabled              = optional(bool, true)<br/>    version              = optional(string)<br/>    configuration_values = optional(string)<br/>  }))</pre> | <pre>{<br/>  "aws-ebs-csi-driver": {},<br/>  "aws-secrets-store-csi-driver-provider": {},<br/>  "coredns": {},<br/>  "eks-node-monitoring-agent": {},<br/>  "eks-pod-identity-agent": {},<br/>  "metrics-server": {},<br/>  "snapshot-controller": {}<br/>}</pre> | no |
| cilium | The CNI. Cilium runs in ENI mode with the AWS VPC CNI never installed, so pods hold routable VPC addresses exactly as<br/>they would under vpc-cni, and kube-proxy is replaced by Cilium's eBPF datapath. This is the one chart terraform<br/>installs: it must exist before the first node can report Ready, so flux cannot own the bootstrap. The release is<br/>bootstrap-only (ignore\_changes) and the stack's cilium component adopts it afterwards.<br/><br/>operator\_pod\_identity moves the ENI permissions off the node role and onto a Pod Identity association. Off by<br/>default: in ENI mode the agent cannot report Ready until the operator has attached ENIs, but the pod-identity-agent<br/>addon only installs once nodes exist — a bootstrap cycle. Turn it on against a running cluster if the node-role<br/>grant is unacceptable. helm\_values is merged OVER the computed values for anything not modelled here. | <pre>object({<br/>    chart_version         = optional(string)<br/>    repository            = optional(string)<br/>    operator_pod_identity = optional(bool, false)<br/>    helm_values           = optional(any, {})<br/>  })</pre> | `{}` | no |
| cluster\_admin\_principals | IAM principal ARNs granted AmazonEKSClusterAdminPolicy through an access entry — the break-glass and CI identities.<br/>The creating principal is admitted automatically (bootstrap\_cluster\_creator\_admin\_permissions), so this is for<br/>everyone else. | `set(string)` | `[]` | no |
| cluster\_log\_types | Control-plane log streams shipped to CloudWatch Logs. | `set(string)` | <pre>[<br/>  "api",<br/>  "audit",<br/>  "authenticator"<br/>]</pre> | no |
| dns | Existing delegated Route53 hosted zone (created upstream; never owned here, so cluster destroy/recreate never<br/>touches the zone or its NS delegation). zone\_name enables the DNS/TLS surface: the external-dns + cert-manager<br/>grants and the DNS\_* / PATCHY\_DOMAIN cluster vars. host optionally narrows the served host below the zone apex. | <pre>object({<br/>    zone_name  = optional(string)<br/>    host       = optional(string)<br/>    acme_email = optional(string)<br/>  })</pre> | `{}` | no |
| encryption\_kms\_key\_arn | Optional customer-managed KMS key for Kubernetes secrets envelope encryption; null leaves EKS's default encryption in place. | `string` | `null` | no |
| flux | Flux bootstrap knobs. Chart repositories, the distribution registry and the sync url default onto platform\_registry;<br/>sync.ref picks the release channel (stable, staging, or edge for dev clusters tracking trunk -- pair edge with the<br/>manifests\_edge signing subject). | <pre>object({<br/>    operator_chart = optional(object({<br/>      repository = optional(string)<br/>      version    = optional(string)<br/>    }), {})<br/>    instance_chart = optional(object({<br/>      repository = optional(string)<br/>      version    = optional(string)<br/>    }), {})<br/>    distribution = optional(object({<br/>      version  = optional(string, "2.x")<br/>      registry = optional(string)<br/>      artifact = optional(string)<br/>    }), {})<br/>    sync = optional(object({<br/>      url      = optional(string)<br/>      ref      = optional(string, "stable")<br/>      path     = optional(string, "stack")<br/>      interval = optional(string, "5m")<br/>    }), {})<br/>    kustomize_patches = optional(list(any), [])<br/>    cluster_vars      = optional(map(string), {})<br/>    namespaces        = optional(list(string), [])<br/>  })</pre> | `{}` | no |
| gateway | The platform Gateway's static addresses. One Cilium Gateway materialises one LoadBalancer Service (an NLB), and every<br/>HTTPRoute hostname shares its address — so the EIPs are reserved once, one per public subnet the NLB spans, and new<br/>hosts are manifests-only. Reserving them here (default) keeps them outside the disposable cluster's lifecycle, so<br/>destroy/recreate serves the same addresses; alternatively reference existing allocations by id. | <pre>object({<br/>    reserve_static_ip = optional(bool, true)<br/>    allocation_ids    = optional(set(string), [])<br/>  })</pre> | `{}` | no |
| karpenter | Workload capacity, provisioned by Karpenter. Terraform owns the IAM roles, the interruption<br/>queue and the discovery tags; the chart and the EC2NodeClass/NodePool objects are a flux-manifests component,<br/>rendered from the KARPENTER\_* cluster vars this shape publishes (lists arrive comma-joined and are expanded with<br/>splitList, exactly as STACK\_COMPONENTS already is).<br/><br/>There is deliberately no min\_nodes: Karpenter scales from zero on pending pods and offers only ceilings<br/>(spec.limits). The cluster's floor is system\_node\_pool.min\_size. | <pre>object({<br/>    node_pool = optional(object({<br/>      name                 = optional(string, "default")<br/>      instance_categories  = optional(list(string), ["c", "m", "r"])<br/>      instance_families    = optional(list(string), [])<br/>      instance_sizes       = optional(list(string), ["large", "xlarge", "2xlarge"])<br/>      capacity_types       = optional(list(string), ["spot", "on-demand"])<br/>      architectures        = optional(list(string), ["amd64"])<br/>      ami_alias            = optional(string, "al2023@latest")<br/>      max_nodes            = optional(number, 20)<br/>      max_cpu              = optional(number, 64)<br/>      max_memory_gib       = optional(number, 256)<br/>      disk_size_gib        = optional(number, 100)<br/>      consolidation_policy = optional(string, "WhenEmptyOrUnderutilized")<br/>      consolidate_after    = optional(string, "1m")<br/>      expire_after         = optional(string, "720h")<br/>    }), {})<br/>  })</pre> | `{}` | no |
| kubernetes\_version | EKS control-plane version, e.g. 1.34. Null tracks whatever EKS defaults to at create and pins it in state. | `string` | `null` | no |
| observability | Where the otel-collector ships telemetry. CloudWatch and X-Ray in the cluster's own account always; amp\_endpoint<br/>optionally adds an Amazon Managed Prometheus remote-write target (and the aps:RemoteWrite grant that goes with it). | <pre>object({<br/>    amp_endpoint = optional(string)<br/>  })</pre> | `{}` | no |
| patchy | Patchy platform knobs. harnesses elects the agent harnesses the cluster runs, published as the AGENT\_HARNESSES<br/>cluster var -- it gates the chart's per-harness runners, the harness credential syncs, and the derived<br/>secret-reader Pod Identity roles (iam.tf); create the matching credential secrets with modules/secrets (same<br/>value there). claude.provider configures the model provider patchy's egress-broker terminates all<br/>claude-runner traffic against, published as the CLAUDE\_* cluster vars (CLAUDE\_PROVIDER, CLAUDE\_ANTHROPIC\_AUTH,<br/>CLAUDE\_BEDROCK\_REGION, CLAUDE\_BEDROCK\_REGION\_PREFIX, CLAUDE\_VERTEX\_REGION, CLAUDE\_VERTEX\_PROJECT\_ID,<br/>CLAUDE\_MODEL\_MAP). Keys are harness-scoped (CLAUDE\_*, not a generic PROVIDER\_*) and the knobs provider-prefixed<br/>(bedrock\_region, not a bare region) — clarity over brevity, mirroring the broker's own PATCHY\_BEDROCK\_* env names.<br/>When the provider is bedrock the broker's KSA additionally gets the Bedrock invoke grant (iam.tf).<br/>evaluation.enabled deploys the evaluation controller -- the evolve-facing remote-evaluation API plus the runners<br/>that execute submitted evaluation units -- published as the PATCHY\_EVALUATION cluster var. It requires sso (the API<br/>has no unauthenticated posture; evolve authenticates through dex as a public PKCE client) and at least one harness<br/>(the chart refuses an evaluation controller with zero enabled runners). | <pre>object({<br/>    harnesses = optional(set(string), ["claude"])<br/><br/>    # Harness-scoped: the model provider belongs to the claude runner alone.<br/>    # A future codex/copilot provider surface slots in as a sibling key<br/>    # (patchy.codex.provider) without renaming anything here.<br/>    claude = optional(object({<br/>      provider = optional(object({<br/>        name                  = optional(string, "anthropic") # anthropic | bedrock<br/>        anthropic_auth        = optional(string, "token")     # key | token<br/>        bedrock_region        = optional(string)              # defaults to the cluster region<br/>        bedrock_region_prefix = optional(string)              # inference-profile geo prefix (us/eu/apac)<br/>        model_map             = optional(map(string), {})     # canonical id -> provider model id<br/>      }), {})<br/>    }), {})<br/><br/>    evaluation = optional(object({<br/>      enabled = optional(bool, false)<br/>    }), {})<br/>  })</pre> | `{}` | no |
| public\_access | Public control-plane endpoint. Disabled by default, so the API is reachable only through the always-on private<br/>endpoint. When enabled, cidrs constrains who may reach the public endpoint; empty leaves it open to 0.0.0.0/0<br/>(PoC posture) — constrain it as soon as a stable egress CIDR exists. | <pre>object({<br/>    enable = optional(bool, false)<br/>    cidrs  = optional(set(string), [])<br/>  })</pre> | `{}` | no |
| rbac | Cluster RBAC subjects. Each role names an IAM principal (typically an IAM Identity Center permission-set role ARN)<br/>and the Kubernetes group its access entry maps to. The group names are published as RBAC\_GROUP\_<ROLE> cluster vars,<br/>which flux-manifests' rbac component binds Role/ClusterRoleBindings against — the manifests contract carries only<br/>group names, never the IAM subjects behind them. | <pre>object({<br/>    enabled = optional(bool, false)<br/>    groups = optional(object({<br/>      viewers    = optional(object({ principal_arn = string, group = optional(string, "platform:viewers") }))<br/>      developers = optional(object({ principal_arn = string, group = optional(string, "platform:developers") }))<br/>      devops     = optional(object({ principal_arn = string, group = optional(string, "platform:devops") }))<br/>      admins     = optional(object({ principal_arn = string, group = optional(string, "platform:admins") }))<br/>    }), {})<br/>  })</pre> | `{}` | no |
| secret\_prefix | Prefix for every Secrets Manager secret name the manifests stack syncs, published as the SECRET\_PREFIX cluster var.<br/>Lets multiple clusters share one account with distinct secrets; the modules/secrets instantiation (a durable<br/>root, holding the out-of-band credential secrets) must create them under the same prefix. Include the trailing<br/>separator (e.g. 'patchy-x-'); empty keeps the unprefixed names. | `string` | `null` | no |
| sso | Platform SSO: deploys dex as the OIDC identity provider and wires every elected relying party to it -- generated<br/>client pairs (sso.tf), the DEX\_CONNECTORS cluster var, and the human-facing HTTPRoutes. Upstream identity is<br/>arbitrary: connector declares the deployment's single upstream IdP -- which connector type a deployment federates<br/>isn't known ahead of time, but it only ever federates one --<br/>  - type: the dex connector type (oidc, saml, google, microsoft, github, ...), passed through verbatim, not<br/>    validated against dex's own supported list.<br/>  - id: the dex connector id, also the naming stem for the credential containers (dex-<id>-<field>) and env vars;<br/>    defaults to type -- set it when the type alone reads poorly (e.g. id = "okta" for an oidc connector).<br/>  - name: the display name shown on dex's login screen; defaults to the connector id when unset.<br/>  - config: the connector's own config: block, passed through near-verbatim (issuer, clientID, scopes,<br/>    claimMapping, adminEmail, ...) -- a redirectURI is injected by default (sso.tf) unless the caller sets one.<br/>    Values keep their native types (bools, lists, numbers) all the way into dex's rendered YAML, e.g.<br/>    fetchTransitiveGroupMembership = true stays a bool.<br/>  - secrets: the out-of-band credential fields this connector needs (default ["client-id", "client-secret"]).<br/>    Each field becomes a dex-<id>-<field> Secrets Manager container (modules/secrets, instantiated in a durable<br/>    root and fed this same sso value -- an OAuth client cannot be terraformed, so its credentials arrive out of<br/>    band) and a <ID>\_<FIELD> env var (uppercased, dashes -> underscores) dex expands<br/>    from its own process env at startup ($<ID>\_<FIELD>) -- reference it yourself, e.g.<br/>    config.clientID = "$GOOGLE\_CLIENT\_ID".<br/>Requires the DNS surface: the issuer and redirect URLs need the served domain.<br/>clients holds the per-client knobs for the generated relying-party pairs (keys: flux-web, patchy-status) -- today<br/>just version, the client secret's rotation counter (absent clients sit at 1): bump it to mint a new client secret;<br/>the raw dex-client-* secret and any config document embedding the same value rewrite in one apply, so the pair<br/>cannot drift (then restart dex: it reads client secrets from env at startup). | <pre>object({<br/>    enabled = optional(bool, false)<br/>    connector = optional(object({<br/>      id      = optional(string)<br/>      type    = string<br/>      name    = optional(string)<br/>      config  = optional(any, {})<br/>      secrets = optional(set(string), ["client-id", "client-secret"])<br/>    }))<br/>    clients = optional(map(object({<br/>      version = number<br/>    })), {})<br/>  })</pre> | `{}` | no |
| stack\_components | The flux-manifests optional-tier components (short names: flux-web, patchy) this cluster elects, published as the<br/>STACK\_COMPONENTS cluster var. The default elects the whole tier; electing none is explicit -- set []. dex is not<br/>elected here: it deploys exactly when sso is enabled, and without it the elected components still run, just with no<br/>SSO auth and no human-facing HTTPRoute (kubectl port-forward to reach). The core tier (kyverno, cert-manager,<br/>external-dns, gateway, rbac, karpenter) is not electable. | `set(string)` | <pre>[<br/>  "flux-web",<br/>  "patchy"<br/>]</pre> | no |
| system\_node\_pool | The always-on managed node group platform controllers pin to (label role=system): flux, kyverno, cert-manager,<br/>external-dns, karpenter and the rest. These counts are CLUSTER-WIDE totals, not per-zone.<br/>Sizing must fit the whole platform tier — Karpenter only provisions workload capacity, never this. | <pre>object({<br/>    instance_types = optional(list(string), ["m7i.large"])<br/>    capacity_type  = optional(string, "ON_DEMAND")<br/>    min_size       = optional(number, 2)<br/>    max_size       = optional(number, 4)<br/>    desired_size   = optional(number, 2)<br/>    disk_size_gib  = optional(number, 50)<br/>  })</pre> | `{}` | no |
| tags | Tags applied to every resource this module creates. | `map(string)` | `{}` | no |
| upgrade\_policy | EKS support policy. STANDARD ends support at the end of standard support; EXTENDED keeps a version supported (at<br/>extra cost) past that date. | `string` | `"STANDARD"` | no |
| workload\_identity | Namespace/service-account pairs the EKS Pod Identity associations bind to — the terraform <-> flux-manifests<br/>contract, cloud-neutral in shape so every cluster tracks the same manifests. Override only to follow a<br/>manifests change. | <pre>object({<br/>    external_dns = optional(object({<br/>      namespace       = optional(string, "external-dns")<br/>      service_account = optional(string, "external-dns")<br/>    }), {})<br/>    cert_manager = optional(object({<br/>      namespace       = optional(string, "cert-manager")<br/>      service_account = optional(string, "cert-manager")<br/>    }), {})<br/>    otel_collector = optional(object({<br/>      namespace       = optional(string, "otel-collector")<br/>      service_account = optional(string, "otel-collector")<br/>    }), {})<br/>    kyverno = optional(object({<br/>      namespace = optional(string, "kyverno")<br/>      # the controllers that fetch image signatures from the registry at<br/>      # admission/report time<br/>      service_accounts = optional(list(string), ["kyverno-admission-controller", "kyverno-reports-controller"])<br/>    }), {})<br/>    # NOT an ingress path: Cilium is the Gateway API implementation and owns all<br/>    # L7 routing. The AWS Load Balancer Controller exists only to turn the one<br/>    # Service type=LoadBalancer that Cilium's Gateway materialises into an NLB<br/>    # bound to the reserved EIPs. EKS's built-in legacy cloud provider could do<br/>    # that too, but AWS ships it critical fixes only and advises against new<br/>    # NLBs on it.<br/>    load_balancer = optional(object({<br/>      namespace       = optional(string, "aws-load-balancer-controller")<br/>      service_account = optional(string, "aws-load-balancer-controller")<br/>    }), {})<br/>    karpenter = optional(object({<br/>      namespace       = optional(string, "kube-system")<br/>      service_account = optional(string, "karpenter")<br/>    }), {})<br/>    # patchy's egress-broker terminates all claude-runner model traffic; when<br/>    # patchy.claude.provider is bedrock its KSA carries the Bedrock invoke grant<br/>    patchy_egress_broker = optional(object({<br/>      namespace       = optional(string, "patchy")<br/>      service_account = optional(string, "patchy-egress-broker")<br/>    }), {})<br/>    # extra KSAs the secrets-store-sync-controller runs as when materialising<br/>    # a consumer's SecretSync objects, beyond the pairs the SSO surface and<br/>    # the patchy election already derive (sso.tf / iam.tf)<br/>    secret_readers = optional(list(object({<br/>      namespace       = string<br/>      service_account = string<br/>    })), [])<br/>  })</pre> | `{}` | no |

## Outputs

| Name | Description |
| ---- | ----------- |
| arn | Cluster ARN. |
| ca\_certificate | Base64-encoded cluster CA certificate. |
| cilium | How Cilium is wired: the release terraform bootstraps (and the stack adopts), and where its ENI permissions live. |
| dns | Delegated zone wiring (null when dns.zone\_name is unset): zone name, hosted zone id, apex domain, served host and the zone's name servers. |
| endpoint | Control-plane endpoint (host for the helm/kubernetes providers). |
| flux | Flux bootstrap facts, including the exact cluster-vars contract this cluster publishes to the stack. |
| gateway | The Gateway's static addresses — reserved here or referenced from existing allocations (null when neither). One Cilium Gateway shares these across every HTTPRoute host. |
| karpenter | Karpenter wiring the flux-manifests component renders its EC2NodeClass/NodePool from: the node role, the interruption queue and the subnet/security-group discovery tag. |
| kubernetes\_version | Current control-plane version. |
| name | Cluster name. |
| node\_iam\_role | The system node group's IAM role (name and ARN); Karpenter nodes use the separate karpenter role. |
| platform\_registry | The platform registry this cluster consumes from (pass-through of var.platform\_registry): its url and whether it is a pull-through cache. |
| rbac | Cluster RBAC subjects (null unless rbac.enabled): each role's IAM principal and the Kubernetes group its access entry maps onto, published as the RBAC\_GROUP\_* cluster vars flux-manifests binds against. |
| registry\_reader\_principals | Every identity that reads the platform registry (node roles, flux controllers, kyverno controllers). Covered automatically when platform\_registry is a pull-through cache in this account; feed these to the artifact-store module's direct\_pull\_principals when the cluster reads a central store directly instead. |
| sso | SSO secrets this cluster owns (null unless sso.enabled): the generated dex client secrets and the composed config documents. The out-of-band dex-<id>-<field> connector containers live in modules/secrets (a durable root), fed the same sso value. |
<!-- END_TF_DOCS -->