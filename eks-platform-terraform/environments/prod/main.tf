#############################
# Networking
#############################
module "vpc" {
  source = "../../modules/vpc"

  name                  = var.name
  vpc_cidr              = var.vpc_cidr
  azs                   = var.azs
  public_subnet_cidrs   = var.public_subnet_cidrs
  private_subnet_cidrs  = var.private_subnet_cidrs
  single_nat_gateway    = false
  enable_flow_logs      = true
  cluster_name          = var.cluster_name
  tags                  = local.common_tags
}

module "security_groups" {
  source = "../../modules/security-groups"

  name     = var.name
  vpc_id   = module.vpc.vpc_id
  vpc_cidr = module.vpc.vpc_cidr
  pod_cidr = var.pod_cidr
  tags     = local.common_tags
}

module "vpc_endpoints" {
  source = "../../modules/vpc-endpoints"

  name                     = var.name
  vpc_id                   = module.vpc.vpc_id
  region                   = var.region
  private_subnet_ids       = module.vpc.private_subnet_ids
  private_route_table_ids  = module.vpc.private_route_table_ids
  security_group_ids       = [module.security_groups.vpc_endpoints_sg_id]
  tags                     = local.common_tags
}

module "waf" {
  source = "../../modules/waf"

  name = "${var.name}-waf"
  tags = local.common_tags
}

#############################
# EKS
#############################
module "eks" {
  source = "../../modules/eks"

  cluster_name               = var.cluster_name
  kubernetes_version          = var.kubernetes_version
  vpc_id                      = module.vpc.vpc_id
  private_subnet_ids          = module.vpc.private_subnet_ids
  cluster_security_group_id   = module.security_groups.eks_cluster_sg_id
  node_security_group_id      = module.security_groups.eks_nodes_sg_id
  endpoint_public_access       = false
  install_vpc_cni_addon       = false # Cilium replaces the AWS VPC CNI
  admin_principal_arns        = var.admin_principal_arns

  node_groups = {
    default = {
      instance_types = ["m6i.large"]
      capacity_type  = "ON_DEMAND"
      min_size       = 3
      max_size       = 9
      desired_size   = 3
      disk_size      = 50
      labels         = { workload = "general" }
      taints         = []
    }
  }

  tags = local.common_tags
}

#############################
# In-cluster addons: Cilium, Istio, Kyverno, observability
#############################
module "cluster_addons" {
  source = "../../modules/cluster-addons"
  count  = var.install_cluster_addons ? 1 : 0

  cluster_name = module.eks.cluster_name
  pod_cidr     = var.pod_cidr

  depends_on = [module.eks]
}

#############################
# Data layer
#############################
module "rds" {
  source = "../../modules/rds"

  name                = "${var.name}-postgres"
  vpc_id              = module.vpc.vpc_id
  subnet_ids          = module.vpc.private_subnet_ids
  security_group_ids  = [module.security_groups.rds_sg_id]
  tags                = local.common_tags
}

module "elasticache" {
  source = "../../modules/elasticache"

  name                = "${var.name}-redis"
  subnet_ids          = module.vpc.private_subnet_ids
  security_group_ids  = [module.security_groups.elasticache_sg_id]
  tags                = local.common_tags
}

module "opensearch" {
  source = "../../modules/opensearch"

  name                = "${var.name}-search"
  subnet_ids          = module.vpc.private_subnet_ids
  security_group_ids  = [module.security_groups.opensearch_sg_id]
  master_user_arn     = var.opensearch_master_user_arn
  tags                = local.common_tags
}

module "msk" {
  source = "../../modules/msk"

  name                = "${var.name}-kafka"
  subnet_ids          = module.vpc.private_subnet_ids
  security_group_ids  = [module.security_groups.msk_sg_id]
  tags                = local.common_tags
}

#############################
# DNS
# NOTE: nlb_dns_name/nlb_zone_id below come from the Istio ingress
# gateway's Kubernetes Service (type=LoadBalancer), which is created by
# module.cluster_addons/Helm, not by this root module directly. Until
# that Service exists, pass placeholder values or manage this record
# out of band; then update and re-apply once the Service's ELB hostname
# is known (e.g. via a `kubernetes_service` data source once addons are up).
#############################
# module "route53" {
#   source = "../../modules/route53"
#
#   create_zone      = false
#   domain_name      = var.domain_name
#   existing_zone_id = "REPLACE_ME"
#   record_name      = var.app_record_name
#   nlb_dns_name     = "REPLACE_ME_AFTER_ISTIO_GATEWAY_IS_UP"
#   nlb_zone_id      = "REPLACE_ME_ELB_ZONE_ID_FOR_REGION"
#   tags             = local.common_tags
# }
