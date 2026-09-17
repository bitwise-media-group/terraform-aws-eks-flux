# Copyright 2026 BitWise Media Group Ltd
# SPDX-License-Identifier: MIT

# The delegated Route53 hosted zone (e.g. platform.example.com) is created
# upstream and delegated from the parent domain once - it deliberately lives
# outside this module so cluster destroy/recreate never touches the zone or its
# NS delegation. This module only looks it up: validating it exists, deriving
# the domain for the Gateway/certificate wiring, and passing the ids through
# to external-dns via cluster vars. The PUBLIC flavour always exists - 
# cert-manager's DNS-01 challenges resolve over public DNS, so even a fully
# internal cluster keeps a public zone for certificate issuance. The private
# flavour (var.dns.private_zone) is the split-horizon addition: a private
# zone under the same name, associated with the cluster VPC, shadowing the
# public one for in-VPC resolution; external-dns runs one instance per
# flavour, publishing the same records into each.

locals {
  # The zone flavours the cluster uses - public unconditionally, private by
  # election.
  dns_zone_kinds = var.dns.zone_name == null ? [] : concat(
    ["public"],
    var.dns.private_zone ? ["private"] : [],
  )
}

data "aws_route53_zone" "cluster" {
  for_each = toset(local.dns_zone_kinds)

  name         = "${trimsuffix(var.dns.zone_name, ".")}."
  private_zone = each.key == "private"
}

locals {
  # Zone apex without the trailing dot (platform.example.com.).
  dns_domain = var.dns.zone_name != null ? trimsuffix(data.aws_route53_zone.cluster["public"].name, ".") : null

  # The host the platform serves on (PLATFORM_DOMAIN): the zone apex unless
  # the caller narrows it to a sub-host. The platform Gateway's wildcard
  # listener covers *.<host>, so every platform and application route hangs
  # off it by hostname.
  platform_domain = var.dns.zone_name != null ? coalesce(var.dns.host, local.dns_domain) : null
}
