# Capacity

The cluster has two kinds of capacity. A **system node group** is always on and carries the platform. **Karpenter**
provisions everything else on demand. `node_groups` adds static pools for the cases Karpenter can't express. An
application published from its own root brings [its own capacity](#capacity-for-an-application), if it needs any.

## The system node group

A managed node group labelled `role=system`. The platform controllers are pinned to it with `nodeSelector role=system`:
flux, kyverno, cert-manager, karpenter, coredns and the rest. That keeps them away from Karpenter's workload capacity,
so consolidation never evicts the controllers that run the cluster.

`system_node_group` sets its instance types, capacity type, size and disk. Its `min_size` is **the cluster's floor**,
since Karpenter has no minimum. Counts are cluster-wide totals, not per availability zone.

`system_node_group.ami` runs a custom AL2023 image instead of the EKS one: `owners` plus an `id` or a `name` pattern.
See [Custom AMIs](../modules/node-group.md#custom-amis). Switching an existing system group between the EKS AMI and a
custom one replaces it, which takes the platform tier down unless you
[bridge it](../modules/node-group.md#switching-between-eks-and-custom-amis).

## Karpenter

Karpenter isn't an EKS add-on: it's in neither the AWS nor the community catalogue. The only AWS-managed Karpenter is
EKS Auto Mode, which owns networking with the AWS VPC CNI and so can't run Cilium in ENI mode. Karpenter therefore
deploys as a platform component, with Terraform providing everything AWS-side.

| Terraform owns (`karpenter.tf`)                                         | flux-manifests owns                        |
| ----------------------------------------------------------------------- | ------------------------------------------ |
| The node role, its instance profile permissions and its access entry    | The karpenter chart                        |
| The controller role, bound by Pod Identity                              | The `EC2NodeClass` and default `NodePool`  |
| The SQS interruption queue and EventBridge rules                        | Rendering both from the `KARPENTER_*` vars |
| `karpenter.sh/discovery` tags on subnets and the cluster security group |                                            |
| The NodePool's _shape_ (`karpenter.node_pool`)                          |                                            |

This split keeps capacity policy with the rest of the cluster's shape, in Terraform, without Terraform ever applying a
custom resource whose CRD flux hasn't installed yet.

### The NodePool shape

`karpenter.node_pool` is published as `KARPENTER_*` cluster vars. Lists are comma-joined and expanded on the manifests
side with `splitList`.

| Group     | Inputs                                                                                          | Defaults                                                                 |
| --------- | ----------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------ |
| Selection | `instance_categories`, `instance_families`, `instance_sizes`, `capacity_types`, `architectures` | `c,m,r` · any family · `large`–`2xlarge` · spot then on-demand · `amd64` |
| Ceilings  | `max_nodes`, `max_cpu`, `max_memory_gib`, `disk_size_gib`                                       | 20 nodes · 64 vCPU · 256 GiB · 100 GiB disk                              |
| Lifecycle | `ami_alias` or `ami`, `consolidation_policy`, `consolidate_after`, `expire_after`               | `al2023@latest` · `WhenEmptyOrUnderutilized` · `1m` · `720h`             |

There's deliberately no `min_nodes`. Karpenter scales from zero on pending pods and offers only ceilings
(`spec.limits`).

### Custom AMIs for Karpenter

`karpenter.node_pool.ami` selects a custom AL2023 image instead of `ami_alias`. When it's set it wins, so the alias
default never needs clearing. The selection is published whole as `KARPENTER_AMI_SELECTOR_TERMS`, a JSON
`amiSelectorTerms` list, with `KARPENTER_AMI_FAMILY=AL2023` (Karpenter needs an explicit family for any selector other
than an alias). `KARPENTER_AMI_ALIAS` is then empty.

| `ami`             | Published terms                                                     | Resolved                                                   |
| ----------------- | ------------------------------------------------------------------- | ---------------------------------------------------------- |
| unset             | `[{"alias": "<ami_alias>"}]`                                        | By Karpenter, from the EKS-published SSM parameter         |
| `owners` + `id`   | `[{"id": "<id>"}]`                                                  | Pinned; the owner is checked at plan time                  |
| `owners` + `name` | `[{"name": "<name>", "owner": "<owner>"}, ...]`, one term per owner | By Karpenter at runtime: the newest match per architecture |

Karpenter forbids combining `id` with any other field in a term, so Terraform checks an id's owner itself and fails the
plan if the image isn't owned by `owners`. A name term is resolved by Karpenter, which drifts nodes onto a newer
matching image as it lands. That's the same lifecycle as `al2023@latest`, so one pattern can cover both architectures.
As in node groups, `{kubernetes_version}` in `name` is replaced with the cluster's version. Karpenter renders the
nodeadm bootstrap itself, so there's no `user_data_parts` here.

`kms_key_arns` names the customer-managed keys an encrypted image's snapshots use. The controller launches nodes as its
own role, so it's granted `Decrypt`, `DescribeKey`, `GenerateDataKeyWithoutPlaintext`, `ReEncrypt*` and `CreateGrant`
(for AWS resources only) on exactly those keys. The key's own policy must allow this as well.

### Interruption handling

An SQS queue receives spot interruption warnings, rebalance recommendations, instance state changes and scheduled health
events from EventBridge. Karpenter drains a node when one of these arrives rather than losing it mid-flight. Only this
account's EventBridge rules can write to the queue, so nobody elsewhere can inject drain events by guessing its name.

### The controller's permissions

The controller role is scoped so a compromised controller can do little harm:

- It can launch only resources tagged as owned by **this** cluster.
- Discovery (instance types, subnets, security groups, images) and the EKS-published AMI ids in SSM are read-only
  lookups.
- KMS access exists only for the keys named in `node_pool.ami.kms_key_arns`, and grants only for AWS resources.
- `iam:PassRole` is limited to the Karpenter node role, and only to EC2. The controller can't launch instances with a
  more privileged identity.
- It manages the instance profile for its `EC2NodeClass` itself.

## Static node groups

`node_groups` adds managed node groups for what Karpenter can't express, such as nodes with extra security groups or
Windows nodes. Each goes through the [node-group](../modules/node-group.md) module, carries the Cilium bootstrap taint
(the module's `cilium_agent_taint`, skipped on Windows) and joins through the shared Linux node role. A group can run a
custom AL2023 image through `ami` instead of `ami_type`. See [Custom AMIs](../modules/node-group.md#custom-amis).

`WINDOWS_*` AMI types get a separate node role. An IAM principal can carry only one EKS access entry, and Windows nodes
join through `EC2_WINDOWS` while Linux nodes join through `EC2_LINUX`. The Windows role has the same managed policies
but no Cilium ENI grant, since Cilium has no Windows datapath.

## Capacity for an application

[`modules/application`](../modules/application.md) owns no nodes. An application that shares Karpenter's default pool
needs nothing more. One that needs dedicated capacity, such as another architecture or a pool only its pods tolerate,
picks one of two patterns.

### A managed node group beside the application

The application root calls [node-group](../modules/node-group.md) next to `modules/application`, fed from the same
`application_target` output. The output carries every node fact the module needs:

| `application_target` field                                     | `modules/node-group` input                                                                        |
| -------------------------------------------------------------- | ------------------------------------------------------------------------------------------------- |
| `name`                                                         | `cluster_name`                                                                                    |
| `node_role_arn`                                                | `node_role_arn`: the shared Linux node role, already admitted by the root's `EC2_LINUX` entry     |
| `node_subnet_ids`                                              | `subnet_ids`                                                                                      |
| `cluster_security_group_id`                                    | `cluster_security_group_id`                                                                       |
| `version`, `endpoint`, `certificate_authority`, `service_cidr` | `kubernetes_version`, `cluster_endpoint`, `cluster_certificate_authority`, `cluster_service_cidr` |

The last row only matters with a custom `ami`, whose nodeadm bootstrap the module renders. The module adds Cilium's
`agent-not-ready` bootstrap taint ahead of the group's own (`cilium_agent_taint`, on by default), exactly as the cluster
root's groups get it. Add a taint of your own to keep other workloads off the group. Groups are Linux only:
`application_target` publishes the Linux node role, and Windows nodes need the root's Windows role.

```hcl
module "node_group" {
  source = "git::https://github.com/bitwise-media-group/terraform-aws-eks-flux.git//modules/node-group?ref=vX.Y.Z"

  cluster_name              = local.cluster.name
  name                      = "patchy-arm64"
  node_role_arn             = local.cluster.node_role_arn
  subnet_ids                = local.cluster.node_subnet_ids
  cluster_security_group_id = local.cluster.cluster_security_group_id

  instance_types = ["m7g.large"]
  ami_type       = "AL2023_ARM_64_STANDARD"

  labels = { "example.com/pool" = "patchy-arm64" }
  taints = [{ key = "example.com/pool", value = "patchy-arm64", effect = "NO_SCHEDULE" }]
}
```

Here `local.cluster` is `data.terraform_remote_state.cluster.outputs.application_target`, the same value the application
module's `cluster` input takes. [`examples/application`](../getting-started/examples.md#application) shows both calls
together.

### A Karpenter NodePool in the application's manifests

The application ships its own Karpenter `NodePool` in its image, pointing `nodeClassRef` at the platform's
`EC2NodeClass default`. Karpenter launches its nodes with the platform's node role, subnets, security groups and AMI
selection, so the application root needs no capacity terraform at all. Give the `NodePool` its own requirements, taints
and `spec.limits`, and keep its name clear of the platform's own (`KARPENTER_NODE_POOL_NAME`, `default` unless
`karpenter.node_pool.name` changes it).

Prefer the `NodePool` when Karpenter can express the capacity: it scales from zero and consolidates. Use a node group
for what it can't, such as a fixed pool that must always be up.

## Node permissions

Every Linux node role carries three AWS managed policies:

- `AmazonEKSWorkerNodePolicy`
- `AmazonEC2ContainerRegistryPullOnly`: pull only, never the older `ReadOnly`, since nodes never write to the registry
- `AmazonSSMManagedInstanceCore`: Session Manager for break-glass access, without opening SSH

They deliberately don't carry `AmazonEKS_CNI_Policy`, the AWS VPC CNI's grant. Cilium's ENI permissions are attached
separately. See [Bootstrap order](bootstrap-order.md#why-ciliums-eni-permissions-sit-on-the-node-role).
