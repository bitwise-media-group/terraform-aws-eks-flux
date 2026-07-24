# registry-cache

An ECR pull-through cache of the platform artifact store, applied in a consuming team's own account and region. This is
the default way a cluster reaches the store: images come from a registry beside the nodes, and the store stays closed to
direct reads.

Its `platform_registry` output feeds straight into the cluster module and carries `is_pull_through_cache = true`, which
is what grants the cluster's pullers the `ecr:CreateRepository` + `ecr:BatchImportUpstreamImage` permissions a cache
needs — repositories here are materialised on their **first** pull.

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
| [aws_ecr_pull_through_cache_rule.platform](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/ecr_pull_through_cache_rule) | resource |
| [aws_ecr_repository_creation_template.cache](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/ecr_repository_creation_template) | resource |
| [aws_iam_policy.consumer](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_policy) | resource |
| [aws_iam_role.cache](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role) | resource |
| [aws_iam_role_policy.cache](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy) | resource |
| [aws_caller_identity.current](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/caller_identity) | data source |
| [aws_iam_policy_document.cache](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy_document) | data source |
| [aws_iam_policy_document.cache_assume_role](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy_document) | data source |
| [aws_iam_policy_document.consumer](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy_document) | data source |
| [aws_partition.current](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/partition) | data source |
| [aws_region.current](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/region) | data source |

## Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| upstream | The artifact store this caches. registry\_id and repository\_prefix come straight from the artifact-store module's<br/>registry\_id / repository\_prefix outputs; region is the store's region. The store must admit this account — which it<br/>does org-wide by default (aws:PrincipalOrgID), so no change there is needed to onboard. | <pre>object({<br/>    registry_id       = string<br/>    region            = string<br/>    repository_prefix = optional(string, "platform")<br/>  })</pre> | n/a | yes |
| kms\_key\_arn | Customer-managed KMS key for the cached repositories; null uses ECR's AES256 default. | `string` | `null` | no |
| name | Base name for the cache's IAM role and consumer policy (keep it short). | `string` | `"platform"` | no |
| repository\_prefix | Local repository prefix the cached artifacts appear under. Null mirrors the upstream prefix, so image paths are<br/>identical on both sides and a cluster moves between store and cache by swapping one variable — keep it that way<br/>unless the prefix is already taken in this registry. | `string` | `null` | no |
| tags | Tags applied to the IAM role, the consumer policy and every cached repository. | `map(string)` | `{}` | no |
| untagged\_expiry\_days | Days after which untagged cached manifests are deleted. They re-cache on the next pull, so this is a cost control rather than a retention policy. | `number` | `14` | no |

## Outputs

| Name | Description |
| ---- | ----------- |
| cache\_role\_arn | The role ECR assumes to fetch from the upstream store. |
| consumer\_policy\_arn | IAM policy granting pull (and first-pull cache fill) on the cached prefix. The cluster module composes its own equivalent grant, so attach this only to pullers outside it — CI runners, bastions. |
| platform\_registry | Feed straight into the cluster module's platform\_registry. is\_pull\_through\_cache is true, which is what adds<br/>ecr:CreateRepository and ecr:BatchImportUpstreamImage to every puller's grant — a cache materialises each<br/>repository on its first pull, so a cluster wired here without those permissions fails on its first image. |
| registry\_host | Registry hostname for docker/helm/crane login in this account. |
| repository\_prefix | Local repository prefix the cached artifacts appear under. |
| upstream\_registry\_url | The store registry this cache fills from. |
<!-- END_TF_DOCS -->