###############################################################################
# AWS Load Balancer Controller.
#
# Needed so the Envoy Gateway that fronts GitLab gets a real NLB with `ip`
# target type. That matters more than usual here: under Cilium ENI mode pods
# already hold routable VPC IPs, so an ip-target NLB reaches pods directly --
# no NodePort hop, and the client source IP survives.
#
# Without this controller the in-tree cloud provider would fall back to a
# Classic ELB, and the `aws-load-balancer-type: external` annotations the
# Gateway sets would simply never be acted on, leaving the Service pending.
###############################################################################

locals {
  # Also useful without GitLab, but nothing else here currently needs an
  # AWS-provisioned load balancer, so it follows the same switch.
  create_aws_lbc = local.gitlab_enabled
}

data "aws_iam_policy_document" "aws_lbc_assume" {
  count = local.create_aws_lbc ? 1 : 0

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
      values   = ["system:serviceaccount:kube-system:aws-load-balancer-controller"]
    }

    condition {
      test     = "StringEquals"
      variable = "${module.eks[0].oidc_provider}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "aws_lbc" {
  count = local.create_aws_lbc ? 1 : 0

  name               = "${var.cluster_name}-aws-lbc"
  assume_role_policy = data.aws_iam_policy_document.aws_lbc_assume[0].json
  tags               = var.tags
}

# Verbatim upstream policy (v3.5.0), kept as a file rather than inlined so it
# can be re-fetched and diffed when the controller is upgraded:
#   curl -o iam-policy-aws-lbc.json \
#     https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/v3.5.0/docs/install/iam_policy.json
resource "aws_iam_policy" "aws_lbc" {
  count = local.create_aws_lbc ? 1 : 0

  name   = "${var.cluster_name}-aws-lbc"
  policy = file("${path.module}/iam-policy-aws-lbc.json")
  tags   = var.tags
}

resource "aws_iam_role_policy_attachment" "aws_lbc" {
  count = local.create_aws_lbc ? 1 : 0

  role       = aws_iam_role.aws_lbc[0].name
  policy_arn = aws_iam_policy.aws_lbc[0].arn
}

resource "helm_release" "aws_lbc" {
  count = local.create_aws_lbc ? 1 : 0

  name       = "aws-load-balancer-controller"
  namespace  = "kube-system"
  repository = "https://aws.github.io/eks-charts"
  chart      = "aws-load-balancer-controller"
  version    = "3.5.0"

  wait    = true
  timeout = 600

  values = [
    yamlencode({
      clusterName = module.eks[0].cluster_name
      region      = var.aws_region
      vpcId       = module.vpc[0].vpc_id

      serviceAccount = {
        create = true
        name   = "aws-load-balancer-controller"
        annotations = {
          "eks.amazonaws.com/role-arn" = aws_iam_role.aws_lbc[0].arn
        }
      }

      nodeSelector = { node-role = "core" }
    })
  ]

  depends_on = [
    aws_eks_addon.coredns,
    aws_iam_role_policy_attachment.aws_lbc,
  ]
}
