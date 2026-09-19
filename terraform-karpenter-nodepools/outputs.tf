output "cluster_name" {
  value = local.cluster_name
}

output "cluster_endpoint" {
  value = local.cluster_endpoint
}

output "configure_kubectl" {
  value = "aws eks update-kubeconfig --name ${local.cluster_name} --region ${var.aws_region}"
}

output "vpc_id" {
  value = var.create_cluster ? module.vpc[0].vpc_id : null
}

output "private_subnet_ids" {
  value = var.create_cluster ? module.vpc[0].private_subnets : null
}

output "node_groups" {
  description = "Graviton managed node groups providing each tier's guaranteed floor."
  value = var.create_cluster ? {
    for k, ng in module.node_group : k => {
      name           = ng.node_group_id
      instance_types = var.workload_node_groups[k].instance_types
      min_size       = var.workload_node_groups[k].min_size
      max_size       = var.workload_node_groups[k].max_size
      taint          = var.workload_node_groups[k].taint_workload == null ? "none (untainted)" : "workload=${var.workload_node_groups[k].taint_workload}:NoSchedule"
    }
  } : null
}

output "karpenter_nodepools" {
  description = "Karpenter NodePools providing burst above the floors."
  value       = { for k, m in module.nodepool : k => m.taint }
}

output "karpenter_node_role_name" {
  description = "IAM role Karpenter uses for the instances it launches."
  value       = local.node_iam_role_name
}

output "nodegroup_node_role_name" {
  description = "IAM role shared by the managed node groups."
  value       = var.create_cluster ? aws_iam_role.node[0].name : null
}

output "cilium_operator_role_arn" {
  description = "IRSA role the Cilium operator assumes to manage ENIs."
  value       = local.install_cilium ? aws_iam_role.cilium_operator[0].arn : null
}

output "verify_cilium" {
  description = "Confirm Cilium fully replaced VPC CNI and kube-proxy."
  value       = "kubectl -n kube-system get ds cilium && kubectl -n kube-system get ds aws-node kube-proxy 2>&1 | tail -1"
}

###############################################################################
# GitLab
###############################################################################

output "gitlab_url" {
  description = "Browser URL for the GitLab UI."
  value       = local.gitlab_enabled ? "https://gitlab.${var.gitlab_domain}" : null
}

output "gitlab_registry_url" {
  value = local.gitlab_enabled ? "https://registry.${var.gitlab_domain}" : null
}

output "gitlab_root_password_command" {
  description = "Retrieve the initial root password (rotate it after first login)."
  value = local.gitlab_enabled ? join(" ", [
    "kubectl -n ${var.gitlab_namespace} get secret gitlab-gitlab-initial-root-password",
    "-o jsonpath='{.data.password}' | base64 -d; echo",
  ]) : null
}

output "gitlab_nameservers" {
  description = "Delegate gitlab_domain to these at your registrar. Until this is done the UI will not resolve and Let's Encrypt cannot issue a certificate."
  value       = local.gitlab_zone_nameservers
}

output "gitlab_db_endpoint" {
  value     = local.gitlab_enabled ? aws_db_instance.gitlab[0].address : null
  sensitive = true
}

output "gitlab_redis_endpoint" {
  value     = local.gitlab_enabled ? aws_elasticache_replication_group.gitlab[0].primary_endpoint_address : null
  sensitive = true
}

output "gitlab_buckets" {
  description = "S3 buckets backing GitLab object storage."
  value       = local.gitlab_bucket_names
}

output "gitlab_watch_rollout" {
  description = "GitLab installs asynchronously by default; follow it with this."
  value       = local.gitlab_enabled ? "kubectl -n ${var.gitlab_namespace} get pods -w" : null
}
