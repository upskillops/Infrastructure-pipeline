###############################################################################
# EC2 worker nodes -- EKS managed node groups, all Graviton (arm64).
#
# These are the guaranteed floor for each tier. Karpenter (main.tf) supplies
# burst capacity above them using the same taint and label, so the scheduler
# treats a managed node and a Karpenter node in the same tier as equivalent.
#
# This replaces the previous revision's "reserved capacity" pause-pod
# Deployments, which faked a min-node floor by parking low-priority pods on
# each pool. That pattern cost roughly 5-10 minutes of every apply: the
# Deployments waited for rollout, and their required hostname anti-affinity
# forced Karpenter to cold-launch five brand-new EC2 instances before
# terraform apply could return. min_size does the same job for free.
###############################################################################

locals {
  create_nodegroups = var.create_cluster

  node_groups = local.create_nodegroups ? var.workload_node_groups : {}

  # 20m when Terraform installs Cilium: a node that is not Ready by then is a
  # genuine failure and should surface fast. 45m when Helm does, because the
  # apply has to sit in the NotReady window long enough for the operator to
  # run install-cilium.sh -- the node group only reaches ACTIVE once the agent
  # has written /etc/cni/net.d and the kubelet reports Ready.
  # local.cilium_via_terraform is defined in main.tf.
  node_group_create_timeout = coalesce(
    var.node_group_create_timeout,
    local.cilium_via_terraform ? "20m" : "45m",
  )
}

# One IAM role shared by all four node groups, rather than four identical roles.
# Deliberately without AmazonEKS_CNI_Policy: VPC CNI is gone, and under Cilium
# ENI mode only the cilium-operator role (modules/cilium) may manipulate ENIs.
resource "aws_iam_role" "node" {
  count = local.create_nodegroups ? 1 : 0

  name = "${var.cluster_name}-node"

  # There is no fallback CNI. Module v21 sets bootstrap_self_managed_addons =
  # false and modules/cluster-addons installs no vpc-cni, so with Cilium off a
  # node has nothing to make it Ready and every node group would sit until it
  # timed out. Fail at plan time instead of 20 minutes into an apply.
  #
  # install_cilium is about *whether* Cilium is the CNI, not who installs it --
  # cilium_install_method = "helm" still satisfies this, because the chart is
  # vendored in helm-charts/ and installed during the NotReady window.
  lifecycle {
    precondition {
      condition     = var.install_cilium
      error_message = "install_cilium must be true when create_cluster is true: Cilium is the only CNI this configuration installs, so disabling it leaves the cluster with no pod networking. To run a different CNI, add it to modules/cluster-addons and relax this precondition."
    }
  }

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = var.tags
}

resource "aws_iam_role_policy_attachment" "node" {
  for_each = local.create_nodegroups ? toset([
    "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy",
    "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryPullOnly",
    "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore",
  ]) : toset([])

  role       = aws_iam_role.node[0].name
  policy_arn = each.value
}

module "node_group" {
  source  = "terraform-aws-modules/eks/aws//modules/eks-managed-node-group"
  version = "~> 21.25"

  for_each = local.node_groups

  name         = "${var.cluster_name}-${each.key}"
  cluster_name = module.eks[0].cluster_name

  # Needed to template nodeadm user data for AL2023.
  kubernetes_version   = module.eks[0].cluster_version
  cluster_endpoint     = module.eks[0].cluster_endpoint
  cluster_auth_base64  = module.eks[0].cluster_certificate_authority_data
  cluster_service_cidr = module.eks[0].cluster_service_cidr

  subnet_ids             = module.vpc[0].private_subnets
  vpc_security_group_ids = [module.eks[0].node_security_group_id]

  ami_type       = each.value.ami_type
  instance_types = each.value.instance_types
  capacity_type  = each.value.capacity_type

  min_size     = each.value.min_size
  max_size     = each.value.max_size
  desired_size = each.value.desired_size

  # disk_size is ignored once the module builds a launch template, which it
  # does by default -- the size has to be set through the block device mapping.
  block_device_mappings = {
    root = {
      device_name = "/dev/xvda"
      ebs = {
        volume_size           = each.value.disk_size
        volume_type           = "gp3"
        encrypted             = true
        delete_on_termination = true
      }
    }
  }

  labels = merge(
    each.value.taint_workload != null ? { workload = each.value.taint_workload } : {},
    each.value.extra_labels,
  )

  taints = each.value.taint_workload != null ? {
    workload = {
      key    = "workload"
      value  = each.value.taint_workload
      effect = "NO_SCHEDULE"
    }
  } : null

  create_iam_role = false
  iam_role_arn    = aws_iam_role.node[0].arn

  metadata_options = {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 2
  }

  # See local.node_group_create_timeout: short when Terraform owns the Cilium
  # install, long enough to cover a manual `helm install` when it does not.
  timeouts = {
    create = local.node_group_create_timeout
    update = "20m"
    delete = "20m"
  }

  tags = var.tags

  # The ordering the whole Cilium design turns on: no node may be created
  # before a CNI exists to make it Ready. See the header of modules/cilium.
  #
  # Under cilium_install_method = "helm" the module's helm_release has count 0,
  # so this edge only carries the IAM role -- nodes are created with no CNI on
  # purpose, join NotReady, and wait for install-cilium.sh. This resource is
  # then the thing that proves the install worked: it cannot reach ACTIVE
  # until a node is Ready.
  depends_on = [
    module.cilium,
    aws_iam_role_policy_attachment.node,
  ]
}
