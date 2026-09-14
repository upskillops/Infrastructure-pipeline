###############################################################################
# Module: Fargate – Outputs
###############################################################################

output "profile_ids" {
  description = "Map of Fargate profile names to ARNs"
  value = {
    for k, v in aws_eks_fargate_profile.this : k => v.arn
  }
}
