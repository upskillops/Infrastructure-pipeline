variable "name" {
  description = "Name for the WAF WebACL"
  type        = string
}

variable "scope" {
  description = "REGIONAL (ALB/API Gateway/AppSync) or CLOUDFRONT. Note: AWS WAF cannot attach directly to a Network Load Balancer since NLB operates at L4 - see README."
  type        = string
  default     = "REGIONAL"
}

variable "rate_limit" {
  description = "Requests per 5-minute window per IP before rate-limit rule blocks"
  type        = number
  default     = 2000
}

variable "tags" {
  description = "Common tags"
  type        = map(string)
  default     = {}
}
