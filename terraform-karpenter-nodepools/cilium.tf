###############################################################################
# Cilium -- sole CNI, full VPC CNI + kube-proxy replacement.
#
# Bootstrap order matters and is subtle:
#   1. Control plane is created with no CNI and no kube-proxy at all.
#   2. Cilium is installed here with wait = false. There are no nodes yet, so
#      every Cilium pod is Pending -- waiting would deadlock the apply.
#   3. Node groups are created (nodegroups.tf). Nodes join NotReady.
#   4. cilium-agent is a DaemonSet and tolerates NotReady nodes; it runs on the
#      host network, writes /etc/cni/net.d, and the node flips to Ready.
#   5. The managed node group's own "wait for ACTIVE" is what makes step 4
#      block the apply until networking genuinely works.
#
# The classic deadlock here is cilium-operator: in ENI mode the agent cannot
# assign pod IPs until the operator has attached ENIs, but a normal Deployment
# needs a pod IP to start. The chart avoids this by defaulting
# operator.hostNetwork = true, so the operator runs on the node's own IP.
###############################################################################

locals {
  install_cilium = var.create_cluster && var.install_cilium
}

data "aws_iam_policy_document" "cilium_operator_assume" {
  count = local.install_cilium ? 1 : 0

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
      values   = ["system:serviceaccount:kube-system:cilium-operator"]
    }

    condition {
      test     = "StringEquals"
      variable = "${module.eks[0].oidc_provider}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "cilium_operator" {
  count = local.install_cilium ? 1 : 0

  name               = "${var.cluster_name}-cilium-operator"
  assume_role_policy = data.aws_iam_policy_document.cilium_operator_assume[0].json
  tags               = var.tags
}

# ENI IPAM: the operator creates/attaches ENIs and hands addresses to agents.
# Note the node role deliberately does NOT get AmazonEKS_CNI_Policy -- with VPC
# CNI gone, ENI management is this role's job alone, not every node's.
resource "aws_iam_role_policy" "cilium_operator" {
  count = local.install_cilium ? 1 : 0

  name = "cilium-operator-eni"
  role = aws_iam_role.cilium_operator[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "ec2:DescribeNetworkInterfaces",
          "ec2:DescribeSubnets",
          "ec2:DescribeVpcs",
          "ec2:DescribeSecurityGroups",
          "ec2:DescribeInstances",
          "ec2:DescribeInstanceTypes",
          "ec2:DescribeTags",
          "ec2:DescribeRouteTables",
        ]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "ec2:CreateNetworkInterface",
          "ec2:AttachNetworkInterface",
          "ec2:DeleteNetworkInterface",
          "ec2:DetachNetworkInterface",
          "ec2:ModifyNetworkInterfaceAttribute",
          "ec2:AssignPrivateIpAddresses",
          "ec2:UnassignPrivateIpAddresses",
          "ec2:CreateTags",
        ]
        Resource = "*"
      },
    ]
  })
}

resource "helm_release" "cilium" {
  count = local.install_cilium ? 1 : 0

  name       = "cilium"
  namespace  = "kube-system"
  repository = "https://helm.cilium.io/"
  chart      = "cilium"
  version    = var.cilium_version

  # Must not wait: at this point the cluster has zero nodes, so nothing can
  # become Ready. Node group creation downstream is what proves Cilium works.
  wait    = false
  atomic  = false
  timeout = 600

  values = [
    yamlencode({
      # --- IPAM: real VPC IPs per pod, no overlay -------------------------
      eni = {
        enabled                   = true
        awsEnablePrefixDelegation = var.cilium_enable_prefix_delegation
        awsReleaseExcessIPs       = true
        # Don't look for the legacy cilium-aws secret; we use IRSA.
        iamRole = aws_iam_role.cilium_operator[0].arn
      }
      ipam = {
        mode = "eni"
      }
      routingMode                = "native"
      ipv4NativeRoutingCIDR      = var.vpc_cidr
      endpointRoutes             = { enabled = true }
      egressMasqueradeInterfaces = "eth0"

      # --- kube-proxy replacement -----------------------------------------
      # There is no kube-proxy, so Cilium cannot reach the API via the
      # kubernetes.default ClusterIP. It needs the real endpoint.
      kubeProxyReplacement = "true"
      k8sServiceHost       = local.cluster_api_host
      k8sServicePort       = 443

      cni = {
        # Remove any other CNI conf file rather than chaining with it.
        exclusive = true
      }

      serviceAccounts = {
        operator = {
          name = "cilium-operator"
          annotations = {
            "eks.amazonaws.com/role-arn" = aws_iam_role.cilium_operator[0].arn
          }
        }
      }

      operator = {
        replicas = var.cilium_operator_replicas
        # Explicit even though it is the chart default -- ENI mode deadlocks
        # without it, so it should be visible rather than inherited.
        hostNetwork = true
      }

      hubble = {
        enabled = true
        relay   = { enabled = var.cilium_enable_hubble_relay }
        ui      = { enabled = false }
      }

      # No arch nodeSelector on purpose: the Cilium images are multi-arch, and
      # pinning the agent DaemonSet to arm64 would silently leave any future
      # amd64 node with no CNI at all.
    })
  ]

  depends_on = [
    module.eks,
    aws_iam_role_policy.cilium_operator,
  ]
}
