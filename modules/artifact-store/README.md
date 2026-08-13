# artifact-store

The central platform artifact store on ECR: one repository prefix holding every artifact the clusters consume, plus the
GitHub Actions publishers allowed to write to it.

ECR has no arbitrary-path model, so a **repository creation template with `CREATE_ON_PUSH`** is what makes the layout
work — publishers push to a path that does not exist yet and ECR creates the repository with the template's lifecycle
policy, tag mutability, encryption and tags. Without a matching template ECR refuses to create on push at all.

Reads are granted **org-wide** to the ECR pull-through cache service (`aws:PrincipalOrgID`), not per account, so a new
cluster account onboards by applying `modules/registry-cache` there rather than by editing this module.

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
| [aws_ecr_registry_policy.platform](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/ecr_registry_policy) | resource |
| [aws_ecr_registry_scanning_configuration.platform](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/ecr_registry_scanning_configuration) | resource |
| [aws_ecr_repository_creation_template.platform](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/ecr_repository_creation_template) | resource |
| [aws_iam_openid_connect_provider.github](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_openid_connect_provider) | resource |
| [aws_iam_role.creation](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role) | resource |
| [aws_iam_role.publisher](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role) | resource |
| [aws_iam_role_policy.creation](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy) | resource |
| [aws_iam_role_policy.publisher](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy) | resource |
| [aws_caller_identity.current](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/caller_identity) | data source |
| [aws_iam_policy_document.creation](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy_document) | data source |
| [aws_iam_policy_document.creation_assume_role](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy_document) | data source |
| [aws_iam_policy_document.publisher](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy_document) | data source |
| [aws_iam_policy_document.publisher_assume_role](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy_document) | data source |
| [aws_partition.current](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/partition) | data source |
| [aws_region.current](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/region) | data source |

## Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| organization\_id | AWS Organizations id (o-xxxxxxxxxx). Every account in the organization may pull through an ECR pull-through cache,<br/>matched by aws:PrincipalOrgID rather than an account list — so onboarding a new cluster account needs no change<br/>here. Narrow it with organization\_paths if the whole org is too broad. | `string` | n/a | yes |
| additional\_registry\_statements | Extra IAM statements merged into the ECR registry policy. ECR allows exactly one registry policy per account per<br/>region and this module owns it, so an account using registry policies for anything else must pass those statements<br/>here rather than declaring a second resource. | `list(any)` | `[]` | no |
| direct\_pull\_principals | IAM principals allowed to pull from the store DIRECTLY rather than through a pull-through cache — the escape hatch<br/>for clusters the platform team lets read it straight. Feed a cluster module's registry\_reader\_principals output<br/>through here. Content security is cosign verification, not read denial, so coarse principals are acceptable. | `list(string)` | `[]` | no |
| enhanced\_scanning | Turn on ECR enhanced (Inspector) continuous scanning for the platform prefix. Registry-scoped by construction, so<br/>leave it off where another owner manages the registry's scanning configuration. | `bool` | `true` | no |
| github | GitHub org and repository names the publisher trust is pinned to, plus the immutable numeric ids GitHub embeds in<br/>the OIDC subjects of post-2026-07-15 repos (org\_id from GET /orgs/<org>, repo ids from GET /repos/<org>/<repo>).<br/>manifests\_id may stay null until that repo exists on GitHub. | <pre>object({<br/>    org           = optional(string, "bitwise-media-group")<br/>    org_id        = optional(number, 282673588)<br/>    containers    = optional(string, "flux-containers")<br/>    containers_id = optional(number, 1303643498)<br/>    manifests     = optional(string, "flux-manifests")<br/>    manifests_id  = optional(number)<br/>  })</pre> | `{}` | no |
| github\_oidc\_thumbprints | Certificate thumbprints for the GitHub Actions OIDC provider, used only when this module creates it. IAM no longer<br/>validates these for well-known issuers, so the value is a formality kept explicit rather than implicit. | `list(string)` | <pre>[<br/>  "6938fd4d98bab03faadb97b34396831e3780aea1"<br/>]</pre> | no |
| kms\_key\_arn | Customer-managed KMS key for repository encryption; null uses ECR's AES256 default. | `string` | `null` | no |
| name | Base name for the publisher and repository-creation IAM roles (keep it short). | `string` | `"platform"` | no |
| oidc\_provider\_arn | ARN of an existing GitHub Actions OIDC provider in this account. Null creates one here — convenient for a<br/>standalone store, but an account that already has one (or gets one from a cloud-accounts aws environment) must pass<br/>it, since IAM permits only a single provider per issuer URL. | `string` | `null` | no |
| organization\_paths | Optional aws:PrincipalOrgPaths patterns narrowing the pull-through grant to particular organizational units, e.g.<br/>["o-abc123/r-root/ou-workloads/*"]. Empty admits the whole organization. | `list(string)` | `[]` | no |
| promotion\_environment | GitHub environment (protected, reviewer-gated) whose jobs may move the stable channel tag. | `string` | `"production"` | no |
| repository\_prefix | ECR repository name prefix everything lands beneath: charts at <prefix>/charts/<name>, images at<br/><prefix>/images/<original-path>, and the manifests artifact at <prefix>/flux-manifests. The creation template is<br/>keyed on this prefix, so it is also what makes create-on-push work. | `string` | `"platform"` | no |
| signing\_kms\_key\_arn | Asymmetric SIGN\_VERIFY KMS key the publish workflows sign artifacts with (cosign sign --key awskms:///<arn>),<br/>instead of keyless Fulcio identities. When set, both publisher roles get kms:Sign / kms:GetPublicKey /<br/>kms:DescribeKey on the key; feed the same ARN to the cluster module's signed\_identity.kms\_key\_arn so verification<br/>matches. Null keeps signing keyless (the signed\_identity\_subjects output). The key itself lives outside this<br/>module — signing identity should outlive any one store. | `string` | `null` | no |
| tags | Tags applied to the IAM roles and to every repository the creation template makes. | `map(string)` | `{}` | no |
| untagged\_expiry\_days | Days after which untagged manifests (failed/superseded pushes) are deleted. | `number` | `14` | no |

## Outputs

| Name | Description |
| ---- | ----------- |
| chart\_publisher | Chart publisher role (the role-to-assume input of aws-actions/configure-aws-credentials in flux-containers, set as the AWS\_CHART\_PUBLISHER\_ROLE org variable). |
| chart\_repository\_prefix | OCI prefix mirrored charts are published under (charts/<name> appended per chart). |
| image\_repository\_prefix | Registry prefix mirrored images are published under (images/<original-path> appended per image). |
| manifest\_artifact\_url | OCI url of the flux-manifests artifact the clusters sync. |
| manifest\_publisher | Manifest publisher role (the role-to-assume input of aws-actions/configure-aws-credentials in flux-manifests, set as the AWS\_MANIFEST\_PUBLISHER\_ROLE org variable). |
| oidc\_provider\_arn | The GitHub Actions OIDC provider the publishers federate through — created here or passed in. |
| platform\_registry | Feed straight into the cluster module's platform\_registry. is\_pull\_through\_cache is false because this IS the store<br/>— a cluster wired here reads it directly, which additionally requires its registry\_reader\_principals to appear in<br/>this module's direct\_pull\_principals. Most clusters should point at a registry-cache module's output instead. |
| registry\_host | Registry hostname for docker/helm/crane login (AWS/ecr get-login-password). |
| registry\_id | Account id owning the registry — the upstream\_registry\_id a registry-cache module points at. |
| repository\_prefix | The repository name prefix everything lands beneath, and the prefix the creation template is keyed on. |
| signed\_identity\_subjects | Fulcio certificate-subject regexps for the publishing workflows (keyless mode) — feed these to the cluster module's signed\_identity variable. Cloud-agnostic: the signer is GitHub, not the hosting cloud. Irrelevant when signing\_kms\_key\_arn selects KMS signing. |
| signing\_kms\_key\_arn | The KMS signing key the publishers sign with (null in keyless mode) — feed it to the cluster module's signed\_identity.kms\_key\_arn so verification matches. |
<!-- END_TF_DOCS -->