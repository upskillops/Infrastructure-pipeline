locals {
  tags = merge(var.tags, { Module = "rds" })
}

resource "aws_db_subnet_group" "this" {
  name       = "${var.name}-db-subnets"
  subnet_ids = var.subnet_ids
  tags       = local.tags
}

resource "aws_kms_key" "rds" {
  count                   = var.kms_key_arn == null ? 1 : 0
  description             = "RDS encryption key for ${var.name}"
  enable_key_rotation     = true
  deletion_window_in_days = 30
  tags                    = local.tags
}

resource "aws_db_instance" "this" {
  identifier     = var.name
  engine         = var.engine
  engine_version = var.engine_version
  instance_class = var.instance_class

  allocated_storage     = var.allocated_storage
  max_allocated_storage = var.max_allocated_storage
  storage_type           = "gp3"
  storage_encrypted      = true
  kms_key_id              = coalesce(var.kms_key_arn, try(aws_kms_key.rds[0].arn, null))

  db_name  = var.database_name
  username = var.master_username

  manage_master_user_password = var.manage_master_user_password

  db_subnet_group_name   = aws_db_subnet_group.this.name
  vpc_security_group_ids = var.security_group_ids
  publicly_accessible    = false

  multi_az                = var.multi_az
  backup_retention_period = var.backup_retention_period
  deletion_protection     = var.deletion_protection
  skip_final_snapshot     = false
  final_snapshot_identifier = "${var.name}-final-snapshot"

  copy_tags_to_snapshot = true

  tags = local.tags
}
