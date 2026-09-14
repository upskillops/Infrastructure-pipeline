variable "name" {
  description = "Name prefix for security groups"
  type        = string
}

variable "vpc_id" {
  description = "VPC ID"
  type        = string
}

variable "vpc_cidr" {
  description = "VPC CIDR block, used for internal-only rules (e.g. VPC endpoints)"
  type        = string
}

variable "pod_cidr" {
  description = "Cilium overlay pod CIDR (not part of the VPC CIDR), allowed to reach data services and VPC endpoints"
  type        = string
  default     = "100.64.0.0/16"
}

variable "tags" {
  description = "Common tags"
  type        = map(string)
  default     = {}
}
