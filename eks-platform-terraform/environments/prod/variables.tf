variable "region" {
  type    = string
  default = "us-east-1"
}

variable "name" {
  description = "Base name prefix for all resources"
  type        = string
  default     = "prod-eks-platform"
}

variable "cluster_name" {
  type    = string
  default = "prod-eks"
}

variable "vpc_cidr" {
  type    = string
  default = "10.0.0.0/16"
}

variable "azs" {
  type    = list(string)
  default = ["us-east-1a", "us-east-1b", "us-east-1c"]
}

variable "public_subnet_cidrs" {
  type    = list(string)
  default = ["10.0.1.0/24", "10.0.2.0/24", "10.0.3.0/24"]
}

variable "private_subnet_cidrs" {
  type    = list(string)
  default = ["10.0.11.0/24", "10.0.12.0/24", "10.0.13.0/24"]
}

variable "pod_cidr" {
  description = "Cilium overlay pod CIDR - deliberately outside the VPC CIDR"
  type        = string
  default     = "100.64.0.0/16"
}

variable "kubernetes_version" {
  type    = string
  default = "1.30"
}

variable "admin_principal_arns" {
  description = "IAM principal ARNs granted EKS cluster-admin"
  type        = list(string)
  default     = []
}

variable "opensearch_master_user_arn" {
  description = "IAM principal ARN for OpenSearch fine-grained access control master user"
  type        = string
}

variable "domain_name" {
  type    = string
  default = "example.com"
}

variable "app_record_name" {
  type    = string
  default = "app.example.com"
}

variable "install_cluster_addons" {
  description = "Install Cilium/Istio/Kyverno/observability via Helm from this root module. Set false on first apply (see README two-phase note), then true on a second apply."
  type        = bool
  default     = true
}
