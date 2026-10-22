# Capacity

The cluster has two kinds of capacity. A **system node group** is always on and carries the platform. **Karpenter**
provisions everything else on demand. `node_groups` adds static pools for the cases Karpenter can't express.

## The system node group

A managed node group labelled `role=system`. The platform controllers are pinned to it with `nodeSelector role=system`:
flux, kyverno, cert-manager, karpenter, coredns and the rest. That keeps them away from Karpenter's workload capacity,
so consolidation never evicts the controllers that run the cluster.

`system_node_group` sets its instance types, capacity type, size and disk. Its `min_size` is **the cluster's floor**,
since Karpenter has no minimum. Counts are cluster-wide totals, not per availability zone.

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
| Lifecycle | `ami_alias`, `consolidation_policy`, `consolidate_after`, `expire_after`                        | `al2023@latest` · `WhenEmptyOrUnderutilized` · `1m` · `720h`             |

There's deliberately no `min_nodes`. Karpenter scales from zero on pending pods and offers only ceilings
(`spec.limits`).

### Interruption handling

An SQS queue receives spot interruption warnings, rebalance recommendations, instance state changes and scheduled health
events from EventBridge. Karpenter drains a node when one of these arrives rather than losing it mid-flight. Only this
account's EventBridge rules can write to the queue, so nobody elsewhere can inject drain events by guessing its name.

### The controller's permissions

The controller role is scoped so a compromised controller can do little harm:

- It can launch only resources tagged as owned by **this** cluster.
- Discovery (instance types, subnets, security groups) and the EKS-published AMI ids in SSM are read-only lookups.
- `iam:PassRole` is limited to the Karpenter node role, and only to EC2. The controller can't launch instances with a
  more privileged identity.
- It manages the instance profile for its `EC2NodeClass` itself.

## Static node groups

`node_groups` adds managed node groups for what Karpenter can't express, such as nodes with extra security groups or
Windows nodes. Each goes through the [node-group](../modules/node-group.md) module, carries the Cilium bootstrap taint
(except on Windows) and joins through the shared Linux node role.

`WINDOWS_*` AMI types get a separate node role. An IAM principal can carry only one EKS access entry, and Windows nodes
join through `EC2_WINDOWS` while Linux nodes join through `EC2_LINUX`. The Windows role has the same managed policies
but no Cilium ENI grant, since Cilium has no Windows datapath.

## Node permissions

Every Linux node role carries three AWS managed policies:

- `AmazonEKSWorkerNodePolicy`
- `AmazonEC2ContainerRegistryPullOnly`: pull only, never the older `ReadOnly`, since nodes never write to the registry
- `AmazonSSMManagedInstanceCore`: Session Manager for break-glass access, without opening SSH

They deliberately don't carry `AmazonEKS_CNI_Policy`, the AWS VPC CNI's grant. Cilium's ENI permissions are attached
separately. See [Bootstrap order](bootstrap-order.md#why-ciliums-eni-permissions-sit-on-the-node-role).
