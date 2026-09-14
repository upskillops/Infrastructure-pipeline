variable "name" {
  description = "Name prefix for all VPC resources"
  type        = string
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC"
  type        = string
  default     = "10.0.0.0/16"
}

variable "azs" {
  description = "List of Availability Zones to deploy into (3 recommended)"
  type        = list(string)
}

variable "public_subnet_cidrs" {
  description = "CIDR blocks for public subnets, one per AZ"
  type        = list(string)
}

variable "private_subnet_cidrs" {
  description = "CIDR blocks for private (EKS node) subnets, one per AZ"
  type        = list(string)
}

variable "single_nat_gateway" {
  description = "If true, use a single shared NAT Gateway instead of one per AZ (cheaper, less resilient)"
  type        = bool
  default     = false
}

variable "enable_flow_logs" {
  description = "Enable VPC Flow Logs to CloudWatch Logs"
  type        = bool
  default     = true
}

variable "flow_log_retention_days" {
  description = "Retention in days for VPC flow log group"
  type        = number
  default     = 30
}

variable "cluster_name" {
  description = "EKS cluster name, used to tag subnets for k8s/ELB discovery"
  type        = string
}

variable "tags" {
  description = "Common tags applied to all resources"
  type        = map(string)
  default     = {}
}
