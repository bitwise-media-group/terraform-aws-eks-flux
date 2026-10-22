# node-group

!!! info "Internal submodule"

    The root module calls this one for the system node group and for each `node_groups` entry. You don't usually call
    it directly. Configure it through the cluster module's `system_node_group` and `node_groups` inputs.

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

| Resource              | Carries                                                                                                                   |
| --------------------- | ------------------------------------------------------------------------------------------------------------------------- |
| `aws_launch_template` | What the managed-node-group API can't express: extra security groups, the gp3 root volume's size, IMDSv2                  |
| `aws_eks_node_group`  | Everything the API expresses directly: instance types, capacity type, scaling, labels, taints, AMI type, node auto-repair |

## How it works

**Security groups.** Extra `security_group_ids` attach next to the EKS-managed cluster security group. That group always
comes along, because nodes need it to reach the control plane.

**The root volume.** EKS picks the AMI for the `ami_type`, so the block-device mapping names that AMI family's root
device rather than discovering it.

**IMDSv2 only**, with a hop limit of 2. That matches the EKS default, so containers (one hop through the bridge) can
still reach the node's metadata.

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

--8<-- "modules/node-group/README.md:tf-docs"
