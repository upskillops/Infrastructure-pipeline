locals {
  tags = merge(var.tags, { Module = "opensearch" })
}

resource "aws_kms_key" "opensearch" {
  description             = "OpenSearch encryption key for ${var.name}"
  enable_key_rotation     = true
  deletion_window_in_days = 30
  tags                    = local.tags
}

resource "aws_opensearch_domain" "this" {
  domain_name    = var.name
  engine_version = var.engine_version

  cluster_config {
    instance_type            = var.instance_type
    instance_count            = var.instance_count
    dedicated_master_enabled = var.dedicated_master_enabled
    dedicated_master_type     = var.dedicated_master_type
    dedicated_master_count    = var.dedicated_master_count
    zone_awareness_enabled    = true

    zone_awareness_config {
      availability_zone_count = var.zone_awareness_az_count
    }
  }

  vpc_options {
    subnet_ids         = slice(var.subnet_ids, 0, var.zone_awareness_az_count)
    security_group_ids = var.security_group_ids
  }

  ebs_options {
    ebs_enabled = true
    volume_type = "gp3"
    volume_size = var.ebs_volume_size
  }

  encrypt_at_rest {
    enabled    = true
    kms_key_id = aws_kms_key.opensearch.key_id
  }

  node_to_node_encryption {
    enabled = true
  }

  domain_endpoint_options {
    enforce_https       = true
    tls_security_policy = "Policy-Min-TLS-1-2-2019-07"
  }

  advanced_security_options {
    enabled                        = true
    internal_user_database_enabled = false

    master_user_options {
      master_user_arn = var.master_user_arn
    }
  }

  tags = local.tags
}

resource "aws_opensearch_domain_policy" "this" {
  domain_name = aws_opensearch_domain.this.domain_name

  # Domain is VPC-scoped, so network access is already gated by the
  # security groups/subnets above; this resource policy simply allows any
  # principal that can reach the VPC endpoint (IAM auth is layered on top
  # via advanced_security_options / fine-grained access control).
  access_policies = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { AWS = "*" }
      Action    = "es:*"
      Resource  = "${aws_opensearch_domain.this.arn}/*"
    }]
  })
}
