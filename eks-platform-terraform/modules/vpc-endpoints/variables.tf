variable "name" {
  type = string
}

variable "vpc_id" {
  type = string
}

variable "region" {
  type = string
}

variable "private_subnet_ids" {
  description = "Subnets to place interface endpoint ENIs in"
  type        = list(string)
}

variable "private_route_table_ids" {
  description = "Route tables to attach the S3 gateway endpoint to"
  type        = list(string)
}

variable "security_group_ids" {
  description = "Security groups for interface endpoint ENIs"
  type        = list(string)
}

variable "interface_endpoints" {
  description = "List of AWS service names (short form, e.g. 'ecr.api', 'ecr.dkr', 'sts') to create interface endpoints for"
  type        = list(string)
  default = [
    "ecr.api",
    "ecr.dkr",
    "sts",
    "secretsmanager",
    "monitoring",   # CloudWatch
    "logs",         # CloudWatch Logs
    "kms",
    "ssm",
    "ssmmessages",
    "ec2messages",
  ]
}

variable "tags" {
  type    = map(string)
  default = {}
}
