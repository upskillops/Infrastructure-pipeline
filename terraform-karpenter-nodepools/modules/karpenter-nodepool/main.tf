locals {
  subnet_selector_terms = length(var.subnet_selector_terms) > 0 ? var.subnet_selector_terms : [
    { tags = { "karpenter.sh/discovery" = var.cluster_name } }
  ]

  security_group_selector_terms = length(var.security_group_selector_terms) > 0 ? var.security_group_selector_terms : [
    { tags = { "karpenter.sh/discovery" = var.cluster_name } }
  ]

  node_labels = merge(
    { (var.taint_key) = var.taint_value },
    var.extra_labels,
  )
}

resource "kubectl_manifest" "ec2nodeclass" {
  yaml_body = yamlencode({
    apiVersion = "karpenter.k8s.aws/v1"
    kind       = "EC2NodeClass"
    metadata = {
      name = var.name
    }
    spec = {
      # amiSelectorTerms is REQUIRED by the Karpenter v1 CRD. The previous
      # revision set only `amiFamily` and omitted this, so every EC2NodeClass
      # it submitted was rejected by the API server and no Karpenter node could
      # ever launch. The alias form ("al2023@latest") also implies the family,
      # which is why amiFamily is no longer set here.
      amiSelectorTerms = [{ alias = var.ami_alias }]

      role                       = var.node_iam_role_name
      subnetSelectorTerms        = local.subnet_selector_terms
      securityGroupSelectorTerms = local.security_group_selector_terms

      blockDeviceMappings = [{
        deviceName = "/dev/xvda"
        ebs = {
          volumeSize          = "${var.volume_size_gb}Gi"
          volumeType          = "gp3"
          encrypted           = true
          deleteOnTermination = true
        }
      }]

      metadataOptions = {
        httpEndpoint            = "enabled"
        httpProtocolIPv6        = "disabled"
        httpPutResponseHopLimit = 2
        httpTokens              = "required"
      }

      tags = merge(var.tags, {
        "karpenter.sh/discovery" = var.cluster_name
        "nodepool"               = var.name
      })
    }
  })
}

resource "kubectl_manifest" "nodepool" {
  yaml_body = yamlencode({
    apiVersion = "karpenter.sh/v1"
    kind       = "NodePool"
    metadata = {
      name = var.name
    }
    spec = {
      template = {
        metadata = {
          labels = local.node_labels
        }
        spec = {
          nodeClassRef = {
            group = "karpenter.k8s.aws"
            kind  = "EC2NodeClass"
            name  = var.name
          }

          # Same taint the tier's managed node group applies, so the scheduler
          # sees managed nodes and Karpenter nodes in this tier as equivalent.
          taints = [{
            key    = var.taint_key
            value  = var.taint_value
            effect = "NoSchedule"
          }]

          requirements = concat(
            [
              # Graviton only. Combined with the generation floor below this
              # resolves to the 7g/8g families (c7g/c8g, m7g/m8g, r7g/r8g).
              { key = "kubernetes.io/arch", operator = "In", values = [var.architecture] },
              { key = "karpenter.k8s.aws/instance-category", operator = "In", values = var.instance_categories },
              { key = "karpenter.k8s.aws/instance-size", operator = "In", values = var.instance_sizes },
              { key = "karpenter.sh/capacity-type", operator = "In", values = var.capacity_types },
              { key = "kubernetes.io/os", operator = "In", values = ["linux"] },
            ],
            var.min_instance_generation != null ? [
              { key = "karpenter.k8s.aws/instance-generation", operator = "Gt", values = [var.min_instance_generation] }
            ] : []
          )

          expireAfter = var.expire_after
        }
      }

      limits = var.limits

      disruption = {
        consolidationPolicy = var.consolidation_policy
        consolidateAfter    = var.consolidate_after
        budgets             = var.disruption_budgets
      }
    }
  })

  depends_on = [kubectl_manifest.ec2nodeclass]
}
