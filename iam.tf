# Copyright 2026 BitWise Media Group Ltd
# SPDX-License-Identifier: MIT

# IAM identities for the flux-deployed workloads. The platform's
# namespace/service-account pairs are the terraform <-> platform-manifests
# contract (overridable via var.workload_identity so this repo can track a
# manifests change without a schema change) - the pairs themselves are
# cloud-neutral, so every cluster consumes the same manifests. Application
# grants arrive through the generic var.workload_grants map (a role and a Pod
# Identity association per entry) and var.workload_identity.secret_readers
# (podless IRSA readers); this module knows no application by name.
#
# Workloads with a real pod bind through EKS Pod Identity associations. The
# secret readers are the one exception: the secrets-store-sync-controller
# materialises each SecretSync WITHOUT a pod, minting the sync KSA's token via
# the TokenRequest API - and a token with no pod behind it lacks the
# kubernetes.io/pod claim Pod Identity's AssumeRoleForPodIdentity requires, so
# an association could never be exercised. The podless path is IRSA:
# AssumeRoleWithWebIdentity needs only the SA-scoped OIDC token, so the
# cluster's issuer is registered as an IAM OIDC provider and each reader role
# trusts its own system:serviceaccount subject. The manifests point each sync
# KSA at its role through the eks.amazonaws.com/role-arn annotation, composed
# from the SECRETS_ROLE_PREFIX cluster var (flux.tf) - role names are
# deterministic, so one prefix covers every pair.
#
# flux-system's own associations (source-controller, flux-operator) live in
# modules/flux-operator/iam.tf next to the workloads they serve. Karpenter's
# lives in karpenter.tf, and Cilium's in cilium.tf, each beside the rest of
# their wiring.

data "aws_iam_policy_document" "pod_identity_assume_role" {
  statement {
    actions = ["sts:AssumeRole", "sts:TagSession"]

    principals {
      type        = "Service"
      identifiers = ["pods.eks.amazonaws.com"]
    }
  }
}

data "tls_certificate" "cluster" {
  url = aws_eks_cluster.main.identity[0].oidc[0].issuer
}

resource "aws_iam_openid_connect_provider" "irsa" {
  url             = aws_eks_cluster.main.identity[0].oidc[0].issuer
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.cluster.certificates[0].sha1_fingerprint]

  tags = var.tags
}

data "aws_iam_policy_document" "irsa_assume_role" {
  for_each = local.secret_reader_grants

  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.irsa.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.oidc_issuer_host}:sub"
      values   = ["system:serviceaccount:${each.value.namespace}:${each.value.service_account}"]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.oidc_issuer_host}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

locals {
  route53_zone_arns = [
    for zone in data.aws_route53_zone.cluster : "arn:${local.partition}:route53:::hostedzone/${zone.zone_id}"
  ]

  secret_arn_pattern = "arn:${local.partition}:secretsmanager:${data.aws_region.current.region}:${local.account_id}:secret:${local.secret_prefix}*"

  # The issuer URL as an IAM condition-key host - the sub/aud keys on the OIDC
  # provider's trust conditions are the issuer with its scheme stripped.
  oidc_issuer_host = trimprefix(aws_eks_cluster.main.identity[0].oidc[0].issuer, "https://")

  # The KSAs the secrets-store-sync-controller runs as, one per consuming
  # namespace: the pairs the SSO surface implies (derived in sso.tf from the
  # election) plus every pair the caller names (an application module's
  # secret_readers output, wired through workload_identity.secret_readers)
  # -- setunion(), because the two may overlap and a for-expression errors on
  # a duplicate key. Scoped to this cluster's SECRET_PREFIX so clusters
  # sharing an account cannot read each other's secrets; each
  # module-authored secret's own policy (sso.tf) narrows it further.
  # Kept apart from the pod-bound grants because these roles trust the IRSA
  # OIDC provider, not Pod Identity (see the header comment).
  secret_reader_grants = {
    for reader in setunion(local.sso_secret_readers, var.workload_identity.secret_readers) :
    "secrets-${reader.namespace}-${reader.service_account}" => {
      namespace       = reader.namespace
      service_account = reader.service_account
      policy          = data.aws_iam_policy_document.secret_read.json
    }
  }

  # name -> { namespace, service_account, policy }. Every entry becomes one IAM
  # role and one inline policy; every entry except the podless secret readers
  # also becomes a Pod Identity association. The platform's grants first,
  # then the caller's application grants (var.workload_grants, whose keys are
  # validated never to collide), then the secret readers.
  workload_grants = merge(
    # DNS-01 challenges and record publication both need the same write on the
    # delegated zone; absent entirely when the DNS surface is off.
    var.dns.zone_name == null ? {} : {
      external-dns = {
        namespace       = var.workload_identity.external_dns.namespace
        service_account = var.workload_identity.external_dns.service_account
        policy          = data.aws_iam_policy_document.route53[0].json
      }
      cert-manager = {
        namespace       = var.workload_identity.cert_manager.namespace
        service_account = var.workload_identity.cert_manager.service_account
        policy          = data.aws_iam_policy_document.route53[0].json
      }
    },
    {
      otel-collector = {
        namespace       = var.workload_identity.otel_collector.namespace
        service_account = var.workload_identity.otel_collector.service_account
        policy          = data.aws_iam_policy_document.otel_collector.json
      }
      aws-load-balancer-controller = {
        namespace       = var.workload_identity.load_balancer.namespace
        service_account = var.workload_identity.load_balancer.service_account
        policy          = data.aws_iam_policy_document.load_balancer_controller.json
      }
    },
    # kyverno fetches image signatures from the registry at admission time, so
    # its controllers read the platform registry like the flux controllers do
    # (plus the KMS verify grant when that is the signing mode).
    {
      for service_account in var.workload_identity.kyverno.service_accounts :
      "kyverno-${service_account}" => {
        namespace       = var.workload_identity.kyverno.namespace
        service_account = service_account
        policy          = data.aws_iam_policy_document.kyverno.json
      }
    },
    # Application grants, verbatim: the policy document is the application
    # module's to write (a model-invoke grant, a bucket, a queue); this module
    # only mints the role and binds it to the pair.
    var.workload_grants,
    local.secret_reader_grants,
  )
}

data "aws_iam_policy_document" "route53" {
  count = var.dns.zone_name != null ? 1 : 0

  statement {
    sid       = "ChangeRecords"
    effect    = "Allow"
    actions   = ["route53:ChangeResourceRecordSets"]
    resources = local.route53_zone_arns
  }

  statement {
    sid    = "ReadZones"
    effect = "Allow"

    actions = [
      "route53:ListHostedZones",
      "route53:ListHostedZonesByName",
      "route53:ListResourceRecordSets",
      "route53:GetChange",
    ]

    resources = ["*"]
  }
}

data "aws_iam_policy_document" "otel_collector" {
  statement {
    sid    = "WriteTelemetry"
    effect = "Allow"

    actions = [
      "logs:CreateLogGroup",
      "logs:CreateLogStream",
      "logs:PutLogEvents",
      "logs:DescribeLogGroups",
      "logs:DescribeLogStreams",
      "cloudwatch:PutMetricData",
      "xray:PutTraceSegments",
      "xray:PutTelemetryRecords",
      "xray:GetSamplingRules",
      "xray:GetSamplingTargets",
    ]

    resources = ["*"]
  }

  # Only when a Managed Prometheus workspace is the metrics target.
  dynamic "statement" {
    for_each = var.observability.amp_endpoint != null ? ["true"] : []

    content {
      sid       = "RemoteWrite"
      effect    = "Allow"
      actions   = ["aps:RemoteWrite"]
      resources = ["*"]
    }
  }
}

# The controller exists to provision the NLB behind the Cilium Gateway (and to
# bind the reserved EIPs to it); it is not an ingress path of its own.
data "aws_iam_policy_document" "load_balancer_controller" {
  statement {
    sid    = "Describe"
    effect = "Allow"

    actions = [
      "ec2:DescribeAccountAttributes",
      "ec2:DescribeAddresses",
      "ec2:DescribeAvailabilityZones",
      "ec2:DescribeInstances",
      "ec2:DescribeInternetGateways",
      "ec2:DescribeNetworkInterfaces",
      "ec2:DescribeSecurityGroups",
      "ec2:DescribeSubnets",
      "ec2:DescribeTags",
      "ec2:DescribeVpcs",
      "elasticloadbalancing:Describe*",
      "acm:DescribeCertificate",
      "acm:ListCertificates",
    ]

    resources = ["*"]
  }

  statement {
    sid    = "ManageLoadBalancers"
    effect = "Allow"

    actions = [
      "elasticloadbalancing:AddTags",
      "elasticloadbalancing:RemoveTags",
      "elasticloadbalancing:CreateLoadBalancer",
      "elasticloadbalancing:DeleteLoadBalancer",
      "elasticloadbalancing:ModifyLoadBalancerAttributes",
      "elasticloadbalancing:SetSubnets",
      "elasticloadbalancing:SetSecurityGroups",
      "elasticloadbalancing:CreateTargetGroup",
      "elasticloadbalancing:DeleteTargetGroup",
      "elasticloadbalancing:ModifyTargetGroup",
      "elasticloadbalancing:ModifyTargetGroupAttributes",
      "elasticloadbalancing:RegisterTargets",
      "elasticloadbalancing:DeregisterTargets",
      "elasticloadbalancing:CreateListener",
      "elasticloadbalancing:DeleteListener",
      "elasticloadbalancing:ModifyListener",
      "ec2:CreateSecurityGroup",
      "ec2:DeleteSecurityGroup",
      "ec2:AuthorizeSecurityGroupIngress",
      "ec2:RevokeSecurityGroupIngress",
      "ec2:CreateTags",
      "ec2:DeleteTags",
    ]

    resources = ["*"]
  }
}

data "aws_iam_policy_document" "registry_read" {
  statement {
    sid       = "Authorize"
    effect    = "Allow"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }

  statement {
    sid    = "Pull"
    effect = "Allow"

    actions = [
      "ecr:BatchGetImage",
      "ecr:GetDownloadUrlForLayer",
      "ecr:BatchCheckLayerAvailability",
      "ecr:DescribeImages",
      "ecr:ListImages",
    ]

    resources = [local.registry_arn]
  }

  # A pull-through cache materialises a repository on the FIRST pull of each
  # image, so every puller needs create/import as well as read.
  dynamic "statement" {
    for_each = var.platform_registry.is_pull_through_cache ? ["true"] : []

    content {
      sid    = "CacheFill"
      effect = "Allow"

      actions = [
        "ecr:CreateRepository",
        "ecr:BatchImportUpstreamImage",
        "ecr:GetImageCopyStatus",
      ]

      resources = [local.registry_arn]
    }
  }
}

# kyverno's image policy verifies signatures at admission/report time: always
# a registry reader, and in KMS signing mode also allowed to resolve the
# signing key (cosign's awskms:///<arn> path fetches the public key and may
# verify remotely).
data "aws_iam_policy_document" "kyverno" {
  source_policy_documents = [data.aws_iam_policy_document.registry_read.json]

  dynamic "statement" {
    for_each = local.signing_kms ? ["true"] : []

    content {
      sid       = "VerifySignatures"
      effect    = "Allow"
      actions   = ["kms:GetPublicKey", "kms:Verify"]
      resources = [var.signed_identity.kms_key_arn]
    }
  }
}

data "aws_iam_policy_document" "secret_read" {
  statement {
    sid    = "ReadSecrets"
    effect = "Allow"

    actions = [
      "secretsmanager:GetSecretValue",
      "secretsmanager:DescribeSecret",
    ]

    resources = [local.secret_arn_pattern]
  }
}

resource "aws_iam_role" "workload" {
  for_each = local.workload_grants

  # A fixed name, never name_prefix: the secret-reader role names are a
  # published contract - the manifests compose ${SECRETS_ROLE_PREFIX}<ns>-<sa>
  # (flux.tf) into each sync KSA's role-arn annotation, so the names must stay
  # deterministic.
  name        = "${var.name}-${each.key}"
  description = "Workload ${each.value.namespace}/${each.value.service_account} (${var.name})"

  # The podless secret readers trust the IRSA OIDC provider; everything with a
  # real pod trusts Pod Identity (see the header comment).
  assume_role_policy = (
    contains(keys(local.secret_reader_grants), each.key)
    ? data.aws_iam_policy_document.irsa_assume_role[each.key].json
    : data.aws_iam_policy_document.pod_identity_assume_role.json
  )

  tags = var.tags
}

resource "aws_iam_role_policy" "workload" {
  for_each = local.workload_grants

  name   = "workload"
  role   = aws_iam_role.workload[each.key].id
  policy = each.value.policy
}

resource "aws_eks_pod_identity_association" "workload" {
  # Every grant except the podless secret readers: their KSAs never back a
  # pod, so an association could never be exercised - they assume their roles
  # through the IRSA trust above instead.
  for_each = {
    for key, grant in local.workload_grants : key => grant
    if !contains(keys(local.secret_reader_grants), key)
  }

  cluster_name    = aws_eks_cluster.main.name
  namespace       = each.value.namespace
  service_account = each.value.service_account
  role_arn        = aws_iam_role.workload[each.key].arn

  tags = var.tags

  # Associations are accepted before the agent exists, but nothing can resolve
  # credentials until it does - ordering them keeps a fresh apply honest.
  depends_on = [aws_eks_addon.pod_identity_agent]
}

locals {
  # Every identity that reads the platform registry. When platform_registry is
  # a pull-through cache in this account the grants above are sufficient;
  # when it points straight at a central store, these are the principals the
  # store's direct_pull_principals must admit.
  registry_reader_principals = concat(
    [
      aws_iam_role.nodes.arn,
      aws_iam_role.karpenter_node.arn,
    ],
    [for role in aws_iam_role.nodes_windows : role.arn],
    [for role in module.flux_operator.registry_reader_roles : role],
    [
      for service_account in var.workload_identity.kyverno.service_accounts :
      aws_iam_role.workload["kyverno-${service_account}"].arn
    ],
  )
}
