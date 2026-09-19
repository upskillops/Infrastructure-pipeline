###############################################################################
# Cluster addons.
#
# Created here rather than inside the EKS module call so they can depend on the
# node groups. The module has no way to know that these need compute, so left
# as module inputs CoreDNS would be created straight after the control plane,
# sit DEGRADED with nowhere to schedule, and stall the apply until it timed out.
#
# There is deliberately no vpc-cni and no kube-proxy addon: Cilium replaces both.
###############################################################################

locals {
  create_addons = var.create_cluster
}

# Versions are intentionally not pinned. Omitting `addon_version` gives the
# default version AWS ships for this Kubernetes release, which is both
# compatible by construction and one less API lookup per plan.
resource "aws_eks_addon" "coredns" {
  count = local.create_addons ? 1 : 0

  cluster_name = module.eks[0].cluster_name
  addon_name   = "coredns"

  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  tags = var.tags

  depends_on = [module.node_group]
}

# Required for Karpenter: the v21 Karpenter submodule authenticates its
# controller with EKS Pod Identity rather than IRSA, and Pod Identity needs
# this agent running on the node.
resource "aws_eks_addon" "pod_identity" {
  count = local.create_addons ? 1 : 0

  cluster_name = module.eks[0].cluster_name
  addon_name   = "eks-pod-identity-agent"

  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  tags = var.tags

  depends_on = [module.node_group]
}

###############################################################################
# EBS CSI driver -- PersistentVolume support.
#
# Strictly beyond "nodegroups + graviton + karpenter + cilium", but the
# monitoring tier asks for 150 GiB nodes to run Prometheus/Loki, and without a
# CSI driver nothing in the cluster can bind a PersistentVolumeClaim. Set
# enable_ebs_csi_driver = false to drop it.
###############################################################################

locals {
  create_ebs_csi = local.create_addons && var.enable_ebs_csi_driver
}

resource "aws_iam_role" "ebs_csi" {
  count = local.create_ebs_csi ? 1 : 0

  name = "${var.cluster_name}-ebs-csi"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "pods.eks.amazonaws.com" }
      Action    = ["sts:AssumeRole", "sts:TagSession"]
    }]
  })

  tags = var.tags
}

resource "aws_iam_role_policy_attachment" "ebs_csi" {
  count = local.create_ebs_csi ? 1 : 0

  role       = aws_iam_role.ebs_csi[0].name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
}

resource "aws_eks_addon" "ebs_csi" {
  count = local.create_ebs_csi ? 1 : 0

  cluster_name = module.eks[0].cluster_name
  addon_name   = "aws-ebs-csi-driver"

  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  pod_identity_association {
    role_arn        = aws_iam_role.ebs_csi[0].arn
    service_account = "ebs-csi-controller-sa"
  }

  tags = var.tags

  depends_on = [
    aws_eks_addon.pod_identity,
    aws_iam_role_policy_attachment.ebs_csi,
  ]
}

# gp3 rather than the gp2 default: cheaper, faster, and the default class has to
# be declared explicitly because EKS no longer ships one.
resource "kubernetes_storage_class_v1" "gp3" {
  count = local.create_ebs_csi ? 1 : 0

  metadata {
    name = "gp3"
    annotations = {
      "storageclass.kubernetes.io/is-default-class" = "true"
    }
  }

  storage_provisioner    = "ebs.csi.aws.com"
  volume_binding_mode    = "WaitForFirstConsumer"
  allow_volume_expansion = true

  parameters = {
    type      = "gp3"
    encrypted = "true"
  }

  depends_on = [aws_eks_addon.ebs_csi]
}
