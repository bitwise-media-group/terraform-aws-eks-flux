# sso-secrets

The Secrets Manager containers for the SSO connector's out-of-band credentials, which the platform's dex component syncs
into the cluster. This is the Terraform half of the platform's dex secret-sync contract. The manifests'
`SecretProviderClass`/`SecretSync` objects are the other half. Keeping the container names here, versioned with the
module release that tracks those manifests, means callers never maintain their own copy that can drift.

```hcl
module "sso_secrets" {
  source = "git::https://github.com/bitwise-media-group/terraform-aws-eks-flux.git//modules/sso-secrets?ref=vX.Y.Z"

  # Mirror the cluster module call in the (separate, disposable) cluster root.
  secret_prefix = "platform-x-"
  sso = {
    enabled   = true
    connector = { type = "google" }
  }
}
```

After the first apply, add a value to every secret out of band:

```sh
aws secretsmanager put-secret-value --secret-id <name> --secret-string file://...
```

## What it creates

| Secret                             | Created when                                            | Holds                                                                     |
| ---------------------------------- | ------------------------------------------------------- | ------------------------------------------------------------------------- |
| `${secret_prefix}dex-<id>-<field>` | `sso.enabled`, one per field in `sso.connector.secrets` | The connector's upstream credential, such as an OAuth client id or secret |

`<id>` is the connector's effective id, which defaults to its `type`. The cluster module applies the same rule, so the
names can't drift. A secret that no sync references is never created, and every referenced secret exists: a
`SecretProviderClass` naming a missing secret syncs nothing and errors forever.

## How it works

### Instantiate it in a durable root

Don't put this module next to the cluster. The secret **values** are added out of band, never through Terraform state,
and must survive a cluster being destroyed and recreated without anyone entering them again. An upstream OAuth client
outlives any one cluster, so its credentials must too. Pass the cluster module's `sso` value here verbatim.

### Containers only, no grants

On EKS the read grant lives on the identity side. The cluster module creates the sync service accounts' IRSA reader
roles with `GetSecretValue`/`DescribeSecret` on `${SECRET_PREFIX}*`, so these secrets become readable as soon as the
cluster exists. See [Identity & secrets](../concepts/identity.md#irsa-for-podless-secret-syncs).

This is the opposite of the GKE sibling module, and it's deliberate. A resource policy here would have to name those
per-cluster role principals. `PutResourcePolicy` validates AWS principals, so the policy couldn't be created before the
cluster exists. Every time the cluster was rebuilt, it would break, with its principals reduced to orphaned unique ids.

### Application credentials live elsewhere

Each application's own module creates its secrets under the same `secret_prefix`. The cluster module's
`workload_identity.secret_readers` input gives that application's sync service accounts their reader roles. Before 4.0
this module was `modules/secrets` and also carried patchy's secrets.

--8<-- "modules/sso-secrets/README.md:tf-docs"
