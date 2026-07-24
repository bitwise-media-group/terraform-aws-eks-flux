# Copyright 2026 BitWise Media Group Ltd
# SPDX-License-Identifier: MIT

# The delegated Route53 hosted zone (e.g. patchy.bitwisemedia.co.uk) is created
# upstream and delegated from the parent domain once — it deliberately lives
# outside this module so cluster destroy/recreate never touches the zone or its
# NS delegation. This module only looks it up: validating it exists, deriving
# the domain for the Gateway/certificate wiring, and passing the id through to
# external-dns via cluster vars.

data "aws_route53_zone" "cluster" {
  for_each = toset(var.dns.zone_name != null ? ["this"] : [])

  name         = "${trimsuffix(var.dns.zone_name, ".")}."
  private_zone = false
}

locals {
  # Zone apex without the trailing dot (patchy.bitwisemedia.co.uk.).
  dns_domain  = var.dns.zone_name != null ? trimsuffix(data.aws_route53_zone.cluster["this"].name, ".") : null
  dns_zone_id = var.dns.zone_name != null ? data.aws_route53_zone.cluster["this"].zone_id : null

  # The public host the patchy webhook is served on: the zone apex unless the
  # caller narrows it to a sub-host.
  patchy_domain = var.dns.zone_name != null ? coalesce(var.dns.host, local.dns_domain) : null
}
