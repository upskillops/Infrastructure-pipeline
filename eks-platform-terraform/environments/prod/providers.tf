provider "aws" {
  region = var.region

  default_tags {
    tags = local.common_tags
  }
}

# The kubernetes/helm providers authenticate to the cluster this same
# root module creates, using a short-lived exec-based token (no static
# kubeconfig needed). This does mean `terraform plan` before the cluster
# exists will fail to authenticate for kubernetes/helm resources - that's
# expected on a first-ever apply; see README for the two-phase approach.
provider "kubernetes" {
  host                   = module.eks.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks.cluster_ca_data)

  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = ["eks", "get-token", "--cluster-name", module.eks.cluster_name, "--region", var.region]
  }
}

provider "helm" {
  kubernetes {
    host                   = module.eks.cluster_endpoint
    cluster_ca_certificate = base64decode(module.eks.cluster_ca_data)

    exec {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      args        = ["eks", "get-token", "--cluster-name", module.eks.cluster_name, "--region", var.region]
    }
  }
}
