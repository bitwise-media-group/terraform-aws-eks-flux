# application

One application published to an existing cluster's Flux instance from a root of its own - another state, another
repository, another team - with everything it needs outside the cluster. The cluster root never changes: the module
reads the cluster through the root's `application_target` output and creates the bootstrap-only seed
(`application-<name>`: the `ResourceSetInputProvider` + `ResourceSet` named `<name>-manifests`, the same local chart the
cluster root seeds its own applications with), a terraform-reconciled `application-<name>-inputs` release carrying the
`<name>-vars` ConfigMap and pre-created namespaces, the workload grants (IAM role `<cluster>-<key>` bound through Pod
Identity), the podless secret-sync reader roles (`<cluster>-secrets-<ns>-<sa>`, trusted through the cluster's IRSA
provider) and any node groups the application brings for its own pods (`<cluster>-<name>-<key>`).

```hcl
module "patchy" {
  source = "git::https://github.com/bitwise-media-group/terraform-aws-eks-flux.git//modules/application?ref=vX.Y.Z"

  name    = "patchy"
  cluster = data.terraform_remote_state.cluster.outputs.application_target

  image = {
    url    = "oci://<registry>/manifests/patchy"
    semver = "<1.0.0 >=0.1.0"
    verify = { subject = "^https://github\\.com/bitwise-media-group/patchy-app-manifests/.+$" }
  }

  vars           = { PATCHY_DOMAIN = "patchy.example.com" }
  namespaces     = ["patchy", "patchy-agents"]
  secret_readers = [{ namespace = "patchy", service_account = "patchy-secrets" }]
}
```

The root needs an `aws` provider in the cluster's account and region, and a `helm` provider pointed at the cluster (both
charts are local, so no registry credentials). Every name matches what the cluster root mints for an application it
seeds itself, so a collision fails loudly - helm refuses a release or object another release owns, IAM a duplicate role.
An application lives in the cluster root **or** in its own root, never both. Dex clients aren't here: the application
ships `DexClient` objects in its own image, and the platform's dex-client-controller registers them.

<!-- --8<-- [start:tf-docs] -->
<!-- BEGIN_TF_DOCS -->
## Requirements

| Name | Version |
| ---- | ------- |
| terraform | >= 1.11, < 2.0 |
| aws | >= 6.0, < 7.0 |
| helm | ~> 3.0 |

## Providers

| Name | Version |
| ---- | ------- |
| aws | >= 6.0, < 7.0 |
| helm | ~> 3.0 |

## Modules

| Name | Source | Version |
| ---- | ------ | ------- |
| node\_group | ../node-group | n/a |

## Resources

| Name | Type |
| ---- | ---- |
| [aws_eks_pod_identity_association.workload](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/eks_pod_identity_association) | resource |
| [aws_iam_role.secret_reader](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role) | resource |
| [aws_iam_role.workload](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role) | resource |
| [aws_iam_role_policy.secret_reader](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy) | resource |
| [aws_iam_role_policy.workload](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy) | resource |
| [helm_release.inputs](https://registry.terraform.io/providers/hashicorp/helm/latest/docs/resources/release) | resource |
| [helm_release.seed](https://registry.terraform.io/providers/hashicorp/helm/latest/docs/resources/release) | resource |
| [aws_caller_identity.current](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/caller_identity) | data source |
| [aws_iam_policy_document.irsa_assume_role](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy_document) | data source |
| [aws_iam_policy_document.pod_identity_assume_role](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy_document) | data source |
| [aws_iam_policy_document.secret_read](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy_document) | data source |
| [aws_partition.current](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/partition) | data source |
| [aws_region.current](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/region) | data source |

## Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| cluster | The cluster to publish to: pass the cluster root's application\_target output verbatim (through<br/>terraform\_remote\_state or any other channel) rather than composing it by hand.<br/>  - name: the EKS cluster name; prefixes every IAM role (<name>-<key>, <name>-secrets-<ns>-<sa>).<br/>  - namespace: the flux namespace the seed and vars live in.<br/>  - platform\_registry: the platform registry url (<account>.dkr.ecr.<region>.amazonaws.com/<prefix>); images<br/>    beneath it are listed and pulled with the flux controllers' Pod Identity.<br/>  - tree: the per-cloud tree the cluster syncs (flux.sync.path), the default image path ./deploy/<tree>.<br/>  - issuer: the keyless signing issuer, the default for image.verify.issuer; null on a KMS-keyed cluster.<br/>  - keyed: whether the cluster verifies with a KMS signing key (the cosign-pub Secret exists only then).<br/>  - oidc\_provider\_arn / oidc\_issuer: the cluster's IRSA OIDC provider and its issuer host (no scheme), which<br/>    the podless secret-sync reader roles trust.<br/>  - secret\_prefix: the SECRET\_PREFIX the readers' Secrets Manager grant is scoped to.<br/>  - node\_role\_arn / node\_subnet\_ids / cluster\_security\_group\_id: the Linux node role (admitted through the<br/>    cluster root's EC2\_LINUX access entry), the node subnets and the EKS-managed cluster security group that<br/>    node\_groups join with. Optional so an older application\_target still plans; node\_groups requires them. | <pre>object({<br/>    name              = string<br/>    namespace         = string<br/>    platform_registry = string<br/>    tree              = string<br/>    issuer            = optional(string)<br/>    keyed             = bool<br/>    oidc_provider_arn = string<br/>    oidc_issuer       = string<br/>    secret_prefix     = string<br/><br/>    node_role_arn             = optional(string)<br/>    node_subnet_ids           = optional(set(string), [])<br/>    cluster_security_group_id = optional(string)<br/>  })</pre> | n/a | yes |
| image | The application's manifest image, exactly as a cluster root applications entry (minus the dex clients that<br/>have moved to DexClient objects). Becomes one bootstrap-only seed: a ResourceSetInputProvider and ResourceSet<br/>named <name>-manifests that resolve the newest tag matching semver, verify the image's cosign signature and<br/>apply path from it as Kustomization <name>. The image ships the same two seed objects under flux/ and owns them<br/>from its first reconcile, so a new application release never needs a terraform apply; the seed is applied once<br/>and then ignored (ignore\_changes). Destroying the module uninstalls the seed and prunes the application.<br/>  - url: the image without a tag or digest. An ECR url must live under cluster.platform\_registry (the flux<br/>    controllers pull it with their Pod Identity and list its tags through the ECR API); any other registry is<br/>    listed and pulled generically, optionally with pull\_secret (a kubernetes.io/dockerconfigjson Secret in the<br/>    flux namespace that both the tag listing and the pull read).<br/>  - semver: the tag range the seed follows (default >=0.0.0); a range matching no tag prunes the application.<br/>  - path: the Kustomization path inside the image (default ./deploy/<cluster.tree>).<br/>  - depends\_on: platform Kustomizations the application waits for (default kyverno-policies).<br/>  - verify: keyless (subject, a Fulcio certificate-subject regexp; issuer defaults to cluster.issuer) XOR keyed<br/>    (the cosign-pub public-key Secret, KMS-keyed clusters only). | <pre>object({<br/>    url        = string<br/>    semver     = optional(string, ">=0.0.0")<br/>    path       = optional(string)<br/>    interval   = optional(string, "30m")<br/>    depends_on = optional(set(string), ["kyverno-policies"])<br/>    verify = object({<br/>      issuer  = optional(string)<br/>      subject = optional(string)<br/>      keyed   = optional(bool, false)<br/>    })<br/>    pull_secret = optional(string)<br/>    prune       = optional(bool, true)<br/>    wait        = optional(bool, true)<br/>    timeout     = optional(string, "5m")<br/>  })</pre> | n/a | yes |
| name | The application's short name: the seed release is application-<name>, the seed objects <name>-manifests, the<br/>Kustomization <name> and the vars ConfigMap <name>-vars, all in the cluster's flux namespace. Must not be seeded<br/>by the cluster root as well (an applications key there) - an application lives in exactly one root. | `string` | n/a | yes |
| namespaces | Namespaces created ahead of the application (e.g. so out-of-band secrets can land before Flux deploys into<br/>them), labelled app.kubernetes.io/managed-by: application-<name>; the image's kustomizations adopt them via<br/>server-side apply. A namespace the cluster root already pre-creates (flux.namespaces) cannot be listed here too. | `set(string)` | `[]` | no |
| node\_groups | Managed node groups the application brings with it, keyed by a short name: capacity Karpenter cannot express, such<br/>as a static pool of another architecture that only this application's pods tolerate. Each group is named<br/><name>-<key> (a name prefix, so a replacement never collides with the group it supersedes), joins with the<br/>cluster's Linux node role into its node subnets wearing the EKS-managed cluster security group, and takes the<br/>cluster root's node\_groups sizing arguments plus ami\_type (null is the EKS AL2023 default for the instance<br/>architecture; AL2023\_ARM\_64\_STANDARD for Graviton), labels and taints. Every group gets the Cilium<br/>agent-not-ready bootstrap taint exactly as the cluster root's groups do; add a taint of your own to keep other<br/>workloads off it. Linux only: Windows groups need the cluster root's windows node role. | <pre>map(object({<br/>    instance_types = optional(list(string), ["m7i.large"])<br/>    capacity_type  = optional(string, "ON_DEMAND")<br/>    min_size       = optional(number, 2)<br/>    max_size       = optional(number, 4)<br/>    desired_size   = optional(number, 2)<br/>    disk_size_gib  = optional(number, 50)<br/>    ami_type       = optional(string)<br/>    labels         = optional(map(string), {})<br/>    taints = optional(list(object({<br/>      key    = string<br/>      value  = optional(string)<br/>      effect = string<br/>    })), [])<br/>  }))</pre> | `{}` | no |
| secret\_readers | The KSAs the secrets-store-sync-controller runs as when materialising this application's SecretSync objects.<br/>Each pair gets a podless IRSA reader role <cluster.name>-secrets-<namespace>-<service\_account>, trusted by the<br/>cluster's OIDC provider and allowed to read every Secrets Manager secret under cluster.secret\_prefix - the role<br/>the manifests reach as ${SECRETS\_ROLE\_PREFIX}<namespace>-<service\_account>. A pair the cluster root already<br/>lists (workload\_identity.secret\_readers, or one the SSO surface derives) cannot be listed here too. | <pre>set(object({<br/>    namespace       = string<br/>    service_account = string<br/>  }))</pre> | `[]` | no |
| tags | Tags applied to the IAM roles and Pod Identity associations this module creates. | `map(string)` | `{}` | no |
| vars | The application's own substitution values, rendered as the <name>-vars ConfigMap in the flux namespace, which<br/>its Kustomization substitutes from beside cluster-vars. Terraform-reconciled (the inputs release), so changes<br/>flow through this root's applies. Keys must be SCREAMING\_SNAKE\_CASE, matching the substitution syntax. | `map(string)` | `{}` | no |
| workload\_grants | Workload IAM grants, keyed by a short name: each entry becomes one IAM role (<cluster.name>-<key>) carrying the<br/>given policy document, bound to its namespace/service-account pair through an EKS Pod Identity association -<br/>the same shape and role names as the cluster root's workload\_grants. Podless secret-sync readers can't bind<br/>through Pod Identity; list those under secret\_readers instead. | <pre>map(object({<br/>    namespace       = string<br/>    service_account = string<br/>    policy          = string<br/>  }))</pre> | `{}` | no |

## Outputs

| Name | Description |
| ---- | ----------- |
| namespace | The flux namespace the seed objects (<name>-manifests) and the <name>-vars ConfigMap live in. |
| node\_groups | Each node\_groups entry's actual node group name and ARN (the names carry generated suffixes). |
| oci\_provider | The OCIRepository provider the registry selected: aws under the platform prefix, generic elsewhere. |
| path | The resolved Kustomization path inside the image. |
| release | The bootstrap-only seed release (application-<name>) in the flux namespace. |
| secret\_reader\_roles | The podless secret-sync reader role ARNs, keyed <namespace>/<service\_account>. |
| tag\_provider | The tag-listing provider the registry selected: ECRArtifactTag under the platform prefix, OCIArtifactTag elsewhere. |
| workload\_roles | The Pod Identity-bound IAM role ARNs, keyed as workload\_grants - for roots that grant these identities further access. |
<!-- END_TF_DOCS -->
<!-- --8<-- [end:tf-docs] -->
