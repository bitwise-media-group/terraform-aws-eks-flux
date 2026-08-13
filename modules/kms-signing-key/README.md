# kms-signing-key

An asymmetric KMS key appropriate for **cosign signing** of platform artifacts: `SIGN_VERIFY` usage with a
sigstore-supported spec (ECDSA P-256 by default, cosign's own default algorithm). Publishers sign with
`cosign sign --key awskms:///<key-arn>` (the `cosign_key_ref` output); verifiers only ever need the public half.

The key lives in its own module because the **signing identity must outlive any one store or cluster** — artifacts
already published verify against this key forever. Feed `key_arn` to the artifact-store module's
`signing_kms_key_arn` (which grants the publisher roles `kms:Sign`) and to the cluster module's
`signed_identity.kms_key_arn` (which selects KMS verification).

Setting `organization_id` grants **verification org-wide** (`aws:PrincipalOrgID`, wildcard principal), mirroring the
artifact store's read grant: a new cluster account onboards without editing this module, and the grant can never sign.
Cross-account *signing* stays opt-in via `signer_principals`.

There is no automatic rotation — KMS cannot rotate asymmetric keys, and rotating a signing key is an identity change
(new key, re-sign, re-point verifiers), not a background task. Accordingly the deletion window defaults to the KMS
maximum, since deleting the key permanently breaks verification of everything it ever signed.

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
| [aws_kms_alias.signing](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/kms_alias) | resource |
| [aws_kms_key.signing](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/kms_key) | resource |
| [aws_caller_identity.current](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/caller_identity) | data source |
| [aws_kms_public_key.signing](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/kms_public_key) | data source |
| [aws_partition.current](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/partition) | data source |

## Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| additional\_key\_policy\_statements | Extra IAM statements merged into the key policy. A KMS key has exactly one policy and this module owns it, so any<br/>further resource-level grants (auditors, external verifiers outside the organization) must be passed here rather<br/>than managed elsewhere. | `list(any)` | `[]` | no |
| deletion\_window\_in\_days | Days a scheduled deletion waits before the key is destroyed. Defaults to the KMS maximum: deleting this key<br/>permanently breaks cosign verification of every artifact ever signed with it, so the window should stay as long as<br/>possible. | `number` | `30` | no |
| key\_spec | Asymmetric key spec, immutable after creation. The default matches cosign's own default algorithm (ECDSA P-256 /<br/>SHA-256); the allowed set is the intersection of KMS signing specs and what cosign's AWS KMS provider supports —<br/>notably excluding ECC\_SECG\_P256K1, which sigstore does not accept. | `string` | `"ECC_NIST_P256"` | no |
| multi\_region | Create the key as a multi-region PRIMARY, allowing replicas in other regions later (same key material, so<br/>signatures verify against any replica). Immutable after creation — a single-region key can never be converted —<br/>so turn it on up front if regional isolation of the verification path may ever matter. The default stays<br/>single-region: the ARN works from any region, and verification is a rare, tiny, read-only call. | `bool` | `false` | no |
| name | Name for the key's alias (alias/<name>) and description (keep it short). | `string` | `"platform-artifact-signing"` | no |
| organization\_id | AWS Organizations id (o-xxxxxxxxxx). When set, every principal in the organization may VERIFY against this key<br/>(kms:GetPublicKey / kms:DescribeKey / kms:Verify), matched by aws:PrincipalOrgID rather than an account list — so<br/>onboarding a new cluster account needs no change here. Verification is not a privilege (the public key is public);<br/>signing stays restricted. Null grants nothing beyond the owning account. | `string` | `null` | no |
| organization\_paths | Optional aws:PrincipalOrgPaths patterns narrowing the organization-wide verify grant to particular organizational<br/>units, e.g. ["o-abc123/r-root/ou-workloads/*"]. Empty admits the whole organization. | `list(string)` | `[]` | no |
| signer\_principals | IAM principals in OTHER accounts allowed to sign with this key (kms:Sign plus the reads cosign needs) — e.g. an<br/>artifact-store module's publisher role ARNs when the store lives in a different account from the key. Cross-account<br/>KMS needs both this key-policy grant and an identity policy on the caller (artifact-store attaches the latter when<br/>given this key's ARN via signing\_kms\_key\_arn). Same-account signers need only their identity policy and can leave<br/>this empty. | `list(string)` | `[]` | no |
| tags | Tags applied to the key. | `map(string)` | `{}` | no |

## Outputs

| Name | Description |
| ---- | ----------- |
| alias\_arn | ARN of the key's alias. |
| alias\_name | The key's alias (alias/<name>) — a human-readable handle for consoles and same-account CLIs; wiring should use key\_arn. |
| cosign\_key\_ref | The --key argument for cosign sign/verify (awskms:///<key-arn>; the ARN form encodes account and region, so it works from anywhere with KMS access). |
| key\_arn | The signing key ARN — feed it to the artifact-store module's signing\_kms\_key\_arn (grants the publishers kms:Sign) and to the cluster module's signed\_identity.kms\_key\_arn (selects KMS verification). |
| key\_id | The signing key id. |
| public\_key\_pem | PEM-encoded public half of the signing key, for offline verification (cosign verify --key cosign.pub) or committing next to the artifacts it verifies. Not secret. |
<!-- END_TF_DOCS -->
