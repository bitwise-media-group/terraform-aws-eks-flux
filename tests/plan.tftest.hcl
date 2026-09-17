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
  # assume_role_policy then rejects as invalid. These tests assert IAM wiring - 
  # which role, which association - not policy contents, so an empty document
  # is enough.
  mock_data "aws_iam_policy_document" {
    defaults = {
      json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}"
    }
  }

  # A fixed PEM so the KMS-mode COSIGN_PUBLIC_KEY assertion can check the
  # base64 round-trip rather than a random string.
  mock_data "aws_kms_public_key" {
    defaults = {
      public_key_pem = "-----BEGIN PUBLIC KEY-----\nMOCK\n-----END PUBLIC KEY-----\n"
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

run "default_security_group_restriction" {
  command = plan

  variables {
    network = {
      vpc_id                          = "vpc-0123456789abcdef0"
      node_subnet_ids                 = ["subnet-0aaa", "subnet-0bbb"]
      public_subnet_ids               = ["subnet-0ccc", "subnet-0ddd"]
      restrict_default_security_group = true
    }
  }

  assert {
    condition     = length(aws_vpc_security_group_egress_rule.default_self) == 4 && length(terraform_data.revoke_default_egress) == 1
    error_message = "restrict_default_security_group must pin the minimum egress rules onto the EKS-managed group and schedule the allow-all revoke"
  }

  assert {
    condition = toset([
      for rule in aws_vpc_security_group_egress_rule.default_self : "${rule.ip_protocol}/${rule.from_port}"
    ]) == toset(["tcp/443", "tcp/10250", "tcp/53", "udp/53"])
    error_message = "the pinned egress must be exactly the documented minimum: 443 and 10250 (TCP) and 53 (TCP+UDP) to self"
  }
}

run "default_security_group_untouched_by_default" {
  command = plan

  assert {
    condition     = length(aws_vpc_security_group_egress_rule.default_self) == 0 && length(terraform_data.revoke_default_egress) == 0
    error_message = "without restrict_default_security_group the EKS-managed group must not be touched"
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
    error_message = "ENI mode requires native routing - tunnelling would defeat the point of VPC-addressed pods"
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
    error_message = "by default the ENI permissions sit on the node role - Pod Identity there is a bootstrap cycle (the agent add-on only installs once nodes exist)"
  }

  assert {
    condition     = length(aws_eks_pod_identity_association.cilium_operator) == 0
    error_message = "cilium.operator_pod_identity defaults off; the association must only exist when it is turned on"
  }
}

run "node_group_gates_on_cilium" {
  command = plan

  assert {
    condition     = module.system_node_group.labels["role"] == "system"
    error_message = "the system node group must carry the role=system label platform controllers pin to"
  }

  assert {
    condition = anytrue([
      for taint in module.system_node_group.taints :
      taint.key == "node.cilium.io/agent-not-ready" && taint.effect == "NO_EXECUTE"
    ])
    error_message = "nodes must be tainted until Cilium can address pods; the Cilium operator removes the taint once its agent is ready"
  }
}

run "additional_node_groups" {
  command = plan

  variables {
    node_groups = {
      workers = {
        labels = { role = "workers" }
      }
      win = {
        ami_type = "WINDOWS_CORE_2022_x86_64"
      }
    }
  }

  assert {
    condition = anytrue([
      for taint in module.node_group["workers"].taints :
      taint.key == "node.cilium.io/agent-not-ready" && taint.effect == "NO_EXECUTE"
    ])
    error_message = "Linux node groups must carry the Cilium bootstrap taint exactly like the system group"
  }

  assert {
    condition = !anytrue([
      for taint in module.node_group["win"].taints :
      taint.key == "node.cilium.io/agent-not-ready"
    ])
    error_message = "Windows nodes run no Cilium agent, so the bootstrap taint would never be removed and must not be applied"
  }

  assert {
    condition     = module.node_group["workers"].labels["role"] == "workers"
    error_message = "node group labels must pass through to the nodes"
  }

  assert {
    condition     = length(aws_iam_role.nodes_windows) == 1 && aws_eks_access_entry.nodes_windows["true"].type == "EC2_WINDOWS"
    error_message = "a WINDOWS_* group must elect the dedicated windows node role and its EC2_WINDOWS access entry into existence - an IAM principal carries exactly one access entry, so the Linux role cannot serve"
  }

  assert {
    condition     = length(local.registry_reader_principals) == 7
    error_message = "the windows node role pulls images too, so it must join the registry reader principals"
  }
}

run "no_windows_machinery_by_default" {
  command = plan

  assert {
    condition     = length(aws_iam_role.nodes_windows) == 0 && length(aws_eks_access_entry.nodes_windows) == 0
    error_message = "without a WINDOWS_* node group, no windows role or access entry may exist"
  }
}

run "node_groups_reject_the_system_key" {
  command = plan

  variables {
    node_groups = {
      system = {}
    }
  }

  expect_failures = [var.node_groups]
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
    condition     = length(aws_eks_pod_identity_association.workload) == length(local.workload_grants) - length(local.secret_reader_grants)
    error_message = "every pod-backed workload grant must get exactly one Pod Identity association; only the podless secret readers are excluded"
  }

  assert {
    condition     = length(setintersection(toset(keys(aws_eks_pod_identity_association.workload)), toset(keys(local.secret_reader_grants)))) == 0
    error_message = "the podless secret readers must never get a Pod Identity association: their KSAs back no pod, so they assume their roles via the IRSA trust instead"
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

  assert {
    condition     = aws_eks_pod_identity_association.ebs_csi["true"].namespace == "kube-system" && aws_eks_pod_identity_association.ebs_csi["true"].service_account == "ebs-csi-controller-sa"
    error_message = "the EBS CSI driver needs its own Pod Identity association: it calls the EC2 API and has no credential source otherwise"
  }

  assert {
    condition     = endswith(aws_iam_role_policy_attachment.ebs_csi["true"].policy_arn, "AmazonEBSCSIDriverPolicy")
    error_message = "the EBS CSI driver's role must carry the AWS managed AmazonEBSCSIDriverPolicy"
  }
}

run "cluster_vars_contract" {
  command = plan

  # aws_eks_cluster.main.endpoint is otherwise unknown until apply (it's a
  # brand-new resource in this plan, not a data source); override it and
  # pull the override forward into the plan phase so the
  # CILIUM_K8S_SERVICE_HOST assertion below can check the https:// strip
  # exactly, rather than just its shape.
  override_resource {
    target          = aws_eks_cluster.main
    override_during = plan
    values = {
      endpoint = "https://ABCDEF0123456789ABCDEF0123456789ABCDEF01.gr7.eu-west-2.eks.amazonaws.com"
      identity = [{
        oidc = [{
          issuer = "https://oidc.eks.eu-west-2.amazonaws.com/id/EXAMPLED539D4633E53DE1B71EXAMPLE"
        }]
      }]
    }
  }

  assert {
    condition     = local.reserved_cluster_vars.OCI_PROVIDER == "aws" && local.reserved_cluster_vars.ARTIFACT_TAG_PROVIDER == "ECRArtifactTag"
    error_message = "the flux controllers resolve ECR credentials via the aws OCI provider and the ECRArtifactTag RSIP type"
  }

  assert {
    condition     = !contains(keys(local.reserved_cluster_vars), "CLOUD")
    error_message = "the manifests are per-cloud trees (flux.sync.path selects aws) - nothing may publish or branch on a CLOUD var"
  }

  assert {
    condition     = local.reserved_cluster_vars.CLUSTER_NAME == "patchy-x"
    error_message = "CLUSTER_NAME is the cluster's identity throughout the stack (external-dns txtOwnerId and more)"
  }

  # Optional surfaces use the empty-string convention so substitution never
  # fails on an absent value.
  assert {
    condition = alltrue([
      for key in ["DNS_ZONE_NAME", "DNS_PUBLIC_ZONE_ID", "DNS_PRIVATE_ZONE_ID", "DNS_DOMAIN", "PLATFORM_DOMAIN", "ACME_EMAIL", "OTEL_AMP_ENDPOINT", "SIGNED_IDENTITY_KMS_KEY", "COSIGN_PUBLIC_KEY"] :
      local.reserved_cluster_vars[key] == ""
    ])
    error_message = "unset optional surfaces must publish empty strings, not null"
  }

  assert {
    condition     = local.reserved_cluster_vars.DEX_CONNECTORS == "[]" && local.reserved_cluster_vars.DEX_CLIENTS == "[]"
    error_message = "without sso, DEX_CONNECTORS and DEX_CLIENTS must publish the empty JSON array (not the empty string -- the manifests unconditionally mustFromJson-parse them)"
  }

  assert {
    condition     = local.reserved_cluster_vars.PLATFORM_COMPONENTS == "flux-web"
    error_message = "the default election is flux-web alone, comma-joined and sorted (arc is opt-in, dex rides sso)"
  }

  assert {
    condition     = local.reserved_cluster_vars.PLATFORM_TREE == "aws"
    error_message = "PLATFORM_TREE must publish flux.sync.path, so applications select the same per-cloud tree the platform syncs"
  }

  assert {
    condition     = endswith(local.reserved_cluster_vars.FLUX_SYNC_URL, "/manifests/platform") && startswith(local.reserved_cluster_vars.FLUX_SYNC_URL, "oci://${var.platform_registry.url}/")
    error_message = "the sync must default to the platform entrypoint image under the platform registry, and publish it so the flux component can re-point a running cluster"
  }

  # The generic-module guard: nothing application-specific may be published.
  assert {
    condition = length([
      for key in keys(local.reserved_cluster_vars) : key
      if key == "STACK_COMPONENTS" || startswith(key, "PATCHY_") || startswith(key, "CLAUDE_") || startswith(key, "AGENT_") || startswith(key, "KUBECTL_OIDC_")
    ]) == 0
    error_message = "the cluster module knows no application: no STACK_COMPONENTS, PATCHY_*, CLAUDE_*, AGENT_* or KUBECTL_OIDC_* key may be published (application vars ride in <key>-vars; the kubectl client rides in DEX_CLIENTS)"
  }

  assert {
    condition     = length([for key in keys(local.workload_grants) : key if startswith(key, "secrets-")]) == 0
    error_message = "without sso or caller-listed readers, no secret-reader role may exist - the module derives none from any application"
  }

  assert {
    condition     = local.reserved_cluster_vars.SIGNED_IDENTITY_MANIFESTS == var.signed_identity.manifests_subject
    error_message = "the manifests signing subject must reach the platform: its flux component re-renders the FluxInstance and needs it for the sync verify patch"
  }

  assert {
    condition     = local.reserved_cluster_vars.GATEWAY_NLB_TARGET_TYPE == "instance"
    error_message = "under a non-vpc-cni datapath the AWS Load Balancer Controller can only register instance targets"
  }

  assert {
    condition     = local.reserved_cluster_vars.GATEWAY_API_CRDS == "true"
    error_message = "gateway.install_crds defaults on: EKS ships no Gateway API CRDs, so the manifests must install them"
  }

  assert {
    condition     = local.reserved_cluster_vars.CILIUM_K8S_SERVICE_HOST == "ABCDEF0123456789ABCDEF0123456789ABCDEF01.gr7.eu-west-2.eks.amazonaws.com"
    error_message = "CILIUM_K8S_SERVICE_HOST must be the bare endpoint hostname (the https:// scheme stripped) -- the chart's k8sServiceHost value takes a host, not a URL"
  }

  assert {
    condition     = local.reserved_cluster_vars.CILIUM_POD_SUBNET_IDS == jsonencode(["subnet-0aaa", "subnet-0bbb"])
    error_message = "without network.pod_subnet_ids, the cilium component's eni.subnetIDsFilter must narrow to node_subnet_ids, JSON-encoded and sorted"
  }

  assert {
    condition     = length(module.flux_operator.applications) == 0 && length(output.flux.applications) == 0
    error_message = "a cluster with no applications seeds nothing - the platform alone is a complete deployment"
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

  # The manifests render each verified namespace's cosign-pub Secret from
  # this var, so it must carry the signing key's public half base64-encoded
  # (Secret data format).
  assert {
    condition     = base64decode(local.reserved_cluster_vars.COSIGN_PUBLIC_KEY) == "-----BEGIN PUBLIC KEY-----\nMOCK\n-----END PUBLIC KEY-----\n"
    error_message = "KMS mode must publish the signing key's public half as base64 PEM in COSIGN_PUBLIC_KEY"
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

  # name_prefix makes the generated names unknown until apply; pin them so
  # the contract assertions below can compare the published cluster vars
  # against the source attributes exactly.
  override_resource {
    target          = aws_iam_role.karpenter_node
    override_during = plan
    values = {
      name = "patchy-x-karpenter-node-20260903"
      arn  = "arn:aws:iam::123456789012:role/patchy-x-karpenter-node-20260903"
    }
  }

  override_resource {
    target          = aws_sqs_queue.karpenter_interruption
    override_during = plan
    values = {
      name = "patchy-x-karpenter-interruption-20260903"
      arn  = "arn:aws:sqs:eu-west-2:123456789012:patchy-x-karpenter-interruption-20260903"
    }
  }

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
    error_message = "the memory ceiling must carry its Gi unit - it lands directly in the NodePool's spec.limits"
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
    platform_components = []
  }

  assert {
    condition     = local.reserved_cluster_vars.PLATFORM_COMPONENTS == "none"
    error_message = "an explicitly empty election must publish the reserved name none - an empty string would re-trigger the manifests' elect-everything default"
  }

  assert {
    condition     = length(aws_secretsmanager_secret.dex_client) == 0 && length(aws_secretsmanager_secret.flux_web_auth_config) == 0
    error_message = "an unelected flux-web gets no client pair and no config document"
  }
}

run "platform_components_reject_unknown" {
  command = plan

  variables {
    platform_components = ["flux-web", "patchy"]
  }

  # patchy is an application, not a component: it arrives through
  # var.applications as its own image, never through the election.
  expect_failures = [var.platform_components]
}

run "arc_is_electable" {
  command = plan

  variables {
    platform_components = ["flux-web", "arc"]
  }

  assert {
    condition     = local.reserved_cluster_vars.PLATFORM_COMPONENTS == "arc,flux-web"
    error_message = "electing arc must publish it sorted into the election the platform entrypoint ranges over"
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
    condition     = local.reserved_cluster_vars.PLATFORM_DOMAIN == "patchy.bitwisemedia.co.uk"
    error_message = "the served host (PLATFORM_DOMAIN, the wildcard listener's apex) defaults to the zone apex unless dns.host narrows it"
  }

  assert {
    condition     = contains(keys(local.workload_grants), "external-dns") && contains(keys(local.workload_grants), "cert-manager")
    error_message = "the DNS surface must bring the Route53 grants with it"
  }

  assert {
    condition     = local.reserved_cluster_vars.DNS_PUBLIC_ZONE_ID != "" && local.reserved_cluster_vars.DNS_PRIVATE_ZONE_ID == ""
    error_message = "the public zone is unconditional with dns.zone_name, and the private id stays empty without the split-horizon election"
  }

  # One EIP per public subnet the Gateway's NLB spans - an NLB requirement, not
  # a per-host one. Every HTTPRoute hostname shares them.
  assert {
    condition     = length(aws_eip.gateway) == length(var.network.public_subnet_ids)
    error_message = "one Gateway address must be reserved per public subnet"
  }

  assert {
    condition     = local.reserved_cluster_vars.GATEWAY_NLB_SCHEME == "internet-facing" && local.reserved_cluster_vars.GATEWAY_SUBNETS == "subnet-0ccc,subnet-0ddd"
    error_message = "the default Gateway is an internet-facing NLB on the public subnets"
  }
}

run "dns_split_horizon" {
  command = plan

  variables {
    dns = {
      zone_name    = "patchy.bitwisemedia.co.uk"
      private_zone = true
      acme_email   = "platform@bitwisemedia.co.uk"
    }
  }

  # A private zone associated with the cluster VPC shadows the public one for
  # in-VPC resolution, so external-dns must be able to write records into both.
  assert {
    condition     = length(data.aws_route53_zone.cluster) == 2 && length(local.route53_zone_arns) == 2
    error_message = "enabling both zone flavours must look up both zones and grant record writes on each"
  }

  assert {
    condition     = local.dns_zone_kinds[0] == "public"
    error_message = "the public zone is unconditional - it must lead the flavour list, private riding alongside by election"
  }

  assert {
    condition     = local.reserved_cluster_vars.DNS_PUBLIC_ZONE_ID != "" && local.reserved_cluster_vars.DNS_PRIVATE_ZONE_ID != ""
    error_message = "split-horizon must publish both per-flavour zone ids so external-dns filters to exactly the pair"
  }
}

run "gateway_private" {
  command = plan

  variables {
    dns = {
      zone_name    = "patchy.bitwisemedia.co.uk"
      private_zone = true
      acme_email   = "platform@bitwisemedia.co.uk"
    }
    gateway = {
      private = true
    }
  }

  assert {
    condition     = local.reserved_cluster_vars.GATEWAY_NLB_SCHEME == "internal" && local.reserved_cluster_vars.GATEWAY_SUBNETS == "subnet-0aaa,subnet-0bbb"
    error_message = "a private Gateway must be an internal NLB spanning the node subnets"
  }

  # Internal NLBs cannot carry Elastic IPs: the reservation must go inert and
  # the manifests gate the eip-allocations annotation absent on the empty var.
  assert {
    condition     = length(aws_eip.gateway) == 0 && local.reserved_cluster_vars.GATEWAY_EIP_ALLOCATIONS == ""
    error_message = "a private Gateway must reserve no EIPs and publish an empty GATEWAY_EIP_ALLOCATIONS"
  }

  # Even a fully internal cluster keeps the public zone: cert-manager's DNS-01
  # challenges resolve over public DNS.
  assert {
    condition     = local.reserved_cluster_vars.DNS_PUBLIC_ZONE_ID != "" && local.reserved_cluster_vars.DNS_PRIVATE_ZONE_ID != ""
    error_message = "a private Gateway rides split-horizon: both zone flavours must publish their ids"
  }
}

run "gateway_private_requires_private_zone" {
  command = plan

  variables {
    dns = {
      zone_name  = "patchy.bitwisemedia.co.uk"
      acme_email = "platform@bitwisemedia.co.uk"
    }
    gateway = {
      private = true
    }
  }

  expect_failures = [var.gateway]
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
      connector = {
        type = "google"
        config = {
          clientID                       = "$GOOGLE_CLIENT_ID"
          fetchTransitiveGroupMembership = true
        }
      }
      clients = {
        flux-web = { version = 3 }
      }
    }
    secret_prefix = "patchy-x-"
  }

  assert {
    condition     = local.reserved_cluster_vars.PLATFORM_COMPONENTS == "dex,flux-web"
    error_message = "dex is not elected directly - it joins the election exactly when sso is on"
  }

  # DEX_CLIENTS carries every relying party dex renders: the platform's
  # flux-web client here (sso.kubectl is off), in the shape the dex component
  # ranges over.
  assert {
    condition     = jsondecode(local.reserved_cluster_vars.DEX_CLIENTS) == [{ id = "flux-web", name = "Flux Status", public = false, redirectURIs = ["https://flux.patchy.bitwisemedia.co.uk/oauth2/callback"] }]
    error_message = "with flux-web elected and sso on, DEX_CLIENTS must publish exactly the flux-web confidential client with its callback on the served domain"
  }

  assert {
    condition     = [for c in jsondecode(local.reserved_cluster_vars.DEX_CONNECTORS) : c.id][0] == "google"
    error_message = "an unset connector id must default to the connector type"
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

  # Regression guard for the map(any) footgun: config typed as map(any)
  # unifies its value types and stringifies bools ("true"), which dex then
  # rejects at startup (cannot unmarshal string into bool). Bare any on a
  # single connector object faces no unification -- see the sso variable's
  # type comment.
  assert {
    condition     = [for c in jsondecode(local.reserved_cluster_vars.DEX_CONNECTORS) : c.config.fetchTransitiveGroupMembership][0] == true
    error_message = "connector config values must keep their native JSON types -- a bool must publish as true, not the string \"true\""
  }

  assert {
    condition     = toset([for c in jsondecode(local.reserved_cluster_vars.DEX_CONNECTORS) : c.secrets][0]) == toset(["client-id", "client-secret"])
    error_message = "an unset connector secrets set must default to the client-id/client-secret pair"
  }

  assert {
    condition     = length(aws_secretsmanager_secret.dex_client) == 1 && aws_secretsmanager_secret.dex_client["flux-web"].name == "patchy-x-dex-client-flux-web"
    error_message = "the one elected confidential relying party must get a generated client pair under the secret prefix"
  }

  assert {
    condition     = aws_secretsmanager_secret_version.dex_client["flux-web"].secret_string_wo_version == 3 && aws_secretsmanager_secret_version.flux_web_auth_config[0].secret_string_wo_version == 3
    error_message = "a client's version must drive both the raw secret and the composed config document, so a bump rotates the pair together"
  }

  assert {
    condition     = local.secret_reader_roles["dex-client-flux-web"].roles == ["secrets-dex-dex-secrets"]
    error_message = "a platform client's raw secret is readable by dex alone"
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
      connector = {
        id      = "okta"
        type    = "oidc"
        name    = "Okta"
        secrets = ["client-id", "client-secret", "api-token"]
      }
    }
  }

  # The credential containers themselves live in modules/secrets (a durable
  # root, fed the same sso value) -- this run asserts only the cluster-side
  # half: the published declaration and the unchanged generated pairs.
  assert {
    condition = toset([for c in jsondecode(local.reserved_cluster_vars.DEX_CONNECTORS) : c.secrets][0]) == toset([
      "client-id", "client-secret", "api-token"
    ])
    error_message = "an explicit secrets set must publish verbatim -- modules/secrets names the dex-<id>-<field> containers from it"
  }

  assert {
    condition     = [for c in jsondecode(local.reserved_cluster_vars.DEX_CONNECTORS) : c.id][0] == "okta"
    error_message = "an explicit connector id must win over the type default"
  }

  assert {
    condition     = [for c in jsondecode(local.reserved_cluster_vars.DEX_CONNECTORS) : c.name][0] == "Okta"
    error_message = "an explicit connector name must pass through to DEX_CONNECTORS untouched"
  }

  assert {
    condition     = length(aws_secretsmanager_secret.dex_client) == 1
    error_message = "the generated client pairs are independent of the connector declarations"
  }
}

run "sso_requires_connector" {
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

run "sso_clients_reject_unknown_ids" {
  command = plan

  variables {
    sso = {
      clients = {
        dex = { version = 2 }
      }
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

  # The manifests bind group NAMES - never the IAM principals behind them.
  assert {
    condition     = local.reserved_cluster_vars.RBAC_GROUP_ADMINS == "platform:admins"
    error_message = "RBAC_GROUP_* must publish the Kubernetes group names, not the principal ARNs"
  }

  assert {
    condition     = local.reserved_cluster_vars.RBAC_GROUP_DEVOPS == ""
    error_message = "unbound roles must publish empty strings"
  }
}

run "rbac_oidc_only_role_gets_no_access_entry" {
  command = plan

  variables {
    rbac = {
      enabled = true
      groups = {
        admins = { group = "oidc:GRP_PATCHY_NONPROD_ADMIN" }
      }
    }
  }

  # A role with no principal_arn is federated purely through OIDC (sso.kubectl)
  # -- it must still publish its group so the manifests bind it, but it must
  # never get an IAM access entry, which requires a principal.
  assert {
    condition     = length(aws_eks_access_entry.rbac) == 0
    error_message = "a role with no principal_arn must not get an access entry"
  }

  assert {
    condition     = local.reserved_cluster_vars.RBAC_GROUP_ADMINS == "oidc:GRP_PATCHY_NONPROD_ADMIN"
    error_message = "an OIDC-only role's group must still publish to RBAC_GROUP_* for the manifests to bind"
  }
}

run "kubectl_oidc_federation" {
  command = plan

  variables {
    dns = {
      zone_name  = "patchy.bitwisemedia.co.uk"
      acme_email = "platform@bitwisemedia.co.uk"
    }
    sso = {
      enabled = true
      connector = {
        id   = "okta"
        type = "oidc"
      }
      kubectl = {
        enabled = true
      }
    }
  }

  assert {
    condition     = length(aws_eks_identity_provider_config.dex) == 1
    error_message = "sso.kubectl.enabled must create exactly one identity provider config"
  }

  assert {
    condition     = aws_eks_identity_provider_config.dex[0].oidc[0].issuer_url == "https://dex.patchy.bitwisemedia.co.uk"
    error_message = "the identity provider config must trust the same dex issuer the web relying parties use"
  }

  assert {
    condition     = aws_eks_identity_provider_config.dex[0].oidc[0].groups_prefix == "oidc:"
    error_message = "groups_claim_prefix must default to a non-empty prefix so an asserted claim can't collide with system: or IAM-sourced group names"
  }

  # The kubectl client is a PUBLIC dex client (PKCE, no secret) published in
  # DEX_CLIENTS beside flux-web - there is no KUBECTL_OIDC_* surface.
  assert {
    condition     = one([for c in jsondecode(local.reserved_cluster_vars.DEX_CLIENTS) : c if c.id == "kubectl-oidc"]).public == true
    error_message = "enabling kubectl OIDC must publish a public kubectl-oidc client in DEX_CLIENTS for the dex component to render"
  }

  assert {
    condition     = one([for c in jsondecode(local.reserved_cluster_vars.DEX_CLIENTS) : c if c.id == "kubectl-oidc"]).redirectURIs == ["http://localhost:8000/callback"]
    error_message = "the kubectl client must register kubelogin's redirect URIs verbatim"
  }

  assert {
    condition     = !contains(keys(aws_secretsmanager_secret.dex_client), "kubectl-oidc")
    error_message = "a public client mints no secret"
  }
}

run "kubectl_oidc_requires_sso" {
  command = plan

  variables {
    sso = {
      kubectl = { enabled = true }
    }
  }

  expect_failures = [var.sso]
}

run "kubectl_oidc_groups_prefix_must_be_nonempty" {
  command = plan

  variables {
    dns = {
      zone_name  = "patchy.bitwisemedia.co.uk"
      acme_email = "platform@bitwisemedia.co.uk"
    }
    sso = {
      enabled = true
      connector = {
        type = "google"
      }
      kubectl = {
        enabled             = true
        groups_claim_prefix = ""
      }
    }
  }

  expect_failures = [var.sso]
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

run "workload_grants_become_pod_identity" {
  command = plan

  variables {
    workload_grants = {
      egress-broker = {
        namespace       = "demo"
        service_account = "demo-egress-broker"
        policy          = "{\"Version\":\"2012-10-17\",\"Statement\":[{\"Effect\":\"Allow\",\"Action\":[\"bedrock:InvokeModel\"],\"Resource\":\"*\"}]}"
      }
    }
    workload_identity = {
      secret_readers = [{ namespace = "demo", service_account = "demo-secrets" }]
    }
  }

  # An application's cloud grant arrives as data: the module mints the role
  # (<cluster>-<key>, so an application module can name it from the static
  # rule) and binds it through Pod Identity, verbatim policy attached.
  assert {
    condition     = aws_iam_role.workload["egress-broker"].name == "patchy-x-egress-broker"
    error_message = "a workload_grants entry must become a role named <cluster>-<key>"
  }

  assert {
    condition     = aws_eks_pod_identity_association.workload["egress-broker"].namespace == "demo" && aws_eks_pod_identity_association.workload["egress-broker"].service_account == "demo-egress-broker"
    error_message = "a workload_grants entry must bind its pair through a Pod Identity association"
  }

  assert {
    condition     = strcontains(aws_iam_role_policy.workload["egress-broker"].policy, "bedrock:InvokeModel")
    error_message = "the caller's policy document must attach verbatim"
  }

  # The podless readers stay the IRSA exception, keyed by the published rule.
  assert {
    condition     = contains(keys(local.secret_reader_grants), "secrets-demo-demo-secrets") && !contains(keys(aws_eks_pod_identity_association.workload), "secrets-demo-demo-secrets")
    error_message = "a caller-listed secret reader must get an IRSA role and never a Pod Identity association"
  }

  assert {
    condition     = output.secrets_role_prefix == "arn:aws:iam::123456789012:role/patchy-x-secrets-"
    error_message = "the reader role prefix must be exported so application wiring can compose <prefix><ns>-<sa>"
  }

  assert {
    condition     = contains(keys(output.workload_roles), "egress-broker") && contains(keys(output.workload_roles), "secrets-demo-demo-secrets")
    error_message = "every minted role must be exported by its key"
  }
}

run "workload_grants_reject_platform_keys" {
  command = plan

  variables {
    workload_grants = {
      external-dns = { namespace = "x", service_account = "y", policy = "{}" }
    }
  }

  expect_failures = [var.workload_grants]
}

run "applications_seeded" {
  command = plan

  variables {
    applications = {
      demo = {
        url        = "oci://123456789012.dkr.ecr.eu-west-2.amazonaws.com/platform/manifests/demo"
        semver     = "<1.0.0 >=0.1.0"
        depends_on = ["kyverno-policies", "gateway"]
        verify     = { subject = "^https://github\\.com/org/demo-app-manifests/\\.github/workflows/publish\\.yaml@refs/tags/v.+$" }
      }
      external = {
        url         = "oci://ghcr.io/org/external-manifests"
        path        = "./deploy/eks"
        verify      = { issuer = "^https://token\\.actions\\.githubusercontent\\.com$", subject = "^https://github\\.com/org/external/.+$" }
        pull_secret = "ghcr-pull"
      }
    }
  }

  # The registry, never the cloud, picks the listing/pull dialect: under the
  # platform prefix the flux controllers reach ECR with their Pod Identity;
  # anywhere else is a generic OCI listing and pull.
  assert {
    condition     = output.flux.applications["demo"].tag_provider == "ECRArtifactTag" && output.flux.applications["demo"].oci_provider == "aws"
    error_message = "an image under the platform registry must be listed with ECRArtifactTag and pulled as provider aws"
  }

  assert {
    condition     = output.flux.applications["external"].tag_provider == "OCIArtifactTag" && output.flux.applications["external"].oci_provider == "generic"
    error_message = "an image outside the platform registry must be listed with OCIArtifactTag and pulled as provider generic"
  }

  # Defaults resolve against cluster facts: the per-cloud tree the platform
  # syncs, and the platform's own keyless issuer.
  assert {
    condition     = output.flux.applications["demo"].path == "./deploy/aws" && output.flux.applications["external"].path == "./deploy/eks"
    error_message = "path must default to ./deploy/<flux.sync.path> and pass through when set"
  }

  assert {
    condition     = local.applications["demo"].verify.issuer == var.signed_identity.issuer && local.applications["external"].verify.issuer == "^https://token\\.actions\\.githubusercontent\\.com$"
    error_message = "a keyless application's issuer must default to signed_identity.issuer and pass through when set"
  }

  assert {
    condition     = output.flux.applications["demo"].release == "application-demo" && output.flux.applications["demo"].namespace == "flux-system"
    error_message = "each application must seed one bootstrap-only release in flux-system"
  }

  assert {
    condition     = length(aws_secretsmanager_secret.dex_client) == 0
    error_message = "applications without dex clients mint no secrets"
  }
}

run "applications_reject_unverified" {
  command = plan

  variables {
    applications = {
      demo = {
        url    = "oci://123456789012.dkr.ecr.eu-west-2.amazonaws.com/platform/manifests/demo"
        verify = {}
      }
    }
  }

  expect_failures = [var.applications]
}

run "applications_reject_keyed_without_kms" {
  command = plan

  variables {
    applications = {
      demo = {
        url    = "oci://123456789012.dkr.ecr.eu-west-2.amazonaws.com/platform/manifests/demo"
        verify = { keyed = true }
      }
    }
  }

  expect_failures = [var.applications]
}

run "applications_reject_foreign_ecr" {
  command = plan

  variables {
    applications = {
      demo = {
        url    = "oci://999988887777.dkr.ecr.eu-west-2.amazonaws.com/other/manifests/demo"
        verify = { subject = "^https://github\\.com/org/demo/.+$" }
      }
    }
  }

  # The flux controllers hold pull rights on the platform prefix alone, so an
  # ECR image anywhere else could never be listed or pulled.
  expect_failures = [var.applications]
}

run "applications_reject_platform_names" {
  command = plan

  variables {
    applications = {
      kyverno = {
        url    = "oci://123456789012.dkr.ecr.eu-west-2.amazonaws.com/platform/manifests/kyverno"
        verify = { subject = "^https://github\\.com/org/kyverno/.+$" }
      }
    }
  }

  expect_failures = [var.applications]
}

run "applications_reject_tagged_url" {
  command = plan

  variables {
    applications = {
      demo = {
        url    = "oci://123456789012.dkr.ecr.eu-west-2.amazonaws.com/platform/manifests/demo:1.2.3"
        verify = { subject = "^https://github\\.com/org/demo/.+$" }
      }
    }
  }

  expect_failures = [var.applications]
}

run "application_dex_clients" {
  command = plan

  variables {
    dns = {
      zone_name  = "patchy.bitwisemedia.co.uk"
      acme_email = "platform@bitwisemedia.co.uk"
    }
    sso = {
      enabled   = true
      connector = { type = "google" }
    }
    secret_prefix = "patchy-x-"
    workload_identity = {
      secret_readers = [{ namespace = "demo", service_account = "demo-secrets" }]
    }
    applications = {
      demo = {
        url    = "oci://123456789012.dkr.ecr.eu-west-2.amazonaws.com/platform/manifests/demo"
        verify = { subject = "^https://github\\.com/org/demo/.+$" }
        dex_clients = {
          demo-status = {
            name          = "Demo Status"
            redirect_uris = ["https://demo.patchy.bitwisemedia.co.uk/auth/callback"]
            readers       = ["demo/demo-secrets"]
            version       = 2
          }
          demo-cli = {
            public        = true
            redirect_uris = ["http://localhost:9000/callback"]
          }
        }
      }
    }
  }

  # Every client, platform and application, lands in the one DEX_CLIENTS
  # list the dex component renders from, sorted by id.
  assert {
    condition     = [for c in jsondecode(local.reserved_cluster_vars.DEX_CLIENTS) : c.id] == ["demo-cli", "demo-status", "flux-web"]
    error_message = "DEX_CLIENTS must carry the application's clients beside the platform's, sorted by id"
  }

  assert {
    condition     = one([for c in jsondecode(local.reserved_cluster_vars.DEX_CLIENTS) : c if c.id == "demo-cli"]).name == "demo-cli"
    error_message = "a client's display name must default to its id"
  }

  # A confidential client mints its secret under the static name the
  # application's own wiring can predict; a public client mints nothing.
  assert {
    condition     = aws_secretsmanager_secret.dex_client["demo-status"].name == "patchy-x-dex-client-demo-status" && !contains(keys(aws_secretsmanager_secret.dex_client), "demo-cli")
    error_message = "a confidential application client must mint <prefix>dex-client-<id>; a public one must not"
  }

  assert {
    condition     = aws_secretsmanager_secret_version.dex_client["demo-status"].secret_string_wo_version == 2
    error_message = "an application client's version must drive its secret's rotation"
  }

  # dex always reads the raw secret; the client's declared readers (the
  # application's own sync KSAs) join it.
  assert {
    condition     = toset(local.secret_reader_roles["dex-client-demo-status"].roles) == toset(["secrets-dex-dex-secrets", "secrets-demo-demo-secrets"])
    error_message = "a confidential client's secret must admit dex and exactly the readers the client declares"
  }

  assert {
    condition     = output.sso.clients["demo-status"].public == false && output.sso.clients["demo-cli"].public == true
    error_message = "the sso output must list every registered client with its kind"
  }
}

run "application_dex_client_requires_sso" {
  command = plan

  variables {
    applications = {
      demo = {
        url         = "oci://123456789012.dkr.ecr.eu-west-2.amazonaws.com/platform/manifests/demo"
        verify      = { subject = "^https://github\\.com/org/demo/.+$" }
        dex_clients = { demo-status = {} }
      }
    }
  }

  expect_failures = [var.applications]
}

run "application_dex_client_rejects_platform_ids" {
  command = plan

  variables {
    dns = {
      zone_name  = "patchy.bitwisemedia.co.uk"
      acme_email = "platform@bitwisemedia.co.uk"
    }
    sso = {
      enabled   = true
      connector = { type = "google" }
    }
    applications = {
      demo = {
        url         = "oci://123456789012.dkr.ecr.eu-west-2.amazonaws.com/platform/manifests/demo"
        verify      = { subject = "^https://github\\.com/org/demo/.+$" }
        dex_clients = { flux-web = {} }
      }
    }
  }

  expect_failures = [var.applications]
}

run "application_dex_client_ids_unique_across_apps" {
  command = plan

  variables {
    dns = {
      zone_name  = "patchy.bitwisemedia.co.uk"
      acme_email = "platform@bitwisemedia.co.uk"
    }
    sso = {
      enabled   = true
      connector = { type = "google" }
    }
    applications = {
      one = {
        url         = "oci://123456789012.dkr.ecr.eu-west-2.amazonaws.com/platform/manifests/one"
        verify      = { subject = "^https://github\\.com/org/one/.+$" }
        dex_clients = { status = { public = true } }
      }
      two = {
        url         = "oci://123456789012.dkr.ecr.eu-west-2.amazonaws.com/platform/manifests/two"
        verify      = { subject = "^https://github\\.com/org/two/.+$" }
        dex_clients = { status = { public = true } }
      }
    }
  }

  expect_failures = [var.applications]
}

run "application_dex_client_readers_must_be_declared" {
  command = plan

  variables {
    dns = {
      zone_name  = "patchy.bitwisemedia.co.uk"
      acme_email = "platform@bitwisemedia.co.uk"
    }
    sso = {
      enabled   = true
      connector = { type = "google" }
    }
    applications = {
      demo = {
        url         = "oci://123456789012.dkr.ecr.eu-west-2.amazonaws.com/platform/manifests/demo"
        verify      = { subject = "^https://github\\.com/org/demo/.+$" }
        dex_clients = { demo-status = { readers = ["demo/demo-secrets"] } }
      }
    }
  }

  # A reader with no role behind it (not listed in
  # workload_identity.secret_readers) could never be admitted.
  expect_failures = [var.applications]
}

run "application_vars_render" {
  command = plan

  variables {
    application_vars = {
      demo = {
        DEMO_DOMAIN    = "demo.example.com"
        DEMO_HARNESSES = "claude"
      }
    }
  }

  # The rendering itself (one <key>-vars ConfigMap per entry) is asserted in
  # the flux-operator module's own suite; here the contract is separation.
  assert {
    condition     = !contains(keys(local.reserved_cluster_vars), "DEMO_DOMAIN") && !contains(keys(output.flux.cluster_vars), "DEMO_DOMAIN")
    error_message = "application vars must never leak into cluster-vars"
  }
}

run "application_vars_reject_lowercase_keys" {
  command = plan

  variables {
    application_vars = {
      demo = { demoDomain = "x" }
    }
  }

  expect_failures = [var.application_vars]
}
