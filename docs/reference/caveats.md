# Caveats

Behaviour that surprises people, and the constraints behind it.

## Applications

### Application seeds are bootstrap-only

After the first apply, the application's image owns `<key>-manifests`. Changing an `applications` entry in Terraform
does nothing until you remove the key and add it back. Never lift `ignore_changes`. See
[Applications](../concepts/applications.md#the-hand-over).

### A semver range that matches no tag prunes the application

An empty input set empties the `ResourceSet`, which garbage-collects the `Kustomization`, which prunes what it applied.
Keep ranges bounded, for example `<1.0.0 >=0.1.0`.

### Application modules must not consume cluster outputs

The root wires application outputs into the cluster module, so the reverse would be a cycle. Derive anything
cluster-minted from the static naming rules (`secret_prefix`, `secrets_role_prefix`), or put it in a second-stage module
in the application repo.

## Capacity

### Karpenter isn't an EKS add-on

It's in neither the AWS nor the community catalogue. The only AWS-managed Karpenter is **EKS Auto Mode**, which owns
networking with the AWS VPC CNI on AWS-managed AMIs, so it can't run Cilium in ENI mode.

### Karpenter has no minimum-node concept

It scales from zero on pending pods and offers only ceilings (`spec.limits`). The cluster's floor is
`system_node_group.min_size`.

### Managed node group counts are cluster-wide totals

They're not per availability zone.

## Networking

### The AWS Load Balancer Controller isn't an ingress path

Cilium is the Gateway API implementation and owns all L7 routing. The controller exists only to turn the one
`Service type=LoadBalancer` that Cilium's Gateway creates into an NLB bound to the reserved EIPs. EKS's built-in legacy
controller could do that too, but AWS ships it critical fixes only and advises against new NLBs on it.

### The NLB targets instances, not IPs

The controller can only register IP targets when the AWS VPC CNI is the datapath. Under any other CNI it's limited to
instance targets, whatever the pods' addresses look like.

### The manifests install the Gateway API CRDs, not EKS

EKS ships no `gateway.networking.k8s.io` CRDs, and Cilium implements the API without owning them. So
`gateway.install_crds` (on by default) has the platform's gateway component install the standard-channel set. Cilium
only enables its Gateway API controller if the CRDs exist when its agent and operator start. On a fresh bootstrap they
arrive after Terraform's Cilium release, so the first Cilium rollout after they're established (an upgrade or restart)
activates the implementation.

If AWS ever installs the CRDs as managed cluster components, turn `gateway.install_crds` off. The manifests then orphan
the CRDs instead of pruning them, since deleting a CRD deletes every Gateway and HTTPRoute with it.

## Bootstrap and operations

### The helm provider needs the AWS CLI

The helm provider must authenticate with an exec plugin, not `data.aws_eks_cluster_auth`. That data source mints a
presigned STS token that lasts about 15 minutes, and resolves it once. A first apply covers cluster creation, the node
group, the add-ons and only then the flux chain, which takes much longer, so the token expires mid-apply.

The examples run `aws eks get-token` when credentials are actually needed. **That makes the AWS CLI a prerequisite on
whatever runs Terraform.** The `--region` argument is passed explicitly, so the CLI doesn't have to infer it from an
environment that might not match the provider's. ECR authorization tokens last 12 hours, so those stay ordinary data
sources.

`network.restrict_default_security_group` also uses the AWS CLI, with `ec2:DescribeSecurityGroupRules` and
`ec2:RevokeSecurityGroupEgress`, authenticated as the provider identity.

### EKS has no deletion protection

Guard production clusters with policy, or with `prevent_destroy` in your own root.

### kubectl SSO needs a second apply

EKS checks the OIDC issuer when it creates the identity provider config, and dex only exists after flux reconciles it.
Apply with `sso.kubectl.enabled = false` first, then turn it on once dex is live.

## Supply chain

### cert-manager and external-dns stay flux-managed

They're available as community add-ons, but AWS supports only their lifecycle operations, not the software. Taking them
as add-ons would also pull images from AWS's registry. That would break the rule that clusters never pull from a public
registry, and the Kyverno policy that enforces it.

### Pull-through coverage of charts and signatures is unvalidated

ECR-to-ECR pull-through copies manifests and blobs, so OCI chart artifacts and `sha256-<digest>.sig` tags should pass
through intact. The whole verification chain depends on it, so confirm both on first apply.

### `aws_ecr_registry_policy` is a singleton

There's one per account and region, and [artifact-store](../modules/artifact-store.md) owns it. An account that uses
registry policies for anything else must merge those statements in through `additional_registry_statements`.
