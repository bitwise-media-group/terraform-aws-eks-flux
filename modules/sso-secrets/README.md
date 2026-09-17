# secrets

The out-of-band credential secrets the flux-manifests stack syncs into the cluster (Secrets Store CSI driver +
secrets-store-sync-controller). This is the terraform half of the secret-sync contract - the manifests'
`SecretProviderClass`/`SecretSync` objects are the other half - so the secret names and election gating live here,
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
break (principals reduce to orphaned unique ids) every time it churns. The dex connector credentials ride the same `sso` declarations the cluster module publishes as
`DEX_CONNECTORS`: pass the cluster module's `sso` value verbatim and each connector's `secrets` fields become
`dex-<id>-<field>` containers here - an upstream OAuth client outlives any one cluster, so its credentials must too.

Pass the same election values as the cluster module call (`stack_components`, `patchy.harnesses`,
`patchy.claude.provider.name`, `sso`, `secret_prefix`); the module then creates exactly the secrets that cluster
shape syncs:

| Secret | Created when | Holds |
| --- | --- | --- |
| `patchy-github-app-id` | `patchy` elected | The patchy GitHub App's numeric id |
| `patchy-github-app-private-key` | `patchy` elected | The App's private key (PEM) |
| `patchy-webhook-secret` | `patchy` elected | The App's webhook secret |
| `patchy-anthropic-token` | + `claude` harness on `anthropic` | `claude setup-token` OAuth token (or an API key, per the chart's `anthropicAuth`) |
| `patchy-openai-token` | + `codex` harness | OpenAI platform API key |
| `patchy-copilot-token` | + `copilot` harness | Fine-grained GitHub token with **no** repository permissions |
| `dex-<id>-<field>` | `sso.enabled`, per `sso.connectors[<id>].secrets` field | The connector's upstream credential (e.g. an OAuth client id/secret) |

After the first apply, add a version to every secret:

```sh
aws secretsmanager put-secret-value --secret-id <name> --secret-string file://...
```

## Usage

```hcl
module "secrets" {
  source = "github.com/bitwise-media-group/terraform-aws-eks-flux//modules/secrets"

  # Mirror the cluster module call in the (separate, disposable) cluster root.
  agent_harnesses = ["claude"]
  claude_provider = "anthropic"
  sso = {
    enabled = true
    connectors = {
      google = { type = "google" }
    }
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
| agent\_harnesses | The agent harnesses the cluster elects -- pass the cluster module's patchy.harnesses value (published to the<br/>manifests as AGENT\_HARNESSES). Each harness brings its credential secret: claude's rides claude\_provider<br/>(anthropic only), codex adds patchy-openai-token, copilot adds patchy-copilot-token. | `set(string)` | <pre>[<br/>  "claude"<br/>]</pre> | no |
| claude\_provider | The claude runner's model provider -- pass the cluster module's patchy.claude.provider.name value. Only anthropic<br/>needs a credential secret (patchy-anthropic-token); a bedrock cluster's egress broker authenticates with its Pod<br/>Identity and gets none. | `string` | `"anthropic"` | no |
| secret\_prefix | Prefix for every secret name, matching the cluster module's secret\_prefix input (the manifests sync<br/><prefix><name>, so the two must move together - and the cluster module's reader roles scope their read grant to<br/>the same prefix). Lets multiple clusters share one account with distinct secrets -- each cluster then needs its<br/>own prefixed set and fresh out-of-band versions. Include the trailing separator (e.g. 'patchy-x-'); null keeps<br/>the unprefixed names. | `string` | `null` | no |
| sso | Platform SSO election -- pass the cluster module's sso value verbatim (its attributes beyond enabled and the<br/>connector's id/type/secrets are dropped by type conversion). enabled mirrors the cluster's dex toggle and gates<br/>the connector containers; the connector's secrets names its out-of-band credential fields, creating one<br/>dex-<id>-<field> Secrets Manager container per field (id defaulting to type, matching the cluster module) --<br/>populate versions out of band (an OAuth client cannot be terraformed). On its own enabled creates nothing: no<br/>connector is declared by default. | <pre>object({<br/>    enabled = optional(bool, false)<br/>    connector = optional(object({<br/>      id      = optional(string)<br/>      type    = string<br/>      secrets = optional(set(string), ["client-id", "client-secret"])<br/>    }))<br/>  })</pre> | `{}` | no |
| stack\_components | The flux-manifests optional-tier components the cluster elects -- pass the cluster module's stack\_components<br/>value. Only patchy carries out-of-band credentials: electing it creates the GitHub App secrets plus the elected<br/>harnesses' model credentials; flux-web is accepted for symmetric passing and creates nothing. There is no dex<br/>entry to gate on: the dex connector containers ride the sso input, mirroring the cluster module's sso toggle. | `set(string)` | <pre>[<br/>  "flux-web",<br/>  "patchy"<br/>]</pre> | no |
| tags | Tags applied to every secret. | `map(string)` | `{}` | no |

## Outputs

| Name | Description |
| ---- | ----------- |
| secrets | The created secrets, keyed by unprefixed name: the ARN and the (prefixed) Secrets Manager name, for wiring further<br/>IAM in the caller (e.g. a maintainer's PutSecretValue rotation grant). Every secret's versions are added out of<br/>band: aws secretsmanager put-secret-value --secret-id <name>. |
<!-- END_TF_DOCS -->
