# kms-signing-key

An asymmetric KMS key for **cosign signing** of platform artifacts. Use it only in KMS signing mode. Keyless signing
(the default) needs no key at all. See [Registry & signing](../concepts/supply-chain.md#signing-and-verification).

```hcl
module "signing_key" {
  source = "git::https://github.com/bitwise-media-group/terraform-aws-eks-flux.git//modules/kms-signing-key?ref=vX.Y.Z"

  name            = "platform-signing"
  organization_id = "o-…" # verification org-wide
}

module "store" {
  source              = "git::https://github.com/bitwise-media-group/terraform-aws-eks-flux.git//modules/artifact-store?ref=vX.Y.Z"
  signing_kms_key_arn = module.signing_key.key_arn # grants the publishers kms:Sign
  # ...
}

module "cluster" {
  source          = "git::https://github.com/bitwise-media-group/terraform-aws-eks-flux.git?ref=vX.Y.Z"
  signed_identity = { kms_key_arn = module.signing_key.key_arn } # selects KMS verification
  # ...
}
```

Publishers sign with `cosign sign --key awskms:///<key-arn>`, which is the `cosign_key_ref` output. Verifiers only ever
need the public half.

## What it creates

- `aws_kms_key` with `key_usage = SIGN_VERIFY` and a cosign-supported asymmetric spec (`key_spec`, default
  `ECC_NIST_P256`, which is ECDSA P-256 / SHA-256, cosign's own default algorithm). Both are fixed once the key exists:
  an `ENCRYPT_DECRYPT` key, the KMS default, can't sign at all.
- An alias, `alias/<name>`.
- The public key, exported as `public_key_pem` for offline verification (`cosign verify --key cosign.pub`).

## How it works

### It lives in its own module

**The signing identity has to outlive every store and cluster.** Artifacts that are already published verify against
this key forever. So its lifecycle is deliberately separate from the infrastructure that signs with it or verifies
against it. Apply it from a durable root.

### The key policy

| Grant                            | To                                                       | Why                                                                                                                    |
| -------------------------------- | -------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------- |
| Full control, delegated to IAM   | the owning account's root                                | No lockout. The artifact store grants its publishers `kms:Sign` through IAM policies, without touching this key policy |
| `kms:Sign`                       | `signer_principals`                                      | Cross-account signers (a store in another account). They also need an identity policy on their side                    |
| `kms:GetPublicKey`, `kms:Verify` | everyone in `organization_id` (and `organization_paths`) | Verification isn't a privilege. A new cluster account onboards without editing the key, and the grant can never sign   |

Add anything else through `additional_key_policy_statements`.

### No rotation, maximum deletion window

There's deliberately no automatic rotation. KMS can't rotate asymmetric keys, and rotating a signing key changes the
signing identity. It means a new key, re-signing everything, and re-pointing every verifier, coordinated by people.

For the same reason the deletion window defaults to 30 days, the KMS maximum. Deleting the key permanently breaks
verification of everything it ever signed.

`multi_region` makes the key a multi-Region primary. This can only be chosen at creation, so turn it on up front if you
might ever need to isolate the verification path by region.

--8<-- "modules/kms-signing-key/README.md:tf-docs"
