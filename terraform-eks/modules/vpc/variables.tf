###############################################################################
# Module: VPC – Variables
###############################################################################

variable "name" {
  description = "Name prefix for VPC resources"
  type        = string
}

variable "cidr" {
  description = "VPC CIDR block"
  type        = string
}

variable "azs" {
  description = "Availability zones"
  type        = list(string)
}

variable "private_subnets" {
  description = "Private subnet CIDRs"
  type        = list(string)
}

variable "public_subnets" {
  description = "Public subnet CIDRs (for NAT GW)"
  type        = list(string)
}

variable "cluster_name" {
  description = "EKS cluster name (used for subnet tags)"
  type        = string
}

variable "enable_nat_gateway" {
  description = "Provision NAT Gateways for outbound internet"
  type        = bool
  default     = true
}

variable "single_nat_gateway" {
  description = "Use one NAT GW for all private subnets (not HA)"
  type        = bool
  default     = false
}

variable "tags" {
  description = "Tags to apply to all resources"
  type        = map(string)
  default     = {}
}
