# flux-operator

The flux bootstrap chain: three helm releases take an empty cluster to a reconciling GitOps platform in one apply —
`flux-operator` (the operator and its CRDs), `cluster-inputs` (the local chart carrying the `cluster-vars` ConfigMap and
pre-created namespaces), and `flux-instance` (the `FluxInstance` the operator materialises controllers from).

The operator and instance releases are **bootstrap-only** (`ignore_changes`): the stack's flux component adopts both by
release name and follows the newest mirrored charts, so a flux-containers publish — never a terraform apply — upgrades
flux on a running cluster. `cluster-inputs` stays terraform-reconciled, so cluster-vars changes flow through applies.

Signature enforcement on the manifests artifact rides in as a kustomize patch on the generated `flux-system`
OCIRepository, since `FluxInstance.spec.sync` has no verify field.

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

No modules.

## Resources

| Name | Type |
| ---- | ---- |
| [aws_eks_pod_identity_association.flux](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/eks_pod_identity_association) | resource |
| [aws_iam_role.flux](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role) | resource |
| [aws_iam_role_policy.flux](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy) | resource |
| [helm_release.cluster_inputs](https://registry.terraform.io/providers/hashicorp/helm/latest/docs/resources/release) | resource |
| [helm_release.flux_instance](https://registry.terraform.io/providers/hashicorp/helm/latest/docs/resources/release) | resource |
| [helm_release.flux_operator](https://registry.terraform.io/providers/hashicorp/helm/latest/docs/resources/release) | resource |
| [aws_iam_policy_document.assume_role](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy_document) | data source |
| [aws_iam_policy_document.registry_read](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy_document) | data source |

## Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| cluster\_name | Name of the EKS cluster the Pod Identity associations are created on. | `string` | n/a | yes |
| distribution | Flux distribution: version constraint and the registry hosting the mirrored fluxcd controller images (and<br/>optionally the OCI artifact with the operator's manifests). | <pre>object({<br/>    version  = string<br/>    registry = string<br/>    artifact = optional(string)<br/>  })</pre> | n/a | yes |
| instance\_chart | flux-instance helm chart location (renders the FluxInstance CR; avoids the kubernetes\_manifest plan-time CRD<br/>problem). A null version installs the latest available at create and pins it in state. | <pre>object({<br/>    repository = string<br/>    version    = optional(string)<br/>  })</pre> | n/a | yes |
| operator\_chart | flux-operator helm chart location: the platform registry's charts/flux-operator, published by flux-containers<br/>(the artifact store must be populated before the first cluster bootstraps). A null version installs the latest<br/>available at create and pins it in state — later applies don't auto-upgrade. | <pre>object({<br/>    repository = string # e.g. oci://<registry>/charts<br/>    version    = optional(string)<br/>  })</pre> | n/a | yes |
| registry\_arn | ARN pattern covering every repository beneath the platform registry prefix; the controllers' read grants are scoped to it. | `string` | n/a | yes |
| signed\_identity | Cosign verification enforced on the generated flux-system OCIRepository, so an unsigned or tampered manifests<br/>artifact is never applied. Exactly one mode: keyless (issuer + manifests\_subject, Go regexps over the Fulcio<br/>certificate) or a signing key's public half (kms\_public\_key\_pem, distributed as the cosign-pub Secret the verify<br/>patch references — source-controller verifies against the public key and never calls the signing service). | <pre>object({<br/>    issuer             = optional(string)<br/>    manifests_subject  = optional(string)<br/>    kms_public_key_pem = optional(string)<br/>  })</pre> | n/a | yes |
| sync | Cluster sync source: the flux-manifests artifact in the platform registry and the path within it. | <pre>object({<br/>    url      = string # oci://<registry>/flux-manifests<br/>    ref      = string # channel tag (stable, staging) or exact version<br/>    path     = string # stack (the single entrypoint all clusters share)<br/>    interval = optional(string, "5m")<br/>  })</pre> | n/a | yes |
| cluster\_vars | The cluster-vars ConfigMap contents — every value the flux-manifests stack substitutes via<br/>postBuild.substituteFrom. | `map(string)` | `{}` | no |
| kustomize\_patches | Extra kustomize patches applied to the generated Flux instance objects, on top of the built-in controller<br/>nodeSelector and flux-system OCIRepository verify patches. | `list(any)` | `[]` | no |
| namespace | Namespace for the flux-operator and Flux controllers. | `string` | `"flux-system"` | no |
| namespaces | Namespaces pre-created by the cluster-inputs chart (e.g. workload namespaces that must exist before their secrets<br/>arrive out-of-band); flux kustomizations adopt them via server-side apply. | `list(string)` | `[]` | no |
| registry\_is\_pull\_through\_cache | Whether the platform registry is a pull-through cache. When set, the controllers also get ecr:CreateRepository and<br/>ecr:BatchImportUpstreamImage on the prefix — the first pull of any artifact is what materialises its repository. | `bool` | `true` | no |
| tags | Tags applied to the IAM roles and Pod Identity associations this module creates. | `map(string)` | `{}` | no |
| web\_config\_secret\_name | Name of a Secret in the namespace whose config.yaml key carries the Web Config API document for the Flux Status web<br/>UI (SSO, base URL). The operator hot-reloads it, so the Secret may arrive after bootstrap. Null runs the web server<br/>unconfigured (anonymous, defaults). | `string` | `null` | no |

## Outputs

| Name | Description |
| ---- | ----------- |
| namespace | Namespace the flux-operator and Flux controllers run in. |
| registry\_reader\_roles | IAM role ARNs the flux controllers assume through Pod Identity — the identities that read the platform registry. |
<!-- END_TF_DOCS -->