###############################################################################
# DNS for the GitLab UI.
#
# The chart exposes GitLab through Gateway API (Envoy Gateway), whose
# LoadBalancer hostname is only known after install. Rather than a two-stage
# apply, external-dns watches the HTTPRoutes the chart creates and writes the
# Route53 records itself -- so gitlab.<domain> resolves as soon as the Gateway
# has an address, which is also what lets Let's Encrypt's HTTP01 challenge
# succeed.
###############################################################################

resource "aws_route53_zone" "gitlab" {
  count = local.gitlab_enabled && var.create_route53_zone ? 1 : 0

  name    = var.gitlab_domain
  comment = "Managed by Terraform for ${var.cluster_name} GitLab"
  tags    = var.tags
}

data "aws_route53_zone" "gitlab" {
  count = local.gitlab_enabled && !var.create_route53_zone ? 1 : 0

  name         = var.gitlab_domain
  private_zone = false
}

locals {
  gitlab_zone_id = local.gitlab_enabled ? (
    var.create_route53_zone ? aws_route53_zone.gitlab[0].zone_id : data.aws_route53_zone.gitlab[0].zone_id
  ) : null

  gitlab_zone_nameservers = local.gitlab_enabled && var.create_route53_zone ? aws_route53_zone.gitlab[0].name_servers : []
}

# ---------------------------------------------------------------------------
# external-dns
# ---------------------------------------------------------------------------

data "aws_iam_policy_document" "external_dns_assume" {
  count = local.gitlab_enabled ? 1 : 0

  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [module.eks[0].oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${module.eks[0].oidc_provider}:sub"
      values   = ["system:serviceaccount:kube-system:external-dns"]
    }

    condition {
      test     = "StringEquals"
      variable = "${module.eks[0].oidc_provider}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "external_dns" {
  count = local.gitlab_enabled ? 1 : 0

  name               = "${var.cluster_name}-external-dns"
  assume_role_policy = data.aws_iam_policy_document.external_dns_assume[0].json
  tags               = var.tags
}

resource "aws_iam_role_policy" "external_dns" {
  count = local.gitlab_enabled ? 1 : 0

  name = "external-dns-route53"
  role = aws_iam_role.external_dns[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = ["route53:ChangeResourceRecordSets"]
        # Scoped to this one zone rather than all of Route53.
        Resource = ["arn:aws:route53:::hostedzone/${local.gitlab_zone_id}"]
      },
      {
        Effect   = "Allow"
        Action   = ["route53:ListHostedZones", "route53:ListResourceRecordSets", "route53:ListTagsForResource"]
        Resource = ["*"]
      },
    ]
  })
}

resource "helm_release" "external_dns" {
  count = local.gitlab_enabled ? 1 : 0

  name       = "external-dns"
  namespace  = "kube-system"
  repository = "https://kubernetes-sigs.github.io/external-dns/"
  chart      = "external-dns"
  version    = "1.15.2"

  wait    = true
  timeout = 600

  values = [
    yamlencode({
      provider = { name = "aws" }

      # gateway-httproute is what reads the HTTPRoutes the GitLab chart creates.
      # Without it external-dns sees no GitLab hostnames at all.
      sources = ["service", "ingress", "gateway-httproute"]

      policy        = "sync"
      registry      = "txt"
      txtOwnerId    = var.cluster_name
      domainFilters = [var.gitlab_domain]

      extraArgs = [
        "--aws-zone-type=public",
        "--zone-id-filter=${local.gitlab_zone_id}",
      ]

      serviceAccount = {
        create = true
        name   = "external-dns"
        annotations = {
          "eks.amazonaws.com/role-arn" = aws_iam_role.external_dns[0].arn
        }
      }

      # Runs on the core group with everything else cluster-wide.
      nodeSelector = { node-role = "core" }
    })
  ]

  depends_on = [
    aws_eks_addon.coredns,
    aws_iam_role_policy.external_dns,
  ]
}
