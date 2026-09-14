###############################################################################
# Module: VPC
###############################################################################

locals {
  nat_gateway_count = var.single_nat_gateway ? 1 : length(var.azs)
}

###############################################################################
# VPC
###############################################################################

resource "aws_vpc" "this" {
  cidr_block           = var.cidr
  enable_dns_support   = true
  enable_dns_hostnames = true  # Required for EKS private endpoints

  tags = merge(var.tags, {
    Name                                        = var.name
    "kubernetes.io/cluster/${var.cluster_name}" = "shared"
  })
}

###############################################################################
# Internet Gateway (for NAT only – pods stay private)
###############################################################################

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id

  tags = merge(var.tags, { Name = "${var.name}-igw" })
}

###############################################################################
# Public Subnets
###############################################################################

resource "aws_subnet" "public" {
  count = length(var.public_subnets)

  vpc_id                  = aws_vpc.this.id
  cidr_block              = var.public_subnets[count.index]
  availability_zone       = var.azs[count.index]
  map_public_ip_on_launch = false  # NAT GW gets EIPs, not instances

  tags = merge(var.tags, {
    Name                                        = "${var.name}-public-${var.azs[count.index]}"
    "kubernetes.io/cluster/${var.cluster_name}" = "shared"
    "kubernetes.io/role/elb"                    = "1"  # ALB/NLB in public subnets
  })
}

###############################################################################
# Private Subnets
###############################################################################

resource "aws_subnet" "private" {
  count = length(var.private_subnets)

  vpc_id            = aws_vpc.this.id
  cidr_block        = var.private_subnets[count.index]
  availability_zone = var.azs[count.index]

  tags = merge(var.tags, {
    Name                                        = "${var.name}-private-${var.azs[count.index]}"
    "kubernetes.io/cluster/${var.cluster_name}" = "owned"
    "kubernetes.io/role/internal-elb"           = "1"  # Internal load balancers
  })
}

###############################################################################
# Elastic IPs for NAT Gateways
###############################################################################

resource "aws_eip" "nat" {
  count  = var.enable_nat_gateway ? local.nat_gateway_count : 0
  domain = "vpc"

  tags = merge(var.tags, {
    Name = "${var.name}-nat-eip-${count.index + 1}"
  })

  depends_on = [aws_internet_gateway.this]
}

###############################################################################
# NAT Gateways
###############################################################################

resource "aws_nat_gateway" "this" {
  count = var.enable_nat_gateway ? local.nat_gateway_count : 0

  allocation_id = aws_eip.nat[count.index].id
  subnet_id     = aws_subnet.public[count.index].id

  tags = merge(var.tags, {
    Name = "${var.name}-nat-${var.azs[count.index]}"
  })

  depends_on = [aws_internet_gateway.this]
}

###############################################################################
# Route Tables
###############################################################################

# Public route table (one, shared)
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.this.id
  }

  tags = merge(var.tags, { Name = "${var.name}-public-rt" })
}

resource "aws_route_table_association" "public" {
  count = length(var.public_subnets)

  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

# Private route tables (one per AZ when multi-NAT)
resource "aws_route_table" "private" {
  count  = local.nat_gateway_count
  vpc_id = aws_vpc.this.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.this[count.index].id
  }

  tags = merge(var.tags, {
    Name = "${var.name}-private-rt-${count.index + 1}"
  })
}

resource "aws_route_table_association" "private" {
  count = length(var.private_subnets)

  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private[var.single_nat_gateway ? 0 : count.index].id
}

###############################################################################
# VPC Endpoints – required for private EKS cluster
###############################################################################

# Security group for VPC endpoints
resource "aws_security_group" "vpc_endpoints" {
  name        = "${var.name}-vpce-sg"
  description = "Security group for VPC interface endpoints"
  vpc_id      = aws_vpc.this.id

  ingress {
    description = "HTTPS from within VPC"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [var.cidr]
  }

  egress {
    description = "Allow all outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(var.tags, { Name = "${var.name}-vpce-sg" })
}

# Gateway endpoint for S3 (no cost, used by ECR layer pulls)
resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.this.id
  service_name      = "com.amazonaws.${data.aws_region.current.name}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = aws_route_table.private[*].id

  tags = merge(var.tags, { Name = "${var.name}-s3-endpoint" })
}

# Interface endpoints required for private EKS
locals {
  interface_endpoints = [
    "ec2",
    "ecr.api",
    "ecr.dkr",
    "logs",                # CloudWatch Logs
    "sts",                 # IAM STS for IRSA
    "elasticloadbalancing",
    "autoscaling",
    "xray",
  ]
}

resource "aws_vpc_endpoint" "interface" {
  for_each = toset(local.interface_endpoints)

  vpc_id              = aws_vpc.this.id
  service_name        = "com.amazonaws.${data.aws_region.current.name}.${each.value}"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = aws_subnet.private[*].id
  security_group_ids  = [aws_security_group.vpc_endpoints.id]
  private_dns_enabled = true

  tags = merge(var.tags, { Name = "${var.name}-${each.value}-endpoint" })
}

data "aws_region" "current" {}
