###############################################################################
# GitLab object storage -- S3 + IRSA.
#
# Chart v10 requires external object storage; there is no bundled MinIO to
# fall back to. Access is via IRSA (use_iam_profile) rather than a static
# access key in a Secret, which is the pattern the rest of this stack uses.
###############################################################################

locals {
  # Bucket names are globally unique across all of AWS, hence the account id.
  gitlab_bucket_suffix = "${var.cluster_name}-${data.aws_caller_identity.current.account_id}"

  gitlab_buckets = local.gitlab_enabled ? {
    artifacts       = "gitlab-artifacts-${local.gitlab_bucket_suffix}"
    lfs             = "gitlab-lfs-${local.gitlab_bucket_suffix}"
    uploads         = "gitlab-uploads-${local.gitlab_bucket_suffix}"
    packages        = "gitlab-packages-${local.gitlab_bucket_suffix}"
    backups         = "gitlab-backups-${local.gitlab_bucket_suffix}"
    tmp             = "gitlab-tmp-${local.gitlab_bucket_suffix}"
    registry        = "gitlab-registry-${local.gitlab_bucket_suffix}"
    ciSecureFiles   = "gitlab-ci-secure-files-${local.gitlab_bucket_suffix}"
    dependencyProxy = "gitlab-dependency-proxy-${local.gitlab_bucket_suffix}"
    terraformState  = "gitlab-tf-state-${local.gitlab_bucket_suffix}"
    externalDiffs   = "gitlab-mr-diffs-${local.gitlab_bucket_suffix}"
    pages           = "gitlab-pages-${local.gitlab_bucket_suffix}"
  } : {}
}

resource "aws_s3_bucket" "gitlab" {
  for_each = local.gitlab_buckets

  bucket = each.value
  tags   = merge(var.tags, { GitLabPurpose = each.key })
}

resource "aws_s3_bucket_public_access_block" "gitlab" {
  for_each = local.gitlab_buckets

  bucket                  = aws_s3_bucket.gitlab[each.key].id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "gitlab" {
  for_each = local.gitlab_buckets

  bucket = aws_s3_bucket.gitlab[each.key].id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_versioning" "gitlab" {
  for_each = local.gitlab_buckets

  bucket = aws_s3_bucket.gitlab[each.key].id

  versioning_configuration {
    status = "Enabled"
  }
}

# Backups and the backup scratch bucket grow without bound otherwise.
resource "aws_s3_bucket_lifecycle_configuration" "gitlab_backups" {
  for_each = { for k, v in local.gitlab_buckets : k => v if contains(["backups", "tmp"], k) }

  bucket = aws_s3_bucket.gitlab[each.key].id

  rule {
    id     = "expire-old-backups"
    status = "Enabled"

    filter {}

    expiration {
      days = each.key == "tmp" ? 7 : 90
    }

    noncurrent_version_expiration {
      noncurrent_days = 7
    }
  }
}

# ---------------------------------------------------------------------------
# IRSA role assumed by every GitLab service account in the namespace
# ---------------------------------------------------------------------------

data "aws_iam_policy_document" "gitlab_s3_assume" {
  count = local.gitlab_enabled ? 1 : 0

  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [module.eks[0].oidc_provider_arn]
    }

    # The chart creates a separate ServiceAccount per component (webservice,
    # sidekiq, toolbox, registry, ...), so this is scoped by namespace rather
    # than enumerating every name the chart might add.
    condition {
      test     = "StringLike"
      variable = "${module.eks[0].oidc_provider}:sub"
      values   = ["system:serviceaccount:${var.gitlab_namespace}:*"]
    }

    condition {
      test     = "StringEquals"
      variable = "${module.eks[0].oidc_provider}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "gitlab_s3" {
  count = local.gitlab_enabled ? 1 : 0

  name               = "${var.cluster_name}-gitlab-s3"
  assume_role_policy = data.aws_iam_policy_document.gitlab_s3_assume[0].json
  tags               = var.tags
}

resource "aws_iam_role_policy" "gitlab_s3" {
  count = local.gitlab_enabled ? 1 : 0

  name = "gitlab-object-storage"
  role = aws_iam_role.gitlab_s3[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["s3:ListBucket", "s3:GetBucketLocation", "s3:ListBucketMultipartUploads"]
        Resource = [for b in aws_s3_bucket.gitlab : b.arn]
      },
      {
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:PutObject",
          "s3:DeleteObject",
          "s3:AbortMultipartUpload",
          "s3:ListMultipartUploadParts",
        ]
        Resource = [for b in aws_s3_bucket.gitlab : "${b.arn}/*"]
      },
    ]
  })
}
