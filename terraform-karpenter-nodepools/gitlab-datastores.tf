###############################################################################
# GitLab datastores -- RDS PostgreSQL + ElastiCache Redis, both Graviton.
#
# These are not optional extras. GitLab Helm chart v10.0.0 REMOVED the bundled
# PostgreSQL, Redis and object storage subcharts; the chart now refuses to
# render without external ones. See the CONFIGURATION CHECKS block in the
# chart's NOTES.txt.
###############################################################################

locals {
  gitlab_enabled = var.create_cluster && var.enable_gitlab

  gitlab_db_name     = "gitlabhq_production"
  gitlab_db_username = "gitlab"
}

data "aws_caller_identity" "current" {}

# gitlab_domain and gitlab_acme_email have no sensible default, and getting
# either wrong is only discovered ~20 minutes into an install (a Gateway with
# no DNS, or a Let's Encrypt account that cannot be registered). Fail at plan.
resource "terraform_data" "gitlab_preconditions" {
  count = local.gitlab_enabled ? 1 : 0

  lifecycle {
    precondition {
      condition     = trimspace(var.gitlab_domain) != ""
      error_message = "gitlab_domain must be set when enable_gitlab = true, e.g. \"example.com\". GitLab serves its UI at gitlab.<domain> and cannot be installed without one."
    }

    precondition {
      condition     = can(regex("^[^@\\s]+@[^@\\s]+\\.[^@\\s]+$", var.gitlab_acme_email))
      error_message = "gitlab_acme_email must be a valid email address when enable_gitlab = true. Let's Encrypt requires it to register the ACME account that issues GitLab's certificate."
    }

    precondition {
      condition     = var.enable_ebs_csi_driver
      error_message = "enable_ebs_csi_driver must be true when enable_gitlab = true: Gitaly stores git repositories on a PersistentVolume, which needs the EBS CSI driver and the gp3 StorageClass."
    }

    precondition {
      condition     = try(var.workload_node_groups["infra"].min_size, 0) >= 1
      error_message = "workload_node_groups[\"infra\"].min_size must be at least 1 when enable_gitlab = true. GitLab is pinned to the managed infra nodes (it is stateful and must not run on the Karpenter spot pool), so a floor of 0 would leave every GitLab pod Pending."
    }
  }
}

# ---------------------------------------------------------------------------
# Credentials
# ---------------------------------------------------------------------------

resource "random_password" "gitlab_db" {
  count = local.gitlab_enabled ? 1 : 0

  length = 32
  # RDS rejects '/', '@', '"' and space in a master password.
  override_special = "!#$%&*()-_=+[]{}<>:?"
}

resource "random_password" "gitlab_redis" {
  count = local.gitlab_enabled ? 1 : 0

  length  = 64
  special = false # ElastiCache auth tokens allow only alphanumerics and a few symbols
}

# ---------------------------------------------------------------------------
# Networking
# ---------------------------------------------------------------------------

resource "aws_db_subnet_group" "gitlab" {
  count = local.gitlab_enabled ? 1 : 0

  name       = "${var.cluster_name}-gitlab"
  subnet_ids = module.vpc[0].private_subnets
  tags       = var.tags
}

resource "aws_security_group" "gitlab_db" {
  count = local.gitlab_enabled ? 1 : 0

  name        = "${var.cluster_name}-gitlab-db"
  description = "GitLab PostgreSQL -- reachable only from cluster nodes"
  vpc_id      = module.vpc[0].vpc_id
  tags        = var.tags
}

resource "aws_vpc_security_group_ingress_rule" "gitlab_db" {
  count = local.gitlab_enabled ? 1 : 0

  security_group_id            = aws_security_group.gitlab_db[0].id
  referenced_security_group_id = module.eks[0].node_security_group_id
  from_port                    = 5432
  to_port                      = 5432
  ip_protocol                  = "tcp"
  description                  = "PostgreSQL from EKS nodes"
}

resource "aws_elasticache_subnet_group" "gitlab" {
  count = local.gitlab_enabled ? 1 : 0

  name       = "${var.cluster_name}-gitlab"
  subnet_ids = module.vpc[0].private_subnets
  tags       = var.tags
}

resource "aws_security_group" "gitlab_redis" {
  count = local.gitlab_enabled ? 1 : 0

  name        = "${var.cluster_name}-gitlab-redis"
  description = "GitLab Redis -- reachable only from cluster nodes"
  vpc_id      = module.vpc[0].vpc_id
  tags        = var.tags
}

resource "aws_vpc_security_group_ingress_rule" "gitlab_redis" {
  count = local.gitlab_enabled ? 1 : 0

  security_group_id            = aws_security_group.gitlab_redis[0].id
  referenced_security_group_id = module.eks[0].node_security_group_id
  from_port                    = 6379
  to_port                      = 6379
  ip_protocol                  = "tcp"
  description                  = "Redis from EKS nodes"
}

# ---------------------------------------------------------------------------
# PostgreSQL
# ---------------------------------------------------------------------------

resource "aws_db_parameter_group" "gitlab" {
  count = local.gitlab_enabled ? 1 : 0

  name   = "${var.cluster_name}-gitlab-pg17"
  family = "postgres17"

  # GitLab requires the pg_trgm and btree_gist extensions. Preloading is not
  # required for either, but forcing SSL is, since the chart connects with
  # sslmode=require.
  parameter {
    name  = "rds.force_ssl"
    value = "1"
  }

  tags = var.tags

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_db_instance" "gitlab" {
  count = local.gitlab_enabled ? 1 : 0

  identifier = "${var.cluster_name}-gitlab"

  engine         = "postgres"
  engine_version = var.gitlab_db_engine_version
  instance_class = var.gitlab_db_instance_class

  allocated_storage     = var.gitlab_db_allocated_storage
  max_allocated_storage = var.gitlab_db_allocated_storage * 4
  storage_type          = "gp3"
  storage_encrypted     = true

  db_name  = local.gitlab_db_name
  username = local.gitlab_db_username
  password = random_password.gitlab_db[0].result
  port     = 5432

  db_subnet_group_name   = aws_db_subnet_group.gitlab[0].name
  vpc_security_group_ids = [aws_security_group.gitlab_db[0].id]
  parameter_group_name   = aws_db_parameter_group.gitlab[0].name
  publicly_accessible    = false

  multi_az                = var.gitlab_db_multi_az
  backup_retention_period = 7
  backup_window           = "03:00-04:00"
  maintenance_window      = "Mon:04:00-Mon:05:00"

  auto_minor_version_upgrade = true
  deletion_protection        = var.gitlab_db_deletion_protection
  skip_final_snapshot        = !var.gitlab_db_deletion_protection
  final_snapshot_identifier  = var.gitlab_db_deletion_protection ? "${var.cluster_name}-gitlab-final" : null

  performance_insights_enabled = true
  apply_immediately            = true

  tags = var.tags
}

# ---------------------------------------------------------------------------
# Redis
# ---------------------------------------------------------------------------

resource "aws_elasticache_replication_group" "gitlab" {
  count = local.gitlab_enabled ? 1 : 0

  replication_group_id = "${var.cluster_name}-gitlab"
  description          = "GitLab Redis"

  engine         = "redis"
  engine_version = var.gitlab_redis_engine_version
  node_type      = var.gitlab_redis_node_type
  port           = 6379

  # Single shard, no cluster mode: GitLab expects a plain Redis endpoint.
  num_cache_clusters         = 1
  automatic_failover_enabled = false

  subnet_group_name  = aws_elasticache_subnet_group.gitlab[0].name
  security_group_ids = [aws_security_group.gitlab_redis[0].id]

  # TLS + AUTH. The chart is told scheme=rediss to match (see gitlab.tf).
  at_rest_encryption_enabled = true
  transit_encryption_enabled = true
  auth_token                 = random_password.gitlab_redis[0].result

  maintenance_window       = "mon:05:00-mon:06:00"
  snapshot_retention_limit = 3

  apply_immediately = true

  tags = var.tags
}
