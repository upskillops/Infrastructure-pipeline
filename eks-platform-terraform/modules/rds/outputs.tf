output "endpoint" {
  value = aws_db_instance.this.endpoint
}

output "db_instance_id" {
  value = aws_db_instance.this.id
}

output "master_user_secret_arn" {
  description = "Secrets Manager ARN holding the generated master password (when manage_master_user_password = true)"
  value       = try(aws_db_instance.this.master_user_secret[0].secret_arn, null)
}
