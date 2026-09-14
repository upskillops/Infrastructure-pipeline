output "nlb_sg_id" {
  value = aws_security_group.nlb.id
}

output "eks_cluster_sg_id" {
  value = aws_security_group.eks_cluster.id
}

output "eks_nodes_sg_id" {
  value = aws_security_group.eks_nodes.id
}

output "vpc_endpoints_sg_id" {
  value = aws_security_group.vpc_endpoints.id
}

output "rds_sg_id" {
  value = aws_security_group.rds.id
}

output "elasticache_sg_id" {
  value = aws_security_group.elasticache.id
}

output "opensearch_sg_id" {
  value = aws_security_group.opensearch.id
}

output "msk_sg_id" {
  value = aws_security_group.msk.id
}
