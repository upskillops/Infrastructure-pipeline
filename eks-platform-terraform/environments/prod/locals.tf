locals {
  common_tags = {
    Project     = var.name
    Environment = "prod"
    ManagedBy   = "terraform"
  }
}
