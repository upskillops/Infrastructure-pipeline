###############################################################################
# Root – EKS Private Cluster with Fargate (self-managed modules)
###############################################################################

terraform {
  required_version = ">= 1.6.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.40.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = ">= 2.27.0"
    }
  }

  # Recommended: use a remote backend for state
  # backend "s3" {
  #   bucket         = "your-terraform-state-bucket"
  #   key            = "eks-fargate/terraform.tfstate"
  #   region         = "us-east-1"
  #   dynamodb_table = "terraform-state-lock"
  #   encrypt        = true
  # }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = var.common_tags
  }
}

provider "kubernetes" {
  host                   = module.eks.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)

  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = ["eks", "get-token", "--cluster-name", module.eks.cluster_name]
  }
}

###############################################################################
# VPC
###############################################################################

module "vpc" {
  source = "./modules/vpc"

  name               = "${var.cluster_name}-vpc"
  cidr               = var.vpc_cidr
  azs                = var.availability_zones
  private_subnets    = var.private_subnet_cidrs
  public_subnets     = var.public_subnet_cidrs
  cluster_name       = var.cluster_name
  enable_nat_gateway = true
  single_nat_gateway = var.single_nat_gateway

  tags = var.common_tags
}

###############################################################################
# EKS Cluster
###############################################################################

module "eks" {
  source = "./modules/eks"

  cluster_name       = var.cluster_name
  cluster_version    = var.cluster_version
  vpc_id             = module.vpc.vpc_id
  private_subnet_ids = module.vpc.private_subnet_ids
  public_subnet_ids  = module.vpc.public_subnet_ids

  # Private cluster settings
  endpoint_private_access = true
  endpoint_public_access  = var.endpoint_public_access   # false for fully private
  public_access_cidrs     = var.public_access_cidrs

  # Logging
  cluster_log_types = var.cluster_log_types

  # OIDC for IRSA
  enable_irsa = true

  tags = var.common_tags
}

###############################################################################
# Fargate Profiles
###############################################################################

module "fargate" {
  source = "./modules/fargate"

  cluster_name                   = module.eks.cluster_name
  private_subnet_ids             = module.vpc.private_subnet_ids
  fargate_pod_execution_role_arn = module.eks.fargate_pod_execution_role_arn

  fargate_profiles = var.fargate_profiles

  tags = var.common_tags

  depends_on = [module.eks]
}
