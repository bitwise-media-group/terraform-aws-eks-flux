# Identity & secrets

Every in-cluster workload that talks to AWS gets its own IAM role, bound to one namespace and service account. The
module mints those roles. The manifests only need to use the agreed service account names.

## Pod Identity for anything with a pod

Workloads with a real pod bind through **EKS Pod Identity associations**: no OIDC trust policies and no service account
annotations. The `eks-pod-identity-agent` add-on goes first among the add-ons, and the associations wait for it, so
nothing tries to get credentials before the agent exists.

### Platform grants

`workload_identity` holds the platform's namespace/service-account pairs. They're part of the Terraform ↔
platform-manifests contract, and their shape is cloud-neutral. Override them only to follow a manifests change.

| Pair (default)                                                 | Granted                                                                                   |
| -------------------------------------------------------------- | ----------------------------------------------------------------------------------------- |
| `external-dns/external-dns`                                    | Record changes on the delegated zone (only when DNS is configured)                        |
| `cert-manager/cert-manager`                                    | The same zone write, for DNS-01 challenges                                                |
| `otel-collector/otel-collector`                                | CloudWatch and X-Ray, plus `aps:RemoteWrite` when `observability.amp_endpoint` is set     |
| `kyverno/kyverno-admission-controller`, `…-reports-controller` | Platform registry read, plus KMS verify in KMS signing mode                               |
| `aws-load-balancer-controller/aws-load-balancer-controller`    | Provisioning the Gateway's NLB and binding its EIPs                                       |
| `kube-system/karpenter`                                        | The Karpenter controller policy (see [Capacity](capacity.md#the-controllers-permissions)) |

A few identities live next to the code they serve rather than in `iam.tf`:

- The flux controllers' registry read (`source-controller` and `flux-operator`) is in `modules/flux-operator/iam.tf`.
- Karpenter's controller role is in `karpenter.tf`.
- The Cilium operator's optional Pod Identity role is in `cilium.tf`.
- The EBS CSI driver uses the AWS managed `AmazonEBSCSIDriverPolicy` on `kube-system/ebs-csi-controller-sa`.

### Application grants

`workload_grants` carries grants for applications. It's a map of `{ namespace, service_account, policy }`, usually
emitted by the application's own module. Each entry becomes one role, `<cluster>-<key>`, with the policy JSON attached
inline and a Pod Identity association. The application module writes the policy (a model-invoke grant, a bucket, a
queue). This module only mints the role and binds it. An application published from its own root with
[`modules/application`](../modules/application.md) mints the same roles there instead.

## IRSA for podless secret syncs

The secrets-store-sync-controller is the one exception to Pod Identity. It materialises each `SecretSync` **without a
pod**, minting the sync service account's token through the TokenRequest API. A token with no pod behind it lacks the
`kubernetes.io/pod` claim that Pod Identity's `AssumeRoleForPodIdentity` requires, so an association could never be
used.

The podless path is IRSA instead. `AssumeRoleWithWebIdentity` needs only the service-account-scoped OIDC token. So:

1. The cluster's issuer is registered as an IAM OIDC provider.
2. Each reader pair gets a role named `<cluster>-secrets-<ns>-<sa>` that trusts only its own
   `system:serviceaccount:<ns>:<sa>` subject.
3. The role can call `GetSecretValue` / `DescribeSecret` on `${SECRET_PREFIX}*` only.
4. The manifests annotate each sync service account with `eks.amazonaws.com/role-arn: ${SECRETS_ROLE_PREFIX}<ns>-<sa>`.

Role names are deterministic, never `name_prefix`, so one published prefix covers every pair.

The reader pairs come from two places, merged together:

- pairs the SSO surface implies: `dex/dex-secrets` when `sso.enabled`, plus `flux-system/flux-web-secrets` when
  `flux-web` is elected too, and
- every pair in `workload_identity.secret_readers`, which is usually an application module's `secret_readers` output.

An application published from its own root lists its pairs in [`modules/application`](../modules/application.md)'s
`secret_readers` instead. That module mints the same `<cluster>-secrets-<ns>-<sa>` roles against the cluster's OIDC
provider (from the `application_target` output), so `${SECRETS_ROLE_PREFIX}<ns>-<sa>` resolves either way.

## Secret naming

`secret_prefix` namespaces every Secrets Manager name the platform syncs. The manifests read each secret as
`${SECRET_PREFIX}<name>`, so clusters sharing an account carry separate secrets. It's published as `SECRET_PREFIX`, or
an empty string when unset.

Secrets fall into two lifecycles:

| Secret                       | Created by                                                  | Lifecycle                                                 |
| ---------------------------- | ----------------------------------------------------------- | --------------------------------------------------------- |
| `dex-client-<id>`            | the cluster module (`sso.tf`), platform clients only        | The cluster's: generated, never entered by hand           |
| `flux-web-auth-config`       | the cluster module (`sso.tf`)                               | The cluster's: composed from the `flux-web` client secret |
| `dex-<id>-<field>`           | [sso-secrets](../modules/sso-secrets.md), in a durable root | Durable: values added out of band, kept across rebuilds   |
| an application's own secrets | the application's module                                    | The application module's choice                           |

### Generated client secrets

The confidential dex client secrets are internal shared secrets that live and die with the cluster. Each value is an
**ephemeral** `random_password` written through write-only attributes. It exists in Secrets Manager and nowhere else:
not in state, not in a plan file. Bumping a client's `version` makes the next apply read a fresh value.

Each generated secret also has a resource policy naming exactly who can read it. That narrows access from the other
direction: a secret and the readers allowed to see it are declared, and deleted, together.

None of the module's secrets have a recovery window. A deleted secret disappears immediately, instead of sitting in a
30-day scheduled-deletion state that would block recreating the cluster under the same names.

## SSO

`sso.enabled` deploys the platform's dex component, which federates to whatever upstream identity provider
`sso.connector` declares. The module:

- normalises the connector (defaulting its `id` and `name`, injecting the shared redirect URI) and publishes the
  non-secret half as `DEX_CONNECTORS`
- registers the platform's relying parties in `DEX_CLIENTS`: `flux-web` when elected and the public kubectl client when
  `sso.kubectl` is on. Applications register their own clients as `DexClient` objects; see
  [Applications](applications.md#dex-clients)
- mints a `dex-client-<id>` secret for each confidential client
- composes `flux-web-auth-config`, the flux-operator Web Config document with the client secret inline, from the same
  ephemeral value, so the two can't drift

The connector's own credentials (an upstream OAuth client id and secret, say) outlive any cluster. They live in
[sso-secrets](../modules/sso-secrets.md), which you instantiate in a durable root with the same `sso` value.

### kubectl through dex

With `sso.kubectl.enabled`, the module creates an EKS identity provider config that trusts
`https://dex.<PLATFORM_DOMAIN>`. Humans then authenticate with kubectl through the upstream connector, using kubelogin's
OIDC/PKCE flow. They don't need an IAM principal. The kubectl client is public, so it has no secret. See
[Bootstrap order](bootstrap-order.md#steps-that-need-a-second-apply) for why this needs a second apply.

## RBAC

With `rbac.enabled`, each role in `rbac.groups` (`viewers`, `developers`, `devops`, `admins`) names a Kubernetes group
(defaulting to `platform:<role>`) and, optionally, an IAM principal such as an IAM Identity Center permission-set role:

- A role with a principal gets an EKS access entry mapping that principal onto the group.
- A role bound only through OIDC needs no access entry. dex asserts the group in its `groups` claim, which the identity
  provider config resolves.
- A role can use both, if the IAM principal's group and the dex-asserted group have the same literal name.

The group names reach the manifests as `RBAC_GROUP_VIEWERS`, `RBAC_GROUP_DEVELOPERS`, `RBAC_GROUP_DEVOPS` and
`RBAC_GROUP_ADMINS`. The platform's rbac component binds roles to whatever names arrive, and never sees whether an IAM
principal or a dex group is behind them.
