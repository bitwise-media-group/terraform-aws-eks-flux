---
title: terraform-aws-eks-flux
template: home.html
hide:
  - navigation
  - toc
---

<!--
  The home page is rendered entirely by overrides/home.html (the landing).
  This body only provides the page title and meta description for the <head>.
-->

A generic EKS cluster that bootstraps flux-operator and syncs a cosign-signed platform from ECR, running Cilium in ENI
mode as the CNI and Karpenter for workload capacity, plus the artifact store, registry cache, signing key and SSO secret
modules around it.
