# Changelog

## 0.1.0 (2026-08-21)


### ⚠ BREAKING CHANGES

* **iam:** the secret-sync contract changed sides together -- requires a flux-manifests release with the IRSA sync dialect (sync KSA eks.amazonaws.com/role-arn annotations composed from SECRETS_ROLE_PREFIX, usePodIdentity "false", sts.amazonaws.com token audience).
* requires flux-manifests >= 3.0.0, whose artifact ships the aws/google/common trees; the old single ./stack entrypoint no longer exists there. Clusters applying this version sync sync.path "aws" -- pin flux.sync.path explicitly only to override the tree.
* **sso:** sso.connectors (map) is replaced by sso.connector (a single object; id optional, defaulting to type) in the root module, examples/complete, and modules/secrets, and sso.client_rotation (map(number)) is replaced by sso.clients (map(object({ version = number }))).
* **sso:** sso.directory_secret is removed along with the dex-directory container, the DEX_DIRECTORY_SECRET cluster var, and the sso output's directory_secret field; declare the upstream via sso.connectors instead, whose secrets fields become dex-<id>-<field> containers in modules/secrets, published through DEX_CONNECTORS.
* public_access_cidrs is gone and the public endpoint is now off by default. Set public_access = { enable = true, cidrs = [...] } to restore the previous posture.

### Features

* add the ECR artifact store and pull-through cache modules ([351e8a3](https://github.com/bitwise-media-group/terraform-aws-eks-flux/commit/351e8a3757ea914867e74c08f122c4b2696e7c73))
* add the EKS cluster module with Cilium ENI and Karpenter ([1b50b55](https://github.com/bitwise-media-group/terraform-aws-eks-flux/commit/1b50b5561f5290ed0e9badc6bcbc92f1b3ee7612))
* elect agent harnesses and derive their secret-reader identities ([1eb16f1](https://github.com/bitwise-media-group/terraform-aws-eks-flux/commit/1eb16f1aa84f9d6e5e29e93cf79f91b5bdbcc663))
* **flux-operator:** port the flux bootstrap chain to EKS ([17de4cc](https://github.com/bitwise-media-group/terraform-aws-eks-flux/commit/17de4cc60b78b32b2e16c8a65bc4120bafa54f3a))
* **flux:** publish COSIGN_PUBLIC_KEY for the manifests' keyed verifies ([46ba67b](https://github.com/bitwise-media-group/terraform-aws-eks-flux/commit/46ba67b6baba91aa8a93028d7748701d26f031ee))
* **flux:** publish GATEWAY_API_CRDS from gateway.install_crds ([5c9f350](https://github.com/bitwise-media-group/terraform-aws-eks-flux/commit/5c9f3507cce573663863d504ffa4aa3d5614e77d))
* gate the public control-plane endpoint behind public_access.enable ([b023f07](https://github.com/bitwise-media-group/terraform-aws-eks-flux/commit/b023f07edf9c9a6fe820c4748b2a6b40f5151bf9))
* **kms-signing-key:** add cosign signing key submodule ([cfc76e7](https://github.com/bitwise-media-group/terraform-aws-eks-flux/commit/cfc76e736b2ab61d097badf483c33cbe3b708051))
* **patchy:** add the evaluation-controller toggle ([f13264d](https://github.com/bitwise-media-group/terraform-aws-eks-flux/commit/f13264dad6e4709a335d3a57e84a167a87492801))
* **patchy:** configure the claude runner's model provider via the egress-broker ([28b6f48](https://github.com/bitwise-media-group/terraform-aws-eks-flux/commit/28b6f48d30a20f1b2aa225f3ca2a7f879195c91f))
* **secrets:** add durable module for out-of-band credential secrets ([0d9f59f](https://github.com/bitwise-media-group/terraform-aws-eks-flux/commit/0d9f59f5a8303510205ee36828cc90842984bd2d))
* **sso:** declare a single connector object with native config types ([2af96ce](https://github.com/bitwise-media-group/terraform-aws-eks-flux/commit/2af96ce043e57eb681ff8e0e1e9513a44fac23cd))
* **sso:** make the dex connector-credential container optional ([176b3da](https://github.com/bitwise-media-group/terraform-aws-eks-flux/commit/176b3da42d5cba99064b347d1a9dadec8319970d))
* **sso:** support arbitrary dex connectors via sso.connectors ([60f87a5](https://github.com/bitwise-media-group/terraform-aws-eks-flux/commit/60f87a5429c093693f343f90cdb8a3cf7e80c7ed))
* support cosign KMS signing/verification as an alternative to keyless ([70e2436](https://github.com/bitwise-media-group/terraform-aws-eks-flux/commit/70e2436c1c15c7a61026887e37c0476ae5b25331))
* sync the per-cloud aws manifests tree ([162c63f](https://github.com/bitwise-media-group/terraform-aws-eks-flux/commit/162c63ff1c7632d6e6a2d9c987de9c0ced38b9af))


### Bug Fixes

* **deps:** update bitwise-media-group/github-workflows action to v6.1.1 ([#12](https://github.com/bitwise-media-group/terraform-aws-eks-flux/issues/12)) ([4561f56](https://github.com/bitwise-media-group/terraform-aws-eks-flux/commit/4561f565f2034ac09b40be23b7e0795e3b15d630))
* **deps:** update bitwise-media-group/github-workflows action to v6.2.0 ([#16](https://github.com/bitwise-media-group/terraform-aws-eks-flux/issues/16)) ([1af9551](https://github.com/bitwise-media-group/terraform-aws-eks-flux/commit/1af9551c72907272ad1290a827f960a3731f1b2c))
* **flux:** publish ARTIFACT_TAG_PROVIDER for RSIP tag listing ([3264ff8](https://github.com/bitwise-media-group/terraform-aws-eks-flux/commit/3264ff8ece05f0f8da4279d5fa244ad0fc5b4120))
* **iam:** dedupe overlapping secret-reader derivations ([9ecebc3](https://github.com/bitwise-media-group/terraform-aws-eks-flux/commit/9ecebc314e0005b5bf6e9ae980789a5b4d274195))
* **iam:** grant the EBS CSI driver its own Pod Identity association ([fa01fd0](https://github.com/bitwise-media-group/terraform-aws-eks-flux/commit/fa01fd0353f6c04a427245985fccc575cb7a2eb7))
* **iam:** move secret-sync reader roles from Pod Identity to IRSA ([af19e86](https://github.com/bitwise-media-group/terraform-aws-eks-flux/commit/af19e86c0f28489ee77211b990f27a9fc3f29e09))
* replace em dashes with hyphens in IAM role descriptions ([0ce07a5](https://github.com/bitwise-media-group/terraform-aws-eks-flux/commit/0ce07a5ee9b09013be1ac16cf8ac4195664a826f))
* **tests:** align the pod-identity asserts with the IRSA secret-reader split ([51287e6](https://github.com/bitwise-media-group/terraform-aws-eks-flux/commit/51287e680e8ced921367e9248ce75fc9bbf6188c))
* **tests:** drop CLOUD and the vertex vars from the contract asserts ([a09709b](https://github.com/bitwise-media-group/terraform-aws-eks-flux/commit/a09709b8f8f92e17f3a846494496b41ba1d05f2c))
