###############################################################################
# Module: Fargate – Variables
###############################################################################

variable "cluster_name" {
  description = "EKS cluster name"
  type        = string
}

variable "private_subnet_ids" {
  description = "Private subnet IDs where Fargate pods will run"
  type        = list(string)
}

variable "fargate_pod_execution_role_arn" {
  description = "ARN of the Fargate pod execution IAM role"
  type        = string
}

variable "fargate_profiles" {
  description = "Map of Fargate profiles to create"
  type = map(object({
    namespace = string
    labels    = optional(map(string), {})
  }))
}

variable "tags" {
  description = "Tags to apply to resources"
  type        = map(string)
  default     = {}
}
