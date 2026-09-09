# node-group

One EKS managed node group behind a module-owned launch template. The launch template carries what the
managed-node-group API alone cannot express - additional security groups attached alongside the EKS-managed cluster
security group (which always rides along for control-plane reachability), the gp3 root volume's size, and IMDSv2
enforcement - while everything the API expresses directly (instance types, capacity type, scaling, labels, taints)
stays on the node group itself.

Names are prefixes (the node group and launch template get generated suffixes), but replacement is destroy-then-create
on purpose: Terraform forces `create_before_destroy` onto every dependency of a resource that sets it, and the group
depends on the cluster, whose fixed name cannot be created before its predecessor is destroyed. The desired size is set
once at create and then left to Kubernetes (`ignore_changes`).

`WINDOWS_*` AMI types are supported; pair them with a node role admitted through an `EC2_WINDOWS` access entry (an IAM
principal carries exactly one access entry, so Windows nodes need a role separate from the Linux one).

## Usage

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

<!-- BEGIN_TF_DOCS -->
## Requirements

| Name | Version |
| ---- | ------- |
| terraform | >= 1.11, < 2.0 |
| aws | >= 6.0, < 7.0 |

## Providers

| Name | Version |
| ---- | ------- |
| aws | >= 6.0, < 7.0 |

## Modules

No modules.

## Resources

| Name | Type |
| ---- | ---- |
| [aws_eks_node_group.main](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/eks_node_group) | resource |
| [aws_launch_template.main](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/launch_template) | resource |

## Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| cluster\_name | Name of the EKS cluster the node group joins. | `string` | n/a | yes |
| cluster\_security\_group\_id | The EKS-managed cluster security group. Always attached - without it nodes cannot reach the control plane. | `string` | n/a | yes |
| name | Node group name stem. Used as a name prefix, so a replacement never collides with the group it supersedes. | `string` | n/a | yes |
| node\_role\_arn | IAM role the nodes run as. Its access entry type (EC2\_LINUX / EC2\_WINDOWS) must match ami\_type's OS family. | `string` | n/a | yes |
| subnet\_ids | Subnets the nodes launch into. | `set(string)` | n/a | yes |
| ami\_type | EKS AMI type. Null takes the EKS default for the instance architecture (AL2023). WINDOWS\_* types launch Windows<br/>nodes - pair them with a node role admitted through an EC2\_WINDOWS access entry. Bottlerocket is deliberately<br/>unsupported: its two-volume layout (a separate data volume) does not fit the single root device this module's<br/>launch template sizes. | `string` | `null` | no |
| capacity\_type | ON\_DEMAND or SPOT capacity. | `string` | `"ON_DEMAND"` | no |
| desired\_size | Initial node count. Set once at create and never argued about again (ignore\_changes) - the count is Kubernetes' to<br/>move on a live cluster. | `number` | `2` | no |
| disk\_size\_gib | Root volume size in GiB (gp3), set through the launch template. | `number` | `50` | no |
| instance\_types | Instance types the node group launches, in preference order. | `list(string)` | <pre>[<br/>  "m7i.large"<br/>]</pre> | no |
| labels | Kubernetes labels applied to every node in the group. | `map(string)` | `{}` | no |
| max\_size | Maximum node count (cluster-wide total, not per-zone). | `number` | `4` | no |
| min\_size | Minimum node count (cluster-wide total, not per-zone). | `number` | `2` | no |
| security\_group\_ids | Additional security groups the launch template attaches alongside the cluster security group. | `set(string)` | `[]` | no |
| tags | Tags applied to every resource this module creates (and, via the launch template, to the instances and volumes). | `map(string)` | `{}` | no |
| taints | Kubernetes taints applied to every node in the group. | <pre>list(object({<br/>    key    = string<br/>    value  = optional(string)<br/>    effect = string<br/>  }))</pre> | `[]` | no |

## Outputs

| Name | Description |
| ---- | ----------- |
| arn | Node group ARN. |
| labels | Kubernetes labels every node in the group carries - the selectors workloads pin with. |
| launch\_template | The module-owned launch template behind the node group (id and current version). |
| name | The node group's actual name (the name stem plus the generated suffix). |
| security\_group\_ids | Security groups the launch template attaches to the nodes (the cluster security group plus any extras). |
| taints | Kubernetes taints every node in the group carries. |
<!-- END_TF_DOCS -->
