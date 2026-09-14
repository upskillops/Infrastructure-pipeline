locals {
  tags = merge(var.tags, {
    Module = "security-groups"
  })
}

#############################
# NLB security group (internet-facing, fronted logically by WAF/Route53)
#############################
resource "aws_security_group" "nlb" {
  name        = "${var.name}-nlb-sg"
  description = "Ingress from the internet to the Network Load Balancer"
  vpc_id      = var.vpc_id

  ingress {
    description = "HTTPS from internet"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "HTTP from internet (redirect to HTTPS)"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.tags, { Name = "${var.name}-nlb-sg" })
}

#############################
# EKS cluster control plane security group
#############################
resource "aws_security_group" "eks_cluster" {
  name        = "${var.name}-eks-cluster-sg"
  description = "EKS control plane <-> node communication"
  vpc_id      = var.vpc_id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.tags, { Name = "${var.name}-eks-cluster-sg" })
}

#############################
# EKS worker node security group
#############################
resource "aws_security_group" "eks_nodes" {
  name        = "${var.name}-eks-nodes-sg"
  description = "EKS worker nodes: node-to-node, cluster-to-node, and NLB health checks/traffic"
  vpc_id      = var.vpc_id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.tags, {
    Name                                          = "${var.name}-eks-nodes-sg"
    "kubernetes.io/cluster/${var.name}"           = "owned"
  })
}

resource "aws_security_group_rule" "nodes_self_all" {
  description              = "Node-to-node (Cilium overlay, kubelet, etc.)"
  type                     = "ingress"
  from_port                = 0
  to_port                  = 0
  protocol                 = "-1"
  security_group_id        = aws_security_group.eks_nodes.id
  source_security_group_id = aws_security_group.eks_nodes.id
}

resource "aws_security_group_rule" "cluster_to_nodes" {
  description              = "Control plane to nodes (kubelet API, webhooks)"
  type                     = "ingress"
  from_port                = 1025
  to_port                  = 65535
  protocol                 = "tcp"
  security_group_id        = aws_security_group.eks_nodes.id
  source_security_group_id = aws_security_group.eks_cluster.id
}

resource "aws_security_group_rule" "nodes_to_cluster_https" {
  description              = "Nodes to control plane API (443)"
  type                     = "ingress"
  from_port                = 443
  to_port                  = 443
  protocol                 = "tcp"
  security_group_id        = aws_security_group.eks_cluster.id
  source_security_group_id = aws_security_group.eks_nodes.id
}

resource "aws_security_group_rule" "nlb_to_nodes" {
  description              = "NLB health checks and traffic to Istio ingress gateway NodePort/target"
  type                     = "ingress"
  from_port                = 30000
  to_port                  = 32767
  protocol                 = "tcp"
  security_group_id        = aws_security_group.eks_nodes.id
  source_security_group_id = aws_security_group.nlb.id
}

#############################
# VPC Interface Endpoints security group
#############################
resource "aws_security_group" "vpc_endpoints" {
  name        = "${var.name}-vpce-sg"
  description = "Allow HTTPS from VPC and pod CIDR to interface VPC endpoints"
  vpc_id      = var.vpc_id

  ingress {
    description = "HTTPS from VPC CIDR"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr, var.pod_cidr]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.tags, { Name = "${var.name}-vpce-sg" })
}

#############################
# Data-layer security groups (RDS, ElastiCache, OpenSearch, MSK)
# Ingress restricted to EKS node SG and pod CIDR (Cilium overlay traffic)
#############################
resource "aws_security_group" "rds" {
  name        = "${var.name}-rds-sg"
  description = "Allow DB traffic from EKS workloads"
  vpc_id      = var.vpc_id

  ingress {
    description     = "PostgreSQL/MySQL from EKS nodes"
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [aws_security_group.eks_nodes.id]
    cidr_blocks     = [var.pod_cidr]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.tags, { Name = "${var.name}-rds-sg" })
}

resource "aws_security_group" "elasticache" {
  name        = "${var.name}-elasticache-sg"
  description = "Allow Redis traffic from EKS workloads"
  vpc_id      = var.vpc_id

  ingress {
    description     = "Redis from EKS nodes"
    from_port       = 6379
    to_port         = 6379
    protocol        = "tcp"
    security_groups = [aws_security_group.eks_nodes.id]
    cidr_blocks     = [var.pod_cidr]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.tags, { Name = "${var.name}-elasticache-sg" })
}

resource "aws_security_group" "opensearch" {
  name        = "${var.name}-opensearch-sg"
  description = "Allow HTTPS traffic from EKS workloads to OpenSearch"
  vpc_id      = var.vpc_id

  ingress {
    description     = "HTTPS from EKS nodes"
    from_port       = 443
    to_port         = 443
    protocol        = "tcp"
    security_groups = [aws_security_group.eks_nodes.id]
    cidr_blocks     = [var.pod_cidr]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.tags, { Name = "${var.name}-opensearch-sg" })
}

resource "aws_security_group" "msk" {
  name        = "${var.name}-msk-sg"
  description = "Allow Kafka traffic from EKS workloads"
  vpc_id      = var.vpc_id

  ingress {
    description     = "Kafka TLS from EKS nodes"
    from_port       = 9094
    to_port         = 9094
    protocol        = "tcp"
    security_groups = [aws_security_group.eks_nodes.id]
    cidr_blocks     = [var.pod_cidr]
  }

  ingress {
    description     = "Kafka plaintext from EKS nodes"
    from_port       = 9092
    to_port         = 9092
    protocol        = "tcp"
    security_groups = [aws_security_group.eks_nodes.id]
    cidr_blocks     = [var.pod_cidr]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.tags, { Name = "${var.name}-msk-sg" })
}
