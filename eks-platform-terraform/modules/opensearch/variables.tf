variable "name" { type = string }
variable "subnet_ids" { type = list(string) }
variable "security_group_ids" { type = list(string) }

variable "engine_version" {
  type    = string
  default = "OpenSearch_2.15"
}

variable "instance_type" {
  type    = string
  default = "r6g.large.search"
}

variable "instance_count" {
  type    = number
  default = 3
}

variable "dedicated_master_enabled" {
  type    = bool
  default = true
}

variable "dedicated_master_type" {
  type    = string
  default = "r6g.large.search"
}

variable "dedicated_master_count" {
  type    = number
  default = 3
}

variable "ebs_volume_size" {
  type    = number
  default = 100
}

variable "zone_awareness_az_count" {
  type    = number
  default = 3
}

variable "master_user_arn" {
  description = "IAM principal ARN granted master access via fine-grained access control (e.g. an IRSA role)"
  type        = string
}

variable "tags" {
  type    = map(string)
  default = {}
}
