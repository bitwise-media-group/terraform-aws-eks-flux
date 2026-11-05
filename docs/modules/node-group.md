# node-group

!!! info "Called by the root, or beside an application"

    The root module calls this one for the system node group and for each `node_groups` entry; configure those
    through the cluster module's `system_node_group` and `node_groups` inputs. An application published from its own
    root calls it directly, beside [application](application.md), fed from the cluster's `application_target` output.
    See [Capacity for an application](../concepts/capacity.md#capacity-for-an-application).

One EKS managed node group behind a launch template the module owns.

```hcl
module "workers" {
  source = "../node-group"

  cluster_name              = aws_eks_cluster.main.name
  name                      = "workers"
  node_role_arn             = aws_iam_role.nodes.arn
  subnet_ids                = var.network.node_subnet_ids
  cluster_security_group_id = aws_eks_cluster.main.vpc_config[0].cluster_security_group_id

  instance_types     = ["m7i.xlarge"]
  min_size           = 1
  max_size           = 6
  desired_size       = 2
  security_group_ids = [aws_security_group.workers_extra.id]

  labels = { role = "workers" }

  tags = var.tags
}
```

## What it creates

| Resource              | Carries                                                                                                                                                                 |
| --------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `aws_launch_template` | What the managed-node-group API can't express: extra security groups, the gp3 root volume's size, IMDSv2, and (with `ami`) the custom image and its bootstrap user data |
| `aws_eks_node_group`  | Everything the API expresses directly: instance types, capacity type, scaling, labels, taints, AMI type, node auto-repair                                               |
| `terraform_data`      | The AMI mode (`eks` or `custom`), which replaces the group when it flips                                                                                                |

## How it works

**Security groups.** Extra `security_group_ids` attach next to the EKS-managed cluster security group. That group always
comes along, because nodes need it to reach the control plane.

**The root volume.** EKS picks the AMI for the `ami_type`, so the block-device mapping names that AMI family's root
device rather than discovering it. A custom `ami` is resolved by the module, so its root device is read off the image.

**IMDSv2 only**, with a hop limit of 2. That matches the EKS default, so containers (one hop through the bridge) can
still reach the node's metadata.

**The Cilium bootstrap taint.** `cilium_agent_taint` (on by default) prepends
`node.cilium.io/agent-not-ready=true:NoExecute` to `taints`, so nothing schedules on a new node until Cilium can give it
an address. The Cilium agent and operator tolerate every taint, and the operator lifts this one once the agent is ready.
`WINDOWS_*` groups never get it, because Cilium has no Windows datapath to lift it. Don't list the taint in `taints` as
well; the module refuses it. Turn `cilium_agent_taint` off only on a cluster whose CNI isn't Cilium.

**Node auto-repair** is on. Its health signals come from the `eks-node-monitoring-agent` add-on.

**Scaling.** Counts are cluster-wide totals, not per availability zone. The desired size is set once at creation, then
left to Kubernetes (`ignore_changes`).

**Replacement is destroy-then-create, on purpose.** Names are prefixes (the group and template get generated suffixes),
but neither resource sets `create_before_destroy`. Terraform forces `create_before_destroy` onto every dependency of a
resource that sets it. The group depends on the cluster, whose fixed name can't be created before its predecessor is
destroyed. So a cluster replacement would fail with "Cluster already exists with name". The cost is a capacity gap
during the rare forced replacement.

**Windows.** `WINDOWS_*` AMI types are supported. Pair them with a node role admitted through an `EC2_WINDOWS` access
entry. An IAM principal carries exactly one access entry, so Windows nodes need a role separate from the Linux one. The
cluster module handles this automatically for `node_groups`.

## Custom AMIs

`ami` runs a custom AL2023 image, such as a company's hardened "golden" image, instead of the one EKS picks for
`ami_type`. The two are mutually exclusive. Nothing about the image is assumed: you name who owns it, then either the
exact image or a name pattern.

```hcl
# Pinned: nodes only roll when the id changes.
ami = {
  owners = ["111122223333"]
  id     = "ami-0123456789abcdef0"
}

# Tracking: the newest image matching the pattern, following the cluster's version.
ami = {
  owners = ["111122223333"]
  name   = "acme-eks-{kubernetes_version}-*"
}
```

**Owners are required, and they are checked.** The image is looked up at plan time against `owners` (account ids, or
`self` / `amazon` / `aws-marketplace`). That applies to an explicit `id` too. An id from an unexpected account matches
nothing and fails the plan instead of launching an untrusted image.

**Name patterns.** `name` is an EC2 name filter (`*` wildcards) and the newest match wins. `{kubernetes_version}` is
replaced with the cluster's version, so a pattern that encodes the version follows the cluster through upgrades. A newer
matching image produces a new launch template version on the next apply, which means a rolling node update, just as an
`@latest` alias would. Pin an `id` to freeze the image. Make the pattern specific enough to select one architecture: the
lookup takes the single newest match, whatever instance types the group runs.

**Bootstrap.** EKS merges no bootstrap user data into a custom image, so the module renders it as a MIME multipart
document. The first part is a nodeadm `NodeConfig` carrying the cluster's name, API endpoint, certificate authority and
service CIDR (the `cluster_*` inputs, which the cluster module passes). Its kubelet flags register the group's labels
(`--node-labels`) and taints (`--register-with-taints`) at registration. EKS applies them afterwards as well, but only
the kubelet can guarantee that a taint such as Cilium's `agent-not-ready` is present before the first pod lands. Because
of this:

- Labels in the `kubernetes.io` / `k8s.io` namespaces are refused, other than `node.kubernetes.io/` and
  `kubelet.kubernetes.io/`. The NodeRestriction admission plugin stops a kubelet from applying them to itself.
- Changing a custom-AMI group's labels or taints changes its user data, so it rolls the nodes, where on an EKS AMI it
  would update them in place.

`user_data_parts` are added after the module's part. An `application/node.eks.aws` part (the default content type) is
another `NodeConfig` that nodeadm merges, for kubelet or containerd settings. Any other content type cloud-init
understands (`text/x-shellscript`, `text/cloud-config`, ...) runs through cloud-init. The module's own part always comes
first and can't be replaced.

**No AMI type.** With a custom image the node group sets no `ami_type` (EKS refuses one alongside a launch template that
names its own image) and reports `CUSTOM`.

**Encrypted images.** If the image's snapshots are encrypted with a customer-managed KMS key, the key's policy must let
the `AWSServiceRoleForAutoScaling` service-linked role use it. That role launches managed node group instances, and this
module can't grant it anything. The key belongs to whoever publishes the image.

### Switching between EKS and custom AMIs

EKS can't move a node group between an EKS AMI and a custom one in place. The module tracks which kind it runs
(`terraform_data.ami_mode`) and replaces the group when that changes, all in a single apply. Moving from one custom
image to another, by id or by a newer name match, is not a switch. That stays an ordinary rolling update.

The replacement is destroy-then-create, like every replacement here (see above). For an additional node group that's a
short capacity gap. For the **system group** it takes the platform tier down (flux, Karpenter, CoreDNS, the Cilium
operator) until the new group is up. Choose the system group's AMI kind when you create the cluster. To switch an
existing cluster without a gap, bridge it. Platform pods pin to the system group only by the `role=system` label, so a
temporary group carrying that label can hold them while the system group is replaced:

1. Add a bridge group sized for the platform tier, then apply:

   ```hcl
   node_groups = {
     system-bridge = {
       labels       = { role = "system" }
       ami          = { owners = ["111122223333"], name = "acme-eks-{kubernetes_version}-*" } # the target image
       min_size     = 2
       desired_size = 2
     }
   }
   ```

2. Set (or remove) `system_node_group.ami`, then apply. The system group is replaced, and its pods drain onto the
   bridge.
3. Remove `system-bridge`, then apply. The pods move back to the new system group as the bridge drains.

--8<-- "modules/node-group/README.md:tf-docs"
