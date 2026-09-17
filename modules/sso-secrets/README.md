# sso-secrets

The out-of-band SSO credential containers the platform's dex component syncs into the cluster (Secrets Store CSI
driver + secrets-store-sync-controller). This is the terraform half of the platform's dex secret-sync contract - the
manifests' `SecretProviderClass`/`SecretSync` objects are the other half - so the container names live here,
versioned with the module release that tracks those manifests, instead of being hand-mirrored (and drifting) in every
caller.

Instantiate it from a **durable** root, not beside the cluster: the secret *versions* are added out of band
(`aws secretsmanager put-secret-value` - never terraform state) and must survive cluster destroy/recreate with no
manual re-entry.

**Containers only, deliberately no grants** - the inverse of the GKE sibling module. On EKS the read grant is
identity-side: the cluster module creates the sync KSAs' IRSA reader roles with
`GetSecretValue`/`DescribeSecret` scoped to `${SECRET_PREFIX}*` (`iam.tf`), so these secrets become readable the
moment the cluster exists. A durable-root resource policy naming those per-cluster role principals would invert the
lifecycle: `PutResourcePolicy` validates AWS principals, so the policy could not land before the cluster and would
break (principals reduce to orphaned unique ids) every time it churns.

The dex connector credentials ride the same `sso` declaration the cluster module publishes as `DEX_CONNECTORS`: pass
the cluster module's `sso` value verbatim and each connector's `secrets` fields become `dex-<id>-<field>` containers
here - an upstream OAuth client outlives any one cluster, so its credentials must too.

**Application credentials are not this module's business.** Each application's own module (composed in the root
beside the cluster module, e.g. `patchy-app-manifests//modules/aws`) creates its containers under the same
`secret_prefix`; the cluster module's generic `workload_identity.secret_readers` input gives the application's sync
KSAs the reader roles. Before 4.0 this module was `modules/secrets` and carried patchy's containers.

| Secret | Created when | Holds |
| --- | --- | --- |
| `dex-<id>-<field>` | `sso.enabled`, per `sso.connector.secrets` field | The connector's upstream credential (e.g. an OAuth client id/secret) |

After the first apply, add a version to every secret:

```sh
aws secretsmanager put-secret-value --secret-id <name> --secret-string file://...
```

## Usage

```hcl
module "sso_secrets" {
  source = "github.com/bitwise-media-group/terraform-aws-eks-flux//modules/sso-secrets"

  # Mirror the cluster module call in the (separate, disposable) cluster root.
  secret_prefix = "platform-x-"
  sso = {
    enabled   = true
    connector = { type = "google" }
  }
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
| [aws_secretsmanager_secret.main](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/secretsmanager_secret) | resource |

## Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| secret\_prefix | Prefix for every secret name, matching the cluster module's secret\_prefix input (the manifests sync<br/><prefix><name>, so the two must move together - and the cluster module's reader roles scope their read grant to<br/>the same prefix). Lets multiple clusters share one account with distinct secrets -- each cluster then needs its<br/>own prefixed set and fresh out-of-band versions. Include the trailing separator (e.g. 'platform-x-'); null keeps<br/>the unprefixed names. | `string` | `null` | no |
| sso | Platform SSO election -- pass the cluster module's sso value verbatim (its attributes beyond enabled and the<br/>connector's id/type/secrets are dropped by type conversion). enabled mirrors the cluster's dex toggle and gates<br/>the connector containers; the connector's secrets names its out-of-band credential fields, creating one<br/>dex-<id>-<field> Secrets Manager container per field (id defaulting to type, matching the cluster module) --<br/>populate versions out of band (an OAuth client cannot be terraformed). On its own enabled creates nothing: no<br/>connector is declared by default. | <pre>object({<br/>    enabled = optional(bool, false)<br/>    connector = optional(object({<br/>      id      = optional(string)<br/>      type    = string<br/>      secrets = optional(set(string), ["client-id", "client-secret"])<br/>    }))<br/>  })</pre> | `{}` | no |
| tags | Tags applied to every secret. | `map(string)` | `{}` | no |

## Outputs

| Name | Description |
| ---- | ----------- |
| secrets | The created secrets, keyed by unprefixed name: the ARN and the (prefixed) Secrets Manager name, for wiring further<br/>IAM in the caller (e.g. a maintainer's PutSecretValue rotation grant). Every secret's versions are added out of<br/>band: aws secretsmanager put-secret-value --secret-id <name>. |
<!-- END_TF_DOCS -->
