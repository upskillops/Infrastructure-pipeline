output "zone_id" {
  value = local.zone_id
}

output "record_fqdn" {
  value = aws_route53_record.app.fqdn
}
