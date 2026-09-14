# Remote state - create the S3 bucket out-of-band (or in a bootstrap root)
# before running `terraform init` here. State locking uses S3's native
# lockfile support (Terraform >= 1.10 / AWS provider >= 5.73), so no
# DynamoDB lock table is required.
#
# If you're on an older Terraform (< 1.10), replace `use_lockfile` below
# with `dynamodb_table = "REPLACE_ME-tfstate-lock"` and provision that
# table (partition key "LockID", type String) instead.
terraform {
  backend "s3" {
    bucket       = "REPLACE_ME-tfstate-bucket"
    key          = "eks-platform/prod/terraform.tfstate"
    region       = "us-east-1"
    use_lockfile = true
    encrypt      = true
  }
}
