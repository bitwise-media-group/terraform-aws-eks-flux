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

<!-- --8<-- [start:tf-docs] -->
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
| terraform | n/a |

## Modules

No modules.

## Resources

| Name | Type |
| ---- | ---- |
| [aws_eks_node_group.main](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/eks_node_group) | resource |
| [aws_launch_template.main](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/launch_template) | resource |
| [terraform_data.ami_mode](https://registry.terraform.io/providers/hashicorp/terraform/latest/docs/resources/data) | resource |
| [aws_ami.custom](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/ami) | data source |

## Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| cluster\_name | Name of the EKS cluster the node group joins. | `string` | n/a | yes |
| cluster\_security\_group\_id | The EKS-managed cluster security group. Always attached - without it nodes cannot reach the control plane. | `string` | n/a | yes |
| name | Node group name stem. Used as a name prefix, so a replacement never collides with the group it supersedes. | `string` | n/a | yes |
| node\_role\_arn | IAM role the nodes run as. Its access entry type (EC2\_LINUX / EC2\_WINDOWS) must match ami\_type's OS family. | `string` | n/a | yes |
| subnet\_ids | Subnets the nodes launch into. | `set(string)` | n/a | yes |
| ami | A custom AL2023 AMI in place of the EKS-published one picked by ami\_type (the two are mutually exclusive). The<br/>image is resolved at plan time and must be owned by one of owners (account ids, or self / amazon /<br/>aws-marketplace) - this check also applies to an explicit id, so an image from an unexpected account fails the plan.<br/>Set exactly one of:<br/>  - id: the exact image id. Pins the image - nodes only roll when the id changes.<br/>  - name: an EC2 name filter (* wildcards), with the newest match taking effect. "{kubernetes\_version}" is<br/>    replaced by kubernetes\_version, so a pattern such as "acme-eks-{kubernetes\_version}-*" follows the<br/>    cluster through upgrades. A newer matching image produces a new launch template version - and a rolling node<br/>    update - on the next apply.<br/>EKS merges no bootstrap user data into a custom image, so the module renders it: a nodeadm NodeConfig (cluster<br/>endpoint, certificate authority and service CIDR) whose kubelet flags register the group's labels and taints, so<br/>a taint such as Cilium's agent-not-ready is present the moment the node registers. user\_data\_parts are appended<br/>to that MIME document - extra NodeConfigs (application/node.eks.aws, merged by nodeadm) or any content type<br/>cloud-init understands (text/x-shellscript, text/cloud-config, ...).<br/>Switching between an EKS AMI and a custom one replaces the node group (destroy-then-create). | <pre>object({<br/>    owners = list(string)<br/>    id     = optional(string)<br/>    name   = optional(string)<br/>    user_data_parts = optional(list(object({<br/>      content_type = optional(string, "application/node.eks.aws")<br/>      content      = string<br/>    })), [])<br/>  })</pre> | `null` | no |
| ami\_type | EKS AMI type. Null takes the EKS default for the instance architecture (AL2023). WINDOWS\_* types launch Windows<br/>nodes - pair them with a node role admitted through an EC2\_WINDOWS access entry. Bottlerocket is deliberately<br/>unsupported: its two-volume layout (a separate data volume) does not fit the single root device this module's<br/>launch template sizes. | `string` | `null` | no |
| capacity\_type | ON\_DEMAND or SPOT capacity. | `string` | `"ON_DEMAND"` | no |
| cilium\_agent\_taint | Prepend Cilium's bootstrap taint (node.cilium.io/agent-not-ready=true:NoExecute) to taints, so nothing schedules<br/>on a new node until Cilium can give it an address - the Cilium operator lifts the taint once the agent is ready.<br/>Ignored for WINDOWS\_* AMI types: Cilium has no Windows datapath, so the taint would never be lifted. Turn it off<br/>only on a cluster whose CNI is not Cilium. | `bool` | `true` | no |
| cluster\_certificate\_authority | The cluster's base64-encoded certificate authority data, rendered into a custom AMI's NodeConfig. Required when ami<br/>is set. | `string` | `null` | no |
| cluster\_endpoint | The cluster's API server endpoint, rendered into a custom AMI's NodeConfig. Required when ami is set. | `string` | `null` | no |
| cluster\_service\_cidr | The cluster's Kubernetes service CIDR, rendered into a custom AMI's NodeConfig. Required when ami is set. | `string` | `null` | no |
| desired\_size | Initial node count. Set once at create and never argued about again (ignore\_changes) - the count is Kubernetes' to<br/>move on a live cluster. | `number` | `2` | no |
| disk\_size\_gib | Root volume size in GiB (gp3), set through the launch template. | `number` | `50` | no |
| instance\_types | Instance types the node group launches, in preference order. | `list(string)` | <pre>[<br/>  "m7i.large"<br/>]</pre> | no |
| kubernetes\_version | The cluster's Kubernetes version (e.g. "1.33"), substituted for "{kubernetes\_version}" in ami.name. Required only<br/>when ami.name uses the placeholder. | `string` | `null` | no |
| labels | Kubernetes labels applied to every node in the group. With a custom ami the kubelet also registers them itself, so<br/>keys in the kubernetes.io / k8s.io namespaces are refused (the NodeRestriction admission plugin stops a kubelet<br/>from self-applying them) - except node.kubernetes.io/ and kubelet.kubernetes.io/, which it allows. | `map(string)` | `{}` | no |
| max\_size | Maximum node count (cluster-wide total, not per-zone). | `number` | `4` | no |
| min\_size | Minimum node count (cluster-wide total, not per-zone). | `number` | `2` | no |
| security\_group\_ids | Additional security groups the launch template attaches alongside the cluster security group. | `set(string)` | `[]` | no |
| tags | Tags applied to every resource this module creates (and, via the launch template, to the instances and volumes). | `map(string)` | `{}` | no |
| taints | Kubernetes taints applied to every node in the group, after the Cilium bootstrap taint (cilium\_agent\_taint). | <pre>list(object({<br/>    key    = string<br/>    value  = optional(string)<br/>    effect = string<br/>  }))</pre> | `[]` | no |

## Outputs

| Name | Description |
| ---- | ----------- |
| ami\_id | The custom AMI the group runs (ami), resolved to its image id; null when EKS picks the AMI for ami\_type. |
| arn | Node group ARN. |
| labels | Kubernetes labels every node in the group carries - the selectors workloads pin with. |
| launch\_template | The module-owned launch template behind the node group (id and current version). |
| name | The node group's actual name (the name stem plus the generated suffix). |
| security\_group\_ids | Security groups the launch template attaches to the nodes (the cluster security group plus any extras). |
| taints | Kubernetes taints every node in the group carries. |
<!-- END_TF_DOCS -->
<!-- --8<-- [end:tf-docs] -->
