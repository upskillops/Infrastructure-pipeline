# NOTE: AWS WAF (WAFv2) can only be associated with CloudFront, ALB, API Gateway,
# AppSync, or Cognito user pools - it cannot attach to a Network Load Balancer,
# because WAF inspects HTTP(S) (L7) traffic and NLB is a pure L4 passthrough.
#
# To match the reference architecture (WAF sitting logically in front of the NLB),
# the common patterns are:
#   1. Put a CloudFront distribution in front of the NLB (NLB as custom origin) and
#      attach this WebACL to CloudFront (scope = "CLOUDFRONT", must be created in us-east-1).
#   2. Terminate TLS/HTTP on an ALB (or the Istio ingress gateway behind an ALB) and
#      attach this WebACL to that ALB (scope = "REGIONAL").
#
# This module creates the WebACL with sane managed-rule defaults; wire the
# `web_acl_arn` output to whichever L7 resource fronts your traffic.

resource "aws_wafv2_web_acl" "this" {
  name        = var.name
  description = "WAF for edge protection - managed rules + rate limiting"
  scope       = var.scope

  default_action {
    allow {}
  }

  rule {
    name     = "AWS-AWSManagedRulesCommonRuleSet"
    priority = 0

    override_action {
      none {}
    }

    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesCommonRuleSet"
        vendor_name = "AWS"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "${var.name}-common-rule-set"
      sampled_requests_enabled   = true
    }
  }

  rule {
    name     = "AWS-AWSManagedRulesKnownBadInputsRuleSet"
    priority = 1

    override_action {
      none {}
    }

    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesKnownBadInputsRuleSet"
        vendor_name = "AWS"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "${var.name}-known-bad-inputs"
      sampled_requests_enabled   = true
    }
  }

  rule {
    name     = "AWS-AWSManagedRulesAmazonIpReputationList"
    priority = 2

    override_action {
      none {}
    }

    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesAmazonIpReputationList"
        vendor_name = "AWS"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "${var.name}-ip-reputation"
      sampled_requests_enabled   = true
    }
  }

  rule {
    name     = "RateLimitPerIP"
    priority = 3

    action {
      block {}
    }

    statement {
      rate_based_statement {
        limit              = var.rate_limit
        aggregate_key_type = "IP"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "${var.name}-rate-limit"
      sampled_requests_enabled   = true
    }
  }

  visibility_config {
    cloudwatch_metrics_enabled = true
    metric_name                = var.name
    sampled_requests_enabled   = true
  }

  tags = merge(var.tags, { Module = "waf" })
}
