# Copyright 2026 BitWise Media Group Ltd
# SPDX-License-Identifier: MIT

# Every surface on: a pull-through cache of the central store, the DNS/TLS
# wiring, reserved Gateway addresses, RBAC access entries, SSO, the staging sync
# channel, the electable platform components and one seeded application
# (patchy) composed the way a real root composes it - the application's own
# module emits the maps, the cluster module consumes them, and nothing
# application-specific lives in the cluster module.
#
# PREREQUISITES this example does not create (they live upstream):
#
#   - the VPC, its private node subnets and public subnets, with NAT or the
#     ECR/S3/STS/EKS VPC endpoints nodes need to pull images and reach the API
#   - the delegated Route53 hosted zone, with NS records added at the parent once
#   - the artifact store (examples/artifact-store), populated by flux-containers
#
# Subnets must carry the kubernetes.io/role/{internal-,}elb tags for the
# Gateway's NLB; the cluster module adds the karpenter.sh/discovery tag itself
# unless network.manage_discovery_tags is turned off.

provider "aws" {
  region = var.region
}

# A pull-through cache in THIS account, so nodes pull from a registry beside
# them and the store stays closed to direct reads. Its platform_registry output
# carries is_pull_through_cache = true, which is what grants the cluster's
# pullers the create/import permissions a cache needs on first pull.
module "cache" {
  source = "../../modules/registry-cache"

  name = "platform"

  upstream = {
    registry_id       = var.store.registry_id
    region            = var.store.region
    repository_prefix = var.store.repository_prefix
  }

  tags = var.tags
}

# The application, composed beside the cluster. A real root sources this
# from the application's own repository (patchy-app-manifests//modules/aws),
# which emits exactly these maps from static root inputs - never from cluster
# outputs, so there is no cycle:
#
#   module "patchy" {
#     source = "git::https://github.com/bitwise-media-group/patchy-app-manifests.git//modules/aws?ref=v0.1.0"
#
#     name              = var.name
#     platform_registry = module.cache.platform_registry.url
#     secret_prefix     = var.secret_prefix
#     domain            = var.dns_zone_name
#     harnesses         = ["claude"]
#     claude            = { provider = "anthropic" }
#     sso_enabled       = var.sso.enabled
#   }
#
# Until that module is published, the same maps are spelled out literally
# here so the example plans on its own; the values are what the module's
# outputs carry.
locals {
  patchy = {
    namespaces = ["patchy", "patchy-agents"]

    # patchy's egress-broker only needs cloud credentials on the bedrock
    # provider; on anthropic (this example) it carries no grant.
    workload_grants = {}

    # The KSA patchy's secret syncs run as (its GitHub App credential and
    # the anthropic token land in the patchy namespace).
    secret_readers = [
      { namespace = "patchy", service_account = "patchy-secrets" },
    ]

    application = {
      url        = "oci://${module.cache.platform_registry.url}/manifests/patchy"
      semver     = "<1.0.0 >=0.1.0"
      timeout    = "10m"
      depends_on = ["kyverno-policies", "gateway", "secret-sync"]
      verify = {
        subject = "^https://github\\.com/bitwise-media-group/patchy-app-manifests/\\.github/workflows/publish\\.yaml@refs/tags/v.+$"
      }
      dex_clients = var.sso.enabled ? {
        patchy-status = {
          name          = "Patchy Status"
          redirect_uris = ["https://status.${var.dns_zone_name}/oauth2/callback"]
          readers       = ["patchy/patchy-secrets"]
        }
      } : {}
    }

    vars = {
      AGENT_HARNESSES                  = "claude"
      AGENT_EGRESS_POLICY              = "cilium"
      PATCHY_EVALUATION                = "false"
      PATCHY_DOMAIN                    = var.dns_zone_name
      CLAUDE_PROVIDER                  = "anthropic"
      CLAUDE_ANTHROPIC_AUTH            = "token"
      PATCHY_MANIFESTS_SEMVER          = "<1.0.0 >=0.1.0"
      SIGNED_IDENTITY_PATCHY_MANIFESTS = "^https://github\\.com/bitwise-media-group/patchy-app-manifests/\\.github/workflows/publish\\.yaml@refs/tags/v.+$"
    }
  }
}

module "cluster" {
  source = "../.."

  name = var.name

  network = {
    vpc_id            = var.network.vpc_id
    node_subnet_ids   = var.network.node_subnet_ids
    public_subnet_ids = var.network.public_subnet_ids
  }

  # One line, no guessing: the cache module says where it is AND that it is a
  # cache. Swap in module.store.platform_registry to read a store directly.
  platform_registry = module.cache.platform_registry

  signed_identity = {
    manifests_subject  = var.signed_identity_subjects.manifests
    containers_subject = var.signed_identity_subjects.containers
  }

  # The delegated zone is created upstream; this only wires it up. Destroy and
  # recreate of the cluster serves the same domain again: the zone, its
  # delegation and the Gateway's EIPs all outlive the cluster.
  dns = {
    zone_name  = var.dns_zone_name
    acme_email = var.acme_email
  }

  # One EIP per public subnet the Gateway's NLB spans. Every HTTPRoute host
  # shares them, so adding a host later is a manifests-only change.
  gateway = {
    reserve_static_ip = true
  }

  public_access = var.public_access

  # IAM Identity Center permission-set roles mapped onto the Kubernetes groups
  # flux-manifests' rbac component binds against.
  rbac = var.rbac

  cluster_admin_principals = var.cluster_admin_principals

  system_node_group = {
    instance_types = ["m7i.large"]
    min_size       = 2
    max_size       = 4
  }

  # Workload capacity. Spot first, on-demand as the fallback; the ceilings are
  # what the manifests render into the NodePool's spec.limits. There is no
  # minimum - Karpenter scales from zero, and system_node_group.min_size is the
  # cluster's floor.
  karpenter = {
    node_pool = {
      instance_categories = ["c", "m", "r"]
      instance_sizes      = ["large", "xlarge", "2xlarge"]
      capacity_types      = ["spot", "on-demand"]
      max_cpu             = 128
      max_memory_gib      = 512
      max_nodes           = 40
    }
  }

  observability = {
    amp_endpoint = var.amp_endpoint
  }

  # Per-cluster reusability knobs: distinct Secrets Manager names when clusters
  # share an account, the electable-tier component election (the platform's
  # flux-web status UI and the GitHub Actions runner controller), and the SSO
  # toggle that deploys dex and wires every relying party to it.
  secret_prefix       = var.secret_prefix
  platform_components = var.platform_components
  sso                 = var.sso

  # The application, wired from its module's outputs: its IAM grants, its
  # secret-sync readers, the seed that installs it and its own vars.
  workload_grants = local.patchy.workload_grants
  workload_identity = {
    secret_readers = local.patchy.secret_readers
  }
  applications = {
    patchy = local.patchy.application
  }
  application_vars = {
    patchy = local.patchy.vars
  }

  flux = {
    sync = {
      # this environment tracks the staging channel; production consumers track
      # stable (the default)
      ref = "staging"
    }

    # the application's namespaces exist from minute zero so its secrets
    # (GitHub App, webhook secret, Anthropic token) can land before it deploys
    namespaces = local.patchy.namespaces

    cluster_vars = {
      # pin a component's chart range without a manifests release
      CERT_MANAGER_SEMVER = ">=1.18.0 <2.0.0"
    }

    kustomize_patches = [
      {
        patch = yamlencode([
          {
            op    = "add"
            path  = "/spec/template/spec/tolerations"
            value = [{ key = "platform.bitwisemedia.co.uk/system", operator = "Exists" }]
          }
        ])
        target = {
          kind          = "Deployment"
          labelSelector = "app.kubernetes.io/part-of=flux"
        }
      }
    ]
  }

  tags = var.tags
}

# Helm talks to the cluster the module just created, and to ECR for the Cilium
# and flux charts.
#
# Cluster auth is an EXEC PLUGIN, not data.aws_eks_cluster_auth. That data
# source mints a presigned STS token valid for about 15 minutes and resolves it
# once, whereas this apply spans cluster creation, the node group, the add-ons
# and only then the flux chain - comfortably longer. The exec plugin shells out
# to `aws eks get-token` when credentials are actually needed, so the token
# cannot go stale mid-apply. It does require the AWS CLI on whatever runs
# terraform.
#
# The ECR token is fine as a data source: those are valid for 12 hours.
data "aws_ecr_authorization_token" "registry" {}

provider "helm" {
  kubernetes = {
    host                   = module.cluster.endpoint
    cluster_ca_certificate = base64decode(module.cluster.ca_certificate)

    exec = {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      args        = ["eks", "get-token", "--cluster-name", module.cluster.name, "--region", var.region]
    }
  }

  registries = [
    {
      url      = "oci://${module.cache.registry_host}"
      username = data.aws_ecr_authorization_token.registry.user_name
      password = data.aws_ecr_authorization_token.registry.password
    }
  ]
}
