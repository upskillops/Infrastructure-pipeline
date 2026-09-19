###############################################################################
# Karpenter controller.
#
# Provides burst capacity above the managed node group floors. The v21
# submodule wires the controller up with EKS Pod Identity instead of IRSA,
# which is why aws_eks_addon.pod_identity has to exist first.
###############################################################################

module "karpenter" {
  count   = var.create_cluster ? 1 : 0
  source  = "terraform-aws-modules/eks/aws//modules/karpenter"
  version = "~> 21.25"

  cluster_name = module.eks[0].cluster_name

  # Node role for Karpenter-launched instances. Kept separate from the managed
  # node group role in nodegroups.tf because the submodule also registers this
  # one with the cluster via its own EKS access entry.
  create_node_iam_role          = true
  node_iam_role_name            = "${var.cluster_name}-karpenter-node"
  node_iam_role_use_name_prefix = false

  # No AmazonEKS_CNI_Policy: Cilium, not VPC CNI, owns ENIs here.
  node_iam_role_attach_cni_policy = false

  node_iam_role_additional_policies = {
    AmazonEC2ContainerRegistryPullOnly = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryPullOnly"
    AmazonSSMManagedInstanceCore       = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
  }

  # Karpenter v1 has the controller manage the instance profile itself through
  # EC2NodeClass.spec.role, so Terraform does not need to create one.
  create_instance_profile = false

  create_access_entry = true
  access_entry_type   = "EC2_LINUX"

  # SQS queue + EventBridge rules for spot interruption and rebalance notices.
  enable_spot_termination = true

  create_pod_identity_association = true

  tags = var.tags
}

resource "helm_release" "karpenter" {
  count = var.create_cluster ? 1 : 0

  name             = "karpenter"
  namespace        = "kube-system"
  create_namespace = false

  repository = "oci://public.ecr.aws/karpenter"
  chart      = "karpenter"
  version    = var.karpenter_version

  wait    = true
  timeout = 600

  values = [
    yamlencode({
      settings = {
        clusterName       = module.eks[0].cluster_name
        clusterEndpoint   = module.eks[0].cluster_endpoint
        interruptionQueue = module.karpenter[0].queue_name
      }

      # Pin the controller to the untainted core group. Karpenter cannot manage
      # the nodes it runs on, so it must never land on a pool it owns.
      nodeSelector = {
        node-role = "core"
      }

      # The chart applies a *required* podAntiAffinity on kubernetes.io/hostname,
      # so these replicas need that many distinct core nodes. Because this
      # release uses wait = true, workload_node_groups["core"].desired_size must
      # stay >= karpenter_replicas, or the apply blocks on a Pending pod until
      # it times out.
      replicas = var.karpenter_replicas
    })
  ]

  depends_on = [
    module.karpenter,
    aws_eks_addon.coredns,
    aws_eks_addon.pod_identity,
  ]
}
