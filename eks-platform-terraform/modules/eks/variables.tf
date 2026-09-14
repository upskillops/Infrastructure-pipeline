variable "cluster_name" {
  type = string
}

variable "kubernetes_version" {
  type    = string
  default = "1.30"
}

variable "vpc_id" {
  type = string
}

variable "private_subnet_ids" {
  description = "Private subnets the control plane ENIs and worker nodes live in"
  type        = list(string)
}

variable "cluster_security_group_id" {
  type = string
}

variable "node_security_group_id" {
  type = string
}

variable "endpoint_private_access" {
  type    = bool
  default = true
}

variable "endpoint_public_access" {
  description = "Set false for a fully private cluster (matches reference diagram: EKS cluster in private subnets only)"
  type        = bool
  default     = false
}

variable "public_access_cidrs" {
  type    = list(string)
  default = []
}

variable "enable_cluster_encryption" {
  description = "Encrypt Kubernetes secrets at rest with a KMS key"
  type        = bool
  default     = true
}

variable "kms_key_arn" {
  description = "Existing KMS key ARN for secrets encryption; if null, a key is created"
  type        = string
  default     = null
}

variable "install_vpc_cni_addon" {
  description = "Whether to install the AWS VPC CNI addon. Set false when Cilium fully replaces it as primary CNI."
  type        = bool
  default     = false
}

variable "enabled_cluster_log_types" {
  type    = list(string)
  default = ["api", "audit", "authenticator", "controllerManager", "scheduler"]
}

variable "log_retention_days" {
  type    = number
  default = 90
}

variable "node_groups" {
  description = "Map of managed node group definitions"
  type = map(object({
    instance_types = list(string)
    capacity_type  = string # ON_DEMAND | SPOT
    min_size       = number
    max_size       = number
    desired_size   = number
    disk_size      = number
    labels         = map(string)
    taints = list(object({
      key    = string
      value  = string
      effect = string
    }))
  }))
  default = {
    default = {
      instance_types = ["m6i.large"]
      capacity_type  = "ON_DEMAND"
      min_size       = 3
      max_size       = 9
      desired_size   = 3
      disk_size      = 50
      labels         = {}
      taints         = []
    }
  }
}

variable "admin_principal_arns" {
  description = "IAM principal ARNs granted EKS cluster-admin via access entries"
  type        = list(string)
  default     = []
}

variable "tags" {
  type    = map(string)
  default = {}
}
