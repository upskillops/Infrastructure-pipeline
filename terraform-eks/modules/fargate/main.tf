###############################################################################
# Module: Fargate Profiles
###############################################################################

###############################################################################
# Fargate Profile per namespace
###############################################################################

resource "aws_eks_fargate_profile" "this" {
  for_each = var.fargate_profiles

  cluster_name           = var.cluster_name
  fargate_profile_name   = "${var.cluster_name}-${each.key}"
  pod_execution_role_arn = var.fargate_pod_execution_role_arn
  subnet_ids             = var.private_subnet_ids

  selector {
    namespace = each.value.namespace
    labels    = each.value.labels
  }

  tags = merge(var.tags, {
    Name = "${var.cluster_name}-${each.key}-fargate-profile"
  })
}
