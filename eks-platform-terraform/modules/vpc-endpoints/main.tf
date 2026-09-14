locals {
  tags = merge(var.tags, { Module = "vpc-endpoints" })
}

# Gateway endpoint - S3 (no hourly/data charge, attaches to route tables)
resource "aws_vpc_endpoint" "s3" {
  vpc_id            = var.vpc_id
  service_name      = "com.amazonaws.${var.region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = var.private_route_table_ids

  tags = merge(local.tags, { Name = "${var.name}-vpce-s3" })
}

# Interface endpoints for private access to AWS APIs from EKS private subnets
resource "aws_vpc_endpoint" "interface" {
  for_each = toset(var.interface_endpoints)

  vpc_id              = var.vpc_id
  service_name        = "com.amazonaws.${var.region}.${each.value}"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = var.private_subnet_ids
  security_group_ids  = var.security_group_ids
  private_dns_enabled = true

  tags = merge(local.tags, { Name = "${var.name}-vpce-${each.value}" })
}
