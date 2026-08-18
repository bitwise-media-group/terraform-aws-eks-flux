# Copyright 2026 BitWise Media Group Ltd
# SPDX-License-Identifier: MIT

# Plan-time contract tests with mocked providers: no credentials, no API calls.
# These assert the cluster shape (no VPC CNI, no kube-proxy, Cilium in ENI mode,
# the bootstrap taint, the add-on set) and the terraform -> flux contract (Pod
# Identity associations, cluster vars).

mock_provider "aws" {
  mock_data "aws_caller_identity" {
    defaults = {
      account_id = "123456789012"
    }
  }

  mock_data "aws_partition" {
    defaults = {
      partition = "aws"
    }
  }

  mock_data "aws_region" {
    defaults = {
      region = "eu-west-2"
    }
  }

  mock_data "aws_route53_zone" {
    defaults = {
      zone_id      = "Z0123456789ABCDEFGHIJ"
      name         = "patchy.bitwisemedia.co.uk."
      name_servers = ["ns-1.awsdns-00.co.uk"]
    }
  }

  # Without a default the mocked json attribute is a random string, which every
  # assume_role_policy then rejects as invalid. These tests assert IAM wiring —
  # which role, which association — not policy contents, so an empty document
  # is enough.
  mock_data "aws_iam_policy_document" {
    defaults = {
      json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}"
    }
  }
}

mock_provider "helm" {}

# random is deliberately NOT mocked: the dex client secrets are ephemeral
# resources, which the mocking mechanism cannot represent, and random_password
# needs no credentials to run for real.

variables {
  name = "patchy-x"

  network = {
    vpc_id            = "vpc-0123456789abcdef0"
    node_subnet_ids   = ["subnet-0aaa", "subnet-0bbb"]
    public_subnet_ids = ["subnet-0ccc", "subnet-0ddd"]
  }

  platform_registry = {
    url                   = "123456789012.dkr.ecr.eu-west-2.amazonaws.com/platform"
    is_pull_through_cache = true
  }

  signed_identity = {
    manifests_subject  = "^https://github\\.com/bitwise-media-group/flux-manifests/\\.github/workflows/publish\\.yaml@refs/tags/v.+$"
    containers_subject = "^https://github\\.com/bitwise-media-group/flux-containers/\\.github/workflows/publish\\.yaml@refs/heads/main$"
  }
}

run "cluster_shape" {
  command = plan

  assert {
    condition     = aws_eks_cluster.main.bootstrap_self_managed_addons == false
    error_message = "EKS must install no default add-ons: the AWS VPC CNI would fight Cilium for ENI ownership, and kube-proxy is replaced by Cilium's datapath"
  }

  assert {
    condition     = !contains(keys(var.addons), "vpc-cni") && !contains(keys(var.addons), "kube-proxy")
    error_message = "vpc-cni and kube-proxy must never appear in the add-on set"
  }

  assert {
    condition     = aws_eks_cluster.main.access_config[0].authentication_mode == "API"
    error_message = "authorization must come from access entries only, never the aws-auth ConfigMap"
  }

  assert {
    condition     = aws_eks_cluster.main.vpc_config[0].endpoint_private_access == true
    error_message = "the private endpoint must be on so in-VPC clients never traverse the public one"
  }

  assert {
    condition     = aws_eks_cluster.main.vpc_config[0].endpoint_public_access == false
    error_message = "the public endpoint must stay off unless public_access.enable opts in"
  }

  assert {
    condition     = contains(aws_eks_cluster.main.enabled_cluster_log_types, "audit")
    error_message = "control-plane audit logs must ship to CloudWatch"
  }
}

run "public_access_open_when_unconstrained" {
  command = plan

  variables {
    public_access = { enable = true }
  }

  assert {
    condition     = aws_eks_cluster.main.vpc_config[0].endpoint_public_access == true
    error_message = "public_access.enable must turn the public endpoint on"
  }

  assert {
    condition     = aws_eks_cluster.main.vpc_config[0].public_access_cidrs == toset(["0.0.0.0/0"])
    error_message = "an enabled public endpoint with no cidrs must fall back to 0.0.0.0/0 (PoC posture)"
  }
}

run "public_access_constrained_to_cidrs" {
  command = plan

  variables {
    public_access = { enable = true, cidrs = ["203.0.113.0/24"] }
  }

  assert {
    condition     = aws_eks_cluster.main.vpc_config[0].public_access_cidrs == toset(["203.0.113.0/24"])
    error_message = "public_access.cidrs must constrain the public endpoint"
  }
}

run "cilium_is_the_cni" {
  command = plan

  assert {
    condition     = local.cilium_values.eni.enabled == true && local.cilium_values.ipam.mode == "eni"
    error_message = "Cilium must run in ENI mode so pods hold routable VPC addresses (not an overlay)"
  }

  assert {
    condition     = local.cilium_values.routingMode == "native"
    error_message = "ENI mode requires native routing — tunnelling would defeat the point of VPC-addressed pods"
  }

  assert {
    condition     = local.cilium_values.kubeProxyReplacement == true
    error_message = "kube-proxy is never installed, so Cilium must replace it"
  }

  assert {
    condition     = local.cilium_values.gatewayAPI.enabled == true
    error_message = "Cilium is the Gateway API implementation; the platform Gateway rides on it"
  }

  assert {
    condition     = helm_release.cilium.wait == false
    error_message = "the Cilium release must not wait: it is installed before any node exists, so waiting would deadlock against the node group that depends on it"
  }

  assert {
    condition     = length(aws_iam_role_policy.cilium_eni) == 1
    error_message = "by default the ENI permissions sit on the node role — Pod Identity there is a bootstrap cycle (the agent add-on only installs once nodes exist)"
  }

  assert {
    condition     = length(aws_eks_pod_identity_association.cilium_operator) == 0
    error_message = "cilium.operator_pod_identity defaults off; the association must only exist when it is turned on"
  }
}

run "node_group_gates_on_cilium" {
  command = plan

  assert {
    condition     = aws_eks_node_group.system.labels["role"] == "system"
    error_message = "the system node group must carry the role=system label platform controllers pin to"
  }

  assert {
    condition = one([
      for taint in aws_eks_node_group.system.taint :
      taint if taint.key == "node.cilium.io/agent-not-ready" && taint.effect == "NO_EXECUTE"
    ]) != null
    error_message = "nodes must be tainted until Cilium can address pods; the Cilium operator removes the taint once its agent is ready"
  }

  assert {
    condition     = aws_eks_node_group.system.node_repair_config[0].enabled == true
    error_message = "node auto-repair must be on"
  }
}

run "node_role_has_no_vpc_cni_policy" {
  command = plan

  assert {
    condition = alltrue([
      for attachment in aws_iam_role_policy_attachment.nodes :
      !endswith(attachment.policy_arn, "AmazonEKS_CNI_Policy")
    ])
    error_message = "AmazonEKS_CNI_Policy is the AWS VPC CNI's grant and must never be attached; Cilium's ENI policy replaces it"
  }

  assert {
    condition = anytrue([
      for attachment in aws_iam_role_policy_attachment.nodes :
      endswith(attachment.policy_arn, "AmazonEKSWorkerNodePolicy")
    ])
    error_message = "nodes still need the standard worker node policy"
  }
}

run "addon_set" {
  command = plan

  assert {
    condition     = length(aws_eks_addon.pod_identity_agent) == 1
    error_message = "the Pod Identity agent must be installed: every workload IAM grant resolves through it"
  }

  assert {
    condition     = contains(keys(aws_eks_addon.main), "aws-ebs-csi-driver") && contains(keys(aws_eks_addon.main), "snapshot-controller")
    error_message = "the EBS CSI driver and snapshot controller must be present by default"
  }

  assert {
    condition     = contains(keys(aws_eks_addon.main), "aws-secrets-store-csi-driver-provider")
    error_message = "the Secrets Store CSI driver + AWS provider arrive as one add-on; only the SecretSync controller is a flux component"
  }

  assert {
    condition     = contains(keys(aws_eks_addon.main), "coredns") && contains(keys(aws_eks_addon.main), "eks-node-monitoring-agent")
    error_message = "coredns and the node monitoring agent (which feeds node auto-repair) must be present by default"
  }
}

run "workload_identity_is_pod_identity" {
  command = plan

  assert {
    condition     = length(aws_eks_pod_identity_association.workload) == length(local.workload_grants)
    error_message = "every workload grant must get exactly one Pod Identity association"
  }

  assert {
    condition     = contains(keys(local.workload_grants), "otel-collector")
    error_message = "the otel-collector's telemetry grant is unconditional"
  }

  assert {
    condition     = !contains(keys(local.workload_grants), "external-dns") && !contains(keys(local.workload_grants), "cert-manager")
    error_message = "the Route53 grants must not exist without the DNS surface"
  }

  assert {
    condition     = aws_eks_pod_identity_association.karpenter_controller.namespace == "kube-system"
    error_message = "Karpenter's controller identity is a Pod Identity association like every other platform workload"
  }
}

run "cluster_vars_contract" {
  command = plan

  assert {
    condition     = local.reserved_cluster_vars.CLOUD == "aws" && local.reserved_cluster_vars.OCI_PROVIDER == "aws"
    error_message = "the stack branches on CLOUD, and the flux controllers resolve ECR credentials via the aws OCI provider"
  }

  assert {
    condition     = local.reserved_cluster_vars.CLUSTER_NAME == "patchy-x"
    error_message = "CLUSTER_NAME is the cluster's identity throughout the stack (external-dns txtOwnerId and more)"
  }

  # Optional surfaces use the empty-string convention so substitution never
  # fails on an absent value.
  assert {
    condition = alltrue([
      for key in ["DNS_ZONE_NAME", "DNS_ZONE_ID", "DNS_DOMAIN", "PATCHY_DOMAIN", "ACME_EMAIL", "OTEL_AMP_ENDPOINT", "SIGNED_IDENTITY_KMS_KEY"] :
      local.reserved_cluster_vars[key] == ""
    ])
    error_message = "unset optional surfaces must publish empty strings, not null"
  }

  assert {
    condition     = local.reserved_cluster_vars.DEX_CONNECTORS == "[]"
    error_message = "without sso, DEX_CONNECTORS must publish the empty JSON array (not the empty string -- the manifests unconditionally mustFromJson-parse it)"
  }

  assert {
    condition     = local.reserved_cluster_vars.STACK_COMPONENTS == "flux-web,patchy"
    error_message = "the default election is the whole optional tier, comma-joined and sorted"
  }

  assert {
    condition     = local.reserved_cluster_vars.AGENT_HARNESSES == "claude"
    error_message = "the default harness election must publish claude alone"
  }

  assert {
    condition     = contains(keys(local.workload_grants), "secrets-patchy-patchy-secrets")
    error_message = "electing patchy must derive the patchy-namespace secret-reader identity (the GitHub App and anthropic syncs) rather than requiring the caller to list it"
  }

  assert {
    condition     = !contains(keys(local.workload_grants), "secrets-patchy-agents-patchy-secrets")
    error_message = "the brokered claude harness mounts no credential into agent pods: no agent-namespace reader may exist by default"
  }

  assert {
    condition     = local.reserved_cluster_vars.SIGNED_IDENTITY_MANIFESTS == var.signed_identity.manifests_subject
    error_message = "the manifests signing subject must reach the stack: its flux component re-renders the FluxInstance and needs it for the sync verify patch"
  }

  assert {
    condition     = local.reserved_cluster_vars.GATEWAY_NLB_TARGET_TYPE == "instance"
    error_message = "under a non-vpc-cni datapath the AWS Load Balancer Controller can only register instance targets"
  }

  # The claude runner's model provider (patchy's egress-broker) defaults to
  # first-party Anthropic with OAuth-token auth.
  assert {
    condition     = local.reserved_cluster_vars.CLAUDE_PROVIDER == "anthropic"
    error_message = "the claude provider must default to first-party anthropic"
  }

  assert {
    condition     = local.reserved_cluster_vars.CLAUDE_ANTHROPIC_AUTH == "token"
    error_message = "anthropic auth must default to token (OAuth), not an API key"
  }

  assert {
    condition = alltrue([
      for key in ["CLAUDE_BEDROCK_REGION", "CLAUDE_BEDROCK_REGION_PREFIX", "CLAUDE_VERTEX_REGION", "CLAUDE_VERTEX_PROJECT_ID", "CLAUDE_MODEL_MAP"] :
      local.reserved_cluster_vars[key] == ""
    ])
    error_message = "provider knobs that do not apply must publish empty strings, not null"
  }
}

run "agent_harness_election" {
  command = plan

  variables {
    patchy = {
      harnesses = ["copilot", "claude"]
    }
  }

  assert {
    condition     = local.reserved_cluster_vars.AGENT_HARNESSES == "claude,copilot"
    error_message = "the harness election must publish sorted and comma-joined, like STACK_COMPONENTS"
  }

  assert {
    condition     = contains(keys(local.workload_grants), "secrets-patchy-agents-patchy-secrets")
    error_message = "a non-brokered harness mounts its credential into agent pods, so its election must derive the agent-namespace secret reader"
  }
}

run "agent_harness_election_empty" {
  command = plan

  variables {
    patchy = {
      harnesses = []
    }
  }

  assert {
    condition     = local.reserved_cluster_vars.AGENT_HARNESSES == "none"
    error_message = "an empty election must publish the reserved name none -- an empty string would re-trigger the manifests' claude := default"
  }
}

run "claude_bedrock_provider" {
  command = plan

  variables {
    patchy = {
      claude = {
        provider = {
          name = "bedrock"
          model_map = {
            "anthropic/claude-opus-5"   = "us.anthropic.claude-opus-5"
            "anthropic/claude-sonnet-5" = "us.anthropic.claude-sonnet-5"
          }
        }
      }
    }
  }

  assert {
    condition     = local.reserved_cluster_vars.CLAUDE_BEDROCK_REGION == "eu-west-2"
    error_message = "an unset bedrock_region must fall back to the cluster's own region, never an empty string"
  }

  assert {
    condition     = local.reserved_cluster_vars.CLAUDE_MODEL_MAP == "anthropic/claude-opus-5=us.anthropic.claude-opus-5,anthropic/claude-sonnet-5=us.anthropic.claude-sonnet-5"
    error_message = "the model map arrives as comma-joined sorted canonical=providerID pairs — the flat-string list pattern the stack already proves"
  }

  # bedrock is the one provider needing cloud credentials, so it alone brings
  # the broker's invoke grant with it.
  assert {
    condition     = contains(keys(local.workload_grants), "patchy-egress-broker")
    error_message = "the bedrock provider must grant the egress-broker's KSA Bedrock invoke permissions"
  }
}

run "kms_signing_mode" {
  command = plan

  variables {
    signed_identity = {
      kms_key_arn = "arn:aws:kms:eu-west-2:123456789012:key/1234abcd-12ab-4bcd-8def-1234567890ab"
    }
  }

  assert {
    condition     = local.reserved_cluster_vars.SIGNED_IDENTITY_KMS_KEY == "arn:aws:kms:eu-west-2:123456789012:key/1234abcd-12ab-4bcd-8def-1234567890ab"
    error_message = "KMS mode must publish the signing key ARN for the stack's awskms:/// verification"
  }

  # One mode or the other: the keyless identities go empty so the manifests'
  # guards select the KMS path.
  assert {
    condition = alltrue([
      for key in ["SIGNED_IDENTITY_ISSUER", "SIGNED_IDENTITY_CHARTS", "SIGNED_IDENTITY_IMAGES", "SIGNED_IDENTITY_MANIFESTS"] :
      local.reserved_cluster_vars[key] == ""
    ])
    error_message = "the keyless identities must publish empty strings in KMS mode"
  }

  assert {
    condition = anytrue([
      for statement in data.aws_iam_policy_document.kyverno.statement :
      statement.sid == "VerifySignatures" && contains(statement.actions, "kms:GetPublicKey")
    ])
    error_message = "kyverno's controllers must be able to resolve the signing key at admission time"
  }
}

run "keyless_mode_gets_no_kms_grant" {
  command = plan

  assert {
    condition = !anytrue([
      for statement in data.aws_iam_policy_document.kyverno.statement :
      statement.sid == "VerifySignatures"
    ])
    error_message = "keyless verification must grant no KMS access"
  }
}

run "karpenter_node_pool_shape" {
  command = plan

  assert {
    condition     = local.reserved_cluster_vars.KARPENTER_CAPACITY_TYPES == "spot,on-demand"
    error_message = "the default NodePool takes spot first with on-demand as fallback"
  }

  assert {
    condition     = local.reserved_cluster_vars.KARPENTER_INSTANCE_CATEGORIES == "c,m,r"
    error_message = "lists reach the stack comma-joined; the manifests expand them with splitList"
  }

  assert {
    condition     = local.reserved_cluster_vars.KARPENTER_MEMORY_LIMIT == "256Gi"
    error_message = "the memory ceiling must carry its Gi unit — it lands directly in the NodePool's spec.limits"
  }

  assert {
    condition     = local.reserved_cluster_vars.KARPENTER_INTERRUPTION_QUEUE == aws_sqs_queue.karpenter_interruption.name
    error_message = "the controller drains nodes from the interruption queue, so its name must reach the manifests"
  }

  assert {
    condition     = local.reserved_cluster_vars.KARPENTER_NODE_ROLE == aws_iam_role.karpenter_node.name
    error_message = "the EC2NodeClass references the node role by name"
  }

  assert {
    condition     = aws_eks_access_entry.karpenter_node.type == "EC2_LINUX"
    error_message = "Karpenter-launched nodes need an EC2_LINUX access entry to join"
  }
}

run "empty_election_publishes_none" {
  command = plan

  variables {
    stack_components = []
  }

  assert {
    condition     = local.reserved_cluster_vars.STACK_COMPONENTS == "none"
    error_message = "an explicitly empty election must publish the reserved name none — an empty string would re-trigger the manifests' elect-everything default"
  }
}

run "dns_and_gateway_surface" {
  command = plan

  variables {
    dns = {
      zone_name  = "patchy.bitwisemedia.co.uk"
      acme_email = "platform@bitwisemedia.co.uk"
    }
  }

  assert {
    condition     = local.reserved_cluster_vars.DNS_DOMAIN == "patchy.bitwisemedia.co.uk"
    error_message = "the apex domain must be derived from the zone with its trailing dot trimmed"
  }

  assert {
    condition     = local.reserved_cluster_vars.PATCHY_DOMAIN == "patchy.bitwisemedia.co.uk"
    error_message = "the served host defaults to the zone apex unless dns.host narrows it"
  }

  assert {
    condition     = contains(keys(local.workload_grants), "external-dns") && contains(keys(local.workload_grants), "cert-manager")
    error_message = "the DNS surface must bring the Route53 grants with it"
  }

  # One EIP per public subnet the Gateway's NLB spans — an NLB requirement, not
  # a per-host one. Every HTTPRoute hostname shares them.
  assert {
    condition     = length(aws_eip.gateway) == length(var.network.public_subnet_ids)
    error_message = "one Gateway address must be reserved per public subnet"
  }
}

run "sso_surface" {
  command = plan

  variables {
    dns = {
      zone_name  = "patchy.bitwisemedia.co.uk"
      acme_email = "platform@bitwisemedia.co.uk"
    }
    sso = {
      enabled = true
      connectors = {
        google = {
          type = "google"
          config = {
            clientID = "$GOOGLE_CLIENT_ID"
          }
        }
      }
    }
    secret_prefix = "patchy-x-"
  }

  assert {
    condition     = local.reserved_cluster_vars.STACK_COMPONENTS == "dex,flux-web,patchy"
    error_message = "dex is not elected directly — it joins the election exactly when sso is on"
  }

  assert {
    condition     = [for c in jsondecode(local.reserved_cluster_vars.DEX_CONNECTORS) : c.id][0] == "google"
    error_message = "DEX_CONNECTORS must publish the declared connector id"
  }

  assert {
    condition     = [for c in jsondecode(local.reserved_cluster_vars.DEX_CONNECTORS) : c.name][0] == "google"
    error_message = "an unset connector name must default to the connector id"
  }

  assert {
    condition     = [for c in jsondecode(local.reserved_cluster_vars.DEX_CONNECTORS) : c.config.redirectURI][0] == "https://dex.patchy.bitwisemedia.co.uk/callback"
    error_message = "a connector with no explicit redirectURI must get the shared callback endpoint injected"
  }

  assert {
    condition     = [for c in jsondecode(local.reserved_cluster_vars.DEX_CONNECTORS) : c.config.clientID][0] == "$GOOGLE_CLIENT_ID"
    error_message = "explicit connector config must pass through verbatim alongside the injected redirectURI"
  }

  assert {
    condition     = toset([for c in jsondecode(local.reserved_cluster_vars.DEX_CONNECTORS) : c.secrets][0]) == toset(["client-id", "client-secret"])
    error_message = "an unset connector secrets set must default to the client-id/client-secret pair"
  }

  assert {
    condition     = length(aws_secretsmanager_secret.dex_client) == 2
    error_message = "both elected relying parties must get a generated client pair"
  }

  assert {
    condition     = alltrue([for secret in aws_secretsmanager_secret.dex_client : secret.recovery_window_in_days == 0])
    error_message = "deletion must be immediate: a 30-day scheduled deletion would block recreating the cluster under the same names"
  }

  assert {
    condition     = contains(keys(local.workload_grants), "secrets-dex-dex-secrets")
    error_message = "the SSO surface must derive its own secret-reader identities rather than requiring the caller to list them"
  }
}

run "sso_connector_mechanism_is_generic" {
  command = plan

  variables {
    dns = {
      zone_name  = "patchy.bitwisemedia.co.uk"
      acme_email = "platform@bitwisemedia.co.uk"
    }
    sso = {
      enabled = true
      connectors = {
        okta = {
          type    = "oidc"
          name    = "Okta"
          secrets = ["client-id", "client-secret", "api-token"]
        }
      }
    }
  }

  # The credential containers themselves live in modules/secrets (a durable
  # root, fed the same sso value) -- this run asserts only the cluster-side
  # half: the published declarations and the unchanged generated pairs.
  assert {
    condition = toset([for c in jsondecode(local.reserved_cluster_vars.DEX_CONNECTORS) : c.secrets][0]) == toset([
      "client-id", "client-secret", "api-token"
    ])
    error_message = "an explicit secrets set must publish verbatim -- modules/secrets names the dex-<id>-<field> containers from it"
  }

  assert {
    condition     = [for c in jsondecode(local.reserved_cluster_vars.DEX_CONNECTORS) : c.name][0] == "Okta"
    error_message = "an explicit connector name must pass through to DEX_CONNECTORS untouched"
  }

  assert {
    condition     = length(aws_secretsmanager_secret.dex_client) == 2
    error_message = "the generated client pairs are independent of the connector declarations"
  }
}

run "sso_requires_connectors" {
  command = plan

  variables {
    dns = {
      zone_name  = "patchy.bitwisemedia.co.uk"
      acme_email = "platform@bitwisemedia.co.uk"
    }
    sso = {
      enabled = true
    }
  }

  expect_failures = [var.sso]
}

run "rbac_access_entries" {
  command = plan

  variables {
    rbac = {
      enabled = true
      groups = {
        viewers = { principal_arn = "arn:aws:iam::123456789012:role/AWSReservedSSO_Viewer_abc123" }
        admins  = { principal_arn = "arn:aws:iam::123456789012:role/AWSReservedSSO_Admin_def456", group = "platform:admins" }
      }
    }
  }

  assert {
    condition     = length(aws_eks_access_entry.rbac) == 2
    error_message = "each bound role must get exactly one access entry"
  }

  assert {
    condition     = contains(aws_eks_access_entry.rbac["viewers"].kubernetes_groups, "platform:viewers")
    error_message = "the access entry maps the IAM principal onto the Kubernetes group the manifests bind"
  }

  # The manifests bind group NAMES — never the IAM principals behind them.
  assert {
    condition     = local.reserved_cluster_vars.RBAC_GROUP_ADMINS == "platform:admins"
    error_message = "RBAC_GROUP_* must publish the Kubernetes group names, not the principal ARNs"
  }

  assert {
    condition     = local.reserved_cluster_vars.RBAC_GROUP_DEVOPS == ""
    error_message = "unbound roles must publish empty strings"
  }
}

run "direct_store_reads_expose_principals" {
  command = plan

  variables {
    platform_registry = {
      url                   = "999988887777.dkr.ecr.eu-west-2.amazonaws.com/platform"
      is_pull_through_cache = false
    }
  }

  # Reading a central store directly means feeding every puller to that store's
  # direct_pull_principals, so the export must be complete: both node roles
  # (kubelet pulls images), both flux controllers, and both kyverno controllers
  # (they fetch signatures at admission). The ARNs themselves are unknown until
  # apply, so the count is what a plan can check.
  assert {
    condition     = length(local.registry_reader_principals) == 6
    error_message = "registry_reader_principals must cover both node roles, both flux controllers and both kyverno controllers"
  }
}
