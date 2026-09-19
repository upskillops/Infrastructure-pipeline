###############################################################################
# Karpenter NodePools -- burst capacity above the managed node group floors.
#
# Previously three near-identical module blocks; now driven by the
# karpenter_nodepools map so a tier is added or retuned in one place.
#
# Each pool shares its tier's taint (workload=<tier>:NoSchedule) and label with
# the managed node group of the same name in nodegroups.tf, so a tier's pods
# schedule onto either half without knowing which is which.
###############################################################################

module "nodepool" {
  source = "./modules/karpenter-nodepool"

  for_each = var.karpenter_nodepools

  name               = "${each.key}-pool"
  cluster_name       = local.cluster_name
  node_iam_role_name = local.node_iam_role_name

  taint_value = each.key

  architecture            = "arm64" # Graviton
  ami_alias               = var.karpenter_ami_alias
  min_instance_generation = var.karpenter_min_instance_generation

  instance_categories = each.value.instance_categories
  instance_sizes      = each.value.instance_sizes
  capacity_types      = each.value.capacity_types

  volume_size_gb = each.value.volume_size_gb
  limits         = each.value.limits

  consolidate_after  = each.value.consolidate_after
  disruption_budgets = each.value.disruption_budgets

  tags = var.tags

  depends_on = [helm_release.karpenter]
}
