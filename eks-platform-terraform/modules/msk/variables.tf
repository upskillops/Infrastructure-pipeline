variable "name" { type = string }
variable "subnet_ids" { type = list(string) }
variable "security_group_ids" { type = list(string) }

variable "kafka_version" {
  type    = string
  default = "3.7.x"
}

variable "instance_type" {
  type    = string
  default = "kafka.m7g.large"
}

variable "number_of_broker_nodes" {
  description = "Total brokers across AZs (must be a multiple of the AZ count)"
  type        = number
  default     = 3
}

variable "ebs_volume_size" {
  type    = number
  default = 500
}

variable "tags" {
  type    = map(string)
  default = {}
}
