output "route53_zone_id" {
  value = local.zone_id
}

output "route53_zone_nameservers" {
  description = "Delegate the domain to these at your registrar. Until that is done nothing resolves and Let's Encrypt cannot issue a certificate. Empty when the zone was looked up rather than created."
  value       = var.create_route53_zone ? aws_route53_zone.this[0].name_servers : []
}

output "lbc_role_arn" {
  value = aws_iam_role.lbc.arn
}

output "external_dns_role_arn" {
  value = aws_iam_role.external_dns.arn
}
