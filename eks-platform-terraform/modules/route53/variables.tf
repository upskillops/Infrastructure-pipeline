variable "create_zone" {
  description = "Create a new public hosted zone; set false to use an existing zone_id"
  type        = bool
  default     = false
}

variable "domain_name" {
  type = string
}

variable "existing_zone_id" {
  type    = string
  default = null
}

variable "record_name" {
  description = "FQDN for the application record (e.g. app.example.com)"
  type        = string
}

variable "nlb_dns_name" {
  description = "DNS name of the Network Load Balancer (or Istio ingress gateway Service ELB hostname) to alias to"
  type        = string
}

variable "nlb_zone_id" {
  description = "Hosted zone ID of the NLB (from the ELB/NLB resource, region-specific)"
  type        = string
}

variable "tags" {
  type    = map(string)
  default = {}
}
