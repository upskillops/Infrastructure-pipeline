###############################################################################
# Module: EKS – Outputs
###############################################################################

output "cluster_name" {
  description = "EKS cluster name"
  value       = aws_eks_cluster.this.name
}

output "cluster_endpoint" {
  description = "API server endpoint"
  value       = aws_eks_cluster.this.endpoint
}

output "cluster_certificate_authority_data" {
  description = "Base64 CA data"
  value       = aws_eks_cluster.this.certificate_authority[0].data
}

output "cluster_oidc_issuer_url" {
  description = "OIDC issuer URL"
  value       = try(aws_eks_cluster.this.identity[0].oidc[0].issuer, "")
}

output "oidc_provider_arn" {
  description = "OIDC provider ARN for IRSA"
  value       = try(aws_iam_openid_connect_provider.cluster[0].arn, "")
}

output "cluster_security_group_id" {
  description = "Cluster control plane SG ID"
  value       = aws_security_group.cluster.id
}

output "node_security_group_id" {
  description = "Node / pod SG ID"
  value       = aws_security_group.node.id
}

output "fargate_pod_execution_role_arn" {
  description = "Fargate pod execution IAM role ARN"
  value       = aws_iam_role.fargate_pod_execution.arn
}

output "kms_key_arn" {
  description = "KMS key ARN used for secrets encryption"
  value       = aws_kms_key.eks.arn
}
