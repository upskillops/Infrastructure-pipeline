###############################################################################
# Composition.
#
# This file wires the pieces together and does nothing else. Each concern is a
# module; the ordering between them is the whole point of the design and is
# stated explicitly with depends_on rather than left to be inferred:
#
#   vpc -> eks -> [cilium] -> node groups -> cluster-addons -> ingress -> gitlab
#                                                     \-> karpenter -> nodepools
#
# The bracket around cilium is deliberate: under the default
# cilium_install_method = "helm" that module creates only an IAM role, and the
# CNI arrives out of band while the node groups block. See modules/cilium.
###############################################################################

locals {
  # Cilium is this cluster's CNI: governs the operator IRSA role, and the
  # absence of the vpc-cni / kube-proxy addons in modules/cluster-addons.
  install_cilium = var.create_cluster && var.install_cilium

  # ...and this decides whether Terraform is also the thing that installs it.
  # Read by nodegroups.tf to pick a create timeout.
  cilium_via_terraform = local.install_cilium && var.cilium_install_method == "terraform"

  # Governs the AWS side of GitLab: RDS, ElastiCache, S3, Route53, IRSA.
  # True regardless of who installs the chart -- the datastores have to exist
  # before either Terraform or `helm install` can point the chart at them.
  gitlab_enabled = var.create_cluster && var.enable_gitlab

  create_addons = var.create_cluster
}

###############################################################################
# CNI
###############################################################################

module "cilium" {
  count  = local.install_cilium ? 1 : 0
  source = "./modules/cilium"

  cluster_name      = module.eks[0].cluster_name
  cluster_endpoint  = module.eks[0].cluster_endpoint
  oidc_provider_arn = module.eks[0].oidc_provider_arn
  oidc_provider     = module.eks[0].oidc_provider
  vpc_cidr          = var.vpc_cidr

  chart_version            = var.cilium_version
  install_method           = var.cilium_install_method
  enable_prefix_delegation = var.cilium_enable_prefix_delegation
  enable_hubble_relay      = var.cilium_enable_hubble_relay
  operator_replicas        = var.cilium_operator_replicas

  tags = var.tags
}

###############################################################################
# Addons and storage
#
# After the node groups, not before: CoreDNS and the EBS CSI controller need
# somewhere to run, and created earlier they would sit DEGRADED and stall the
# apply until it timed out.
###############################################################################

module "cluster_addons" {
  count  = local.create_addons ? 1 : 0
  source = "./modules/cluster-addons"

  cluster_name          = module.eks[0].cluster_name
  enable_ebs_csi_driver = var.enable_ebs_csi_driver
  storage_classes       = var.storage_classes

  tags = var.tags

  depends_on = [module.node_group]
}

###############################################################################
# Ingress: load balancer controller, external-dns, and the hosted zone.
#
# Follows the GitLab switch because nothing else here currently needs an
# AWS-provisioned load balancer, but it is not GitLab-specific.
###############################################################################

module "ingress" {
  count  = local.gitlab_enabled ? 1 : 0
  source = "./modules/ingress"

  cluster_name      = module.eks[0].cluster_name
  aws_region        = var.aws_region
  vpc_id            = module.vpc[0].vpc_id
  oidc_provider_arn = module.eks[0].oidc_provider_arn
  oidc_provider     = module.eks[0].oidc_provider

  domain              = var.gitlab_domain
  create_route53_zone = var.create_route53_zone

  tags = var.tags

  depends_on = [module.cluster_addons]
}

###############################################################################
# GitLab
###############################################################################

# Preconditions that are about the *caller's* configuration rather than the
# module's own inputs, so they cannot live as variable validations inside it.
# All three are failure modes that otherwise surface twenty minutes into an
# install as a Pending pod.
resource "terraform_data" "gitlab_preconditions" {
  count = local.gitlab_enabled ? 1 : 0

  lifecycle {
    precondition {
      condition     = var.enable_ebs_csi_driver
      error_message = "enable_ebs_csi_driver must be true when enable_gitlab = true: Gitaly stores git repositories on a PersistentVolume, which needs the EBS CSI driver and a StorageClass."
    }

    precondition {
      condition     = contains(keys(var.storage_classes), var.gitlab_storage_class)
      error_message = "gitlab_storage_class (\"${var.gitlab_storage_class}\") is not a key in storage_classes. Available: ${join(", ", keys(var.storage_classes))}."
    }

    precondition {
      condition     = try(var.workload_node_groups["infra"].min_size, 0) >= 1
      error_message = "workload_node_groups[\"infra\"].min_size must be at least 1 when enable_gitlab = true. GitLab is pinned to the managed infra nodes (it is stateful and must not run on the Karpenter spot pool), so a floor of 0 would leave every GitLab pod Pending."
    }
  }
}

module "gitlab" {
  count  = local.gitlab_enabled ? 1 : 0
  source = "./modules/gitlab"

  cluster_name           = module.eks[0].cluster_name
  aws_region             = var.aws_region
  vpc_id                 = module.vpc[0].vpc_id
  private_subnet_ids     = module.vpc[0].private_subnets
  node_security_group_id = module.eks[0].node_security_group_id
  oidc_provider_arn      = module.eks[0].oidc_provider_arn
  oidc_provider          = module.eks[0].oidc_provider

  namespace      = var.gitlab_namespace
  domain         = var.gitlab_domain
  acme_email     = var.gitlab_acme_email
  install_method = var.gitlab_install_method

  chart_version        = var.gitlab_chart_version
  wait_for_rollout     = var.gitlab_wait_for_rollout
  infra_nodegroup_name = "${var.cluster_name}-infra"

  db_instance_class      = var.gitlab_db_instance_class
  db_engine_version      = var.gitlab_db_engine_version
  db_allocated_storage   = var.gitlab_db_allocated_storage
  db_multi_az            = var.gitlab_db_multi_az
  db_deletion_protection = var.gitlab_db_deletion_protection

  redis_node_type      = var.gitlab_redis_node_type
  redis_engine_version = var.gitlab_redis_engine_version

  webservice_replicas  = var.gitlab_webservice_replicas
  sidekiq_replicas     = var.gitlab_sidekiq_replicas
  gitaly_storage_size  = var.gitlab_gitaly_storage_size
  gitaly_storage_class = var.gitlab_storage_class
  runner_helper_image  = var.gitlab_runner_helper_image

  tags = var.tags

  # The release needs the gp3 StorageClass to exist (Gitaly's PVC), and needs
  # the LB controller and external-dns running before it creates a Gateway --
  # otherwise the Service sits pending and no DNS record is ever written.
  depends_on = [
    module.cluster_addons,
    module.ingress,
    terraform_data.gitlab_preconditions,
  ]
}

###############################################################################
# Karpenter NodePools -- burst capacity above the managed node group floors.
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
