###############################################################################
# Root – Variables
###############################################################################

variable "aws_region" {
  description = "AWS region to deploy resources"
  type        = string
  default     = "us-east-1"
}

variable "cluster_name" {
  description = "Name of the EKS cluster"
  type        = string
  default     = "private-eks-fargate"
}

variable "cluster_version" {
  description = "Kubernetes version for the EKS cluster"
  type        = string
  default     = "1.29"
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC"
  type        = string
  default     = "10.0.0.0/16"
}

variable "availability_zones" {
  description = "List of availability zones"
  type        = list(string)
  default     = ["us-east-1a", "us-east-1b", "us-east-1c"]
}

variable "private_subnet_cidrs" {
  description = "CIDR blocks for private subnets (one per AZ)"
  type        = list(string)
  default     = ["10.0.1.0/24", "10.0.2.0/24", "10.0.3.0/24"]
}

variable "public_subnet_cidrs" {
  description = "CIDR blocks for public subnets (NAT Gateway lives here)"
  type        = list(string)
  default     = ["10.0.101.0/24", "10.0.102.0/24", "10.0.103.0/24"]
}

variable "single_nat_gateway" {
  description = "Use a single NAT Gateway (cost-saving; not HA)"
  type        = bool
  default     = false
}

variable "endpoint_public_access" {
  description = "Enable public API server endpoint. Set to false for fully private."
  type        = bool
  default     = false
}

variable "public_access_cidrs" {
  description = "CIDRs allowed to reach the public endpoint (when enabled)"
  type        = list(string)
  default     = []
}

variable "cluster_log_types" {
  description = "EKS control plane log types to enable"
  type        = list(string)
  default     = ["api", "audit", "authenticator", "controllerManager", "scheduler"]
}

variable "fargate_profiles" {
  description = "Map of Fargate profile configurations"
  type = map(object({
    namespace   = string
    labels      = optional(map(string), {})
  }))
  default = {
    kube-system = {
      namespace = "kube-system"
      labels    = {}
    }
    default = {
      namespace = "default"
      labels    = {}
    }
    app = {
      namespace = "app"
      labels    = { workload = "fargate" }
    }
  }
}

variable "common_tags" {
  description = "Common tags applied to all resources"
  type        = map(string)
  default = {
    Terraform   = "true"
    Environment = "production"
    Project     = "eks-fargate"
  }
}
