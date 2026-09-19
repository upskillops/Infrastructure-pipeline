###############################################################################
# Cluster identity
###############################################################################

variable "cluster_name" {
  description = "Name of the EKS cluster. If create_cluster = true this is the name given to the new cluster; if false it is the existing cluster to attach to."
  type        = string
}

variable "aws_region" {
  type    = string
  default = "us-east-1"
}

variable "create_cluster" {
  description = "If true, provisions VPC + EKS cluster + Cilium + Graviton node groups + Karpenter. If false, attaches Karpenter NodePools to an existing cluster."
  type        = bool
  default     = true
}

variable "tags" {
  type    = map(string)
  default = {}
}

###############################################################################
# Only used when create_cluster = true
###############################################################################

variable "kubernetes_version" {
  description = "EKS control plane version. 1.35 is in standard support until 2027-03-27."
  type        = string
  default     = "1.35"
}

variable "vpc_cidr" {
  type    = string
  default = "10.0.0.0/16"
}

variable "public_subnet_cidrs" {
  description = "One per AZ, matching the design's Public Subnet A/B/C."
  type        = list(string)
  default     = ["10.0.1.0/24", "10.0.2.0/24", "10.0.3.0/24"]
}

variable "private_subnet_cidrs" {
  description = "One per AZ. All nodes -- managed node groups and Karpenter-launched -- live here. /20s because Cilium ENI mode gives every pod a real VPC IP, so pod density is bounded by subnet size, not by an overlay."
  type        = list(string)
  default     = ["10.0.16.0/20", "10.0.32.0/20", "10.0.48.0/20"]
}

variable "az_count" {
  description = "Number of AZs to spread subnets across."
  type        = number
  default     = 3
}

variable "single_nat_gateway" {
  description = "true = one shared NAT gateway (cheaper, not HA). false = one per AZ, matching the design."
  type        = bool
  default     = false
}

variable "cluster_endpoint_public_access" {
  description = "Whether the EKS API server is reachable from the internet (still IAM/RBAC gated)."
  type        = bool
  default     = true
}

variable "cluster_endpoint_public_access_cidrs" {
  type    = list(string)
  default = ["0.0.0.0/0"]
}

variable "cluster_enabled_log_types" {
  description = "Control plane log types. Empty list disables control plane logging (each enabled type is a CloudWatch log stream you pay for)."
  type        = list(string)
  default     = ["api", "audit", "authenticator"]
}

###############################################################################
# Cilium
###############################################################################

variable "install_cilium" {
  description = "Install Cilium as the sole CNI (full kube-proxy + VPC CNI replacement). Only meaningful with create_cluster = true -- swapping the CNI on a live cluster is a migration, not a create."
  type        = bool
  default     = true
}

variable "cilium_version" {
  description = "Cilium Helm chart version."
  type        = string
  default     = "1.19.8"
}

variable "cilium_enable_prefix_delegation" {
  description = "Let Cilium assign /28 prefixes to ENIs instead of single IPs. Dramatically raises pods-per-node, which matters because Graviton instances here are large."
  type        = bool
  default     = true
}

variable "cilium_enable_hubble_relay" {
  description = "Deploy Hubble Relay for cluster-wide flow visibility. The Hubble UI is left off."
  type        = bool
  default     = true
}

###############################################################################
# Worker node groups (EC2, Graviton)
###############################################################################

variable "workload_node_groups" {
  description = <<-EOT
    EKS managed node groups -- the guaranteed floor for each tier. Karpenter
    handles burst above these numbers via the matching entry in
    karpenter_nodepools.

    taint_workload = null leaves the group untainted (used by "core", which has
    to host CoreDNS / Cilium operator / Karpenter itself). Any other value
    applies workload=<value>:NoSchedule and the matching node label, so a tier's
    managed nodes and its Karpenter nodes are interchangeable to the scheduler.
  EOT
  type = map(object({
    instance_types = list(string)
    capacity_type  = optional(string, "ON_DEMAND")
    ami_type       = optional(string, "AL2023_ARM_64_STANDARD")
    min_size       = number
    max_size       = number
    desired_size   = number
    disk_size      = optional(number, 50)
    taint_workload = optional(string)
    extra_labels   = optional(map(string), {})
  }))

  default = {
    # System tier. Untainted on purpose: CoreDNS, the Cilium operator, the EBS
    # CSI controller and the Karpenter controller ship without tolerations for a
    # custom taint, and Karpenter cannot manage the nodes it runs on.
    core = {
      instance_types = ["m7g.large", "m8g.large"]
      min_size       = 2
      max_size       = 4
      desired_size   = 2
      disk_size      = 50
      taint_workload = null
      extra_labels   = { node-role = "core" }
    }

    # Sized to host GitLab (webservice, sidekiq, gitaly, registry, kas, the
    # runner manager, cert-manager and Envoy Gateway) with room to spare:
    # 3 x m7g.xlarge = 12 vCPU / 48 GiB. The floor is non-zero because GitLab
    # is stateful -- Gitaly owns an EBS volume holding your git repositories --
    # so it must not depend on Karpenter, whose infra pool includes spot.
    # Drop min/desired back to 0 if you set enable_gitlab = false.
    infra = {
      instance_types = ["m7g.xlarge", "m8g.xlarge", "c7g.2xlarge"]
      min_size       = 3
      max_size       = 10
      desired_size   = 3
      disk_size      = 80
      taint_workload = "infra"
    }

    app = {
      instance_types = ["m7g.xlarge", "m8g.xlarge", "r7g.xlarge"]
      min_size       = 3
      max_size       = 30
      desired_size   = 3
      disk_size      = 80
      taint_workload = "app"
    }

    # Memory-biased for Prometheus / Loki.
    monitoring = {
      instance_types = ["r7g.xlarge", "r8g.xlarge", "m7g.2xlarge"]
      min_size       = 2
      max_size       = 8
      desired_size   = 2
      disk_size      = 150
      taint_workload = "monitoring"
    }
  }
}

###############################################################################
# Karpenter burst pools
###############################################################################

variable "karpenter_version" {
  description = "Karpenter Helm chart version."
  type        = string
  default     = "1.14.1"
}

variable "karpenter_replicas" {
  description = "Karpenter controller replicas. The chart applies a *required* podAntiAffinity on hostname, so this many distinct core nodes must exist. Drop to 1 on a single-node or tiny-node cluster."
  type        = number
  default     = 2
}

variable "cilium_operator_replicas" {
  description = "Cilium operator replicas. 1 is fine on small clusters; the operator is not on the data path."
  type        = number
  default     = 2
}

variable "karpenter_nodepools" {
  description = "Karpenter NodePools providing burst capacity above the managed node group floors. Keys must match workload_node_groups keys so the taint and label line up."
  type = map(object({
    instance_categories = list(string)
    instance_sizes      = list(string)
    capacity_types      = optional(list(string), ["on-demand"])
    limits = object({
      cpu    = string
      memory = string
    })
    consolidate_after  = optional(string, "5m")
    disruption_budgets = optional(list(map(string)), [{ nodes = "20%" }])
    volume_size_gb     = optional(number, 50)
  }))

  default = {
    infra = {
      instance_categories = ["c", "m"]
      instance_sizes      = ["large", "xlarge", "2xlarge"]
      capacity_types      = ["spot", "on-demand"]
      limits              = { cpu = "160", memory = "640Gi" }
      consolidate_after   = "5m"
      disruption_budgets  = [{ nodes = "20%" }]
      volume_size_gb      = 50
    }
    app = {
      instance_categories = ["m", "r"]
      instance_sizes      = ["large", "xlarge", "2xlarge", "4xlarge"]
      capacity_types      = ["on-demand"]
      limits              = { cpu = "480", memory = "1920Gi" }
      consolidate_after   = "10m"
      disruption_budgets  = [{ nodes = "10%" }]
      volume_size_gb      = 80
    }
    monitoring = {
      instance_categories = ["r", "m"]
      instance_sizes      = ["large", "xlarge", "2xlarge"]
      capacity_types      = ["on-demand"]
      limits              = { cpu = "128", memory = "1024Gi" }
      consolidate_after   = "10m"
      disruption_budgets  = [{ nodes = "1" }] # never disrupt >1 monitoring node at once
      volume_size_gb      = 150
    }
  }
}

variable "karpenter_min_instance_generation" {
  description = "Exclusive Gt floor on karpenter.k8s.aws/instance-generation. 6 restricts Karpenter to 7g/8g Graviton, skipping the older 6g families."
  type        = string
  default     = "6"
}

variable "karpenter_ami_alias" {
  description = "EC2NodeClass amiSelectorTerms alias. Karpenter v1 *requires* amiSelectorTerms -- the previous revision set only amiFamily, which the v1 CRD rejects."
  type        = string
  default     = "al2023@latest"
}

###############################################################################
# Addons
###############################################################################

variable "enable_ebs_csi_driver" {
  description = "Install the EBS CSI driver addon. Needed for PersistentVolumes -- without it the monitoring tier cannot back Prometheus/Loki with disk."
  type        = bool
  default     = true
}

###############################################################################
# Existing-cluster path only
###############################################################################

variable "node_iam_role_name" {
  description = "Only used when create_cluster = false. On the create path the node role is created and named by the Karpenter submodule."
  type        = string
  default     = "karpenter-node-role"
}

###############################################################################
# GitLab
###############################################################################

variable "enable_gitlab" {
  description = "Install GitLab (plus its bundled Runner, cert-manager and Envoy Gateway) onto the infra node group, with RDS PostgreSQL, ElastiCache Redis and S3 behind it."
  type        = bool
  default     = true
}

variable "gitlab_domain" {
  description = "Base domain for GitLab. The chart derives gitlab.<domain>, registry.<domain> and kas.<domain> from it. REQUIRED when enable_gitlab = true."
  type        = string
  default     = ""
}

variable "gitlab_acme_email" {
  description = "Contact email for the Let's Encrypt account used to issue GitLab's certificates. REQUIRED when enable_gitlab = true."
  type        = string
  default     = ""
}

variable "create_route53_zone" {
  description = "Create a public Route53 hosted zone for gitlab_domain. Set false if the zone already exists (it will be looked up instead)."
  type        = bool
  default     = true
}

variable "gitlab_namespace" {
  type    = string
  default = "gitlab"
}

variable "gitlab_chart_version" {
  description = "GitLab Helm chart version. 10.4.0 = GitLab 19.4.0. Note chart v10 removed the bundled PostgreSQL/Redis/object storage -- all three are now external and provisioned here."
  type        = string
  default     = "10.4.0"
}

variable "gitlab_wait_for_rollout" {
  description = "Block terraform apply until every GitLab pod is Ready. A first install runs migrations and pulls ~20 images, so this adds 10-20 minutes. Left false so apply returns promptly; watch progress with kubectl -n gitlab get pods -w."
  type        = bool
  default     = false
}

# ---- RDS PostgreSQL ----

variable "gitlab_db_instance_class" {
  description = "Graviton RDS class. db.m7g.large = 2 vCPU / 8 GiB."
  type        = string
  default     = "db.m7g.large"
}

variable "gitlab_db_engine_version" {
  description = "PostgreSQL version. GitLab chart 10.x requires 17 or newer -- 16 fails the migration job's version check."
  type        = string
  default     = "17.11"
}

variable "gitlab_db_allocated_storage" {
  type    = number
  default = 100
}

variable "gitlab_db_multi_az" {
  description = "Multi-AZ RDS. Roughly doubles the database cost."
  type        = bool
  default     = false
}

variable "gitlab_db_deletion_protection" {
  description = "Block `terraform destroy` from dropping the GitLab database."
  type        = bool
  default     = false
}

# ---- ElastiCache Redis ----

variable "gitlab_redis_node_type" {
  description = "Graviton ElastiCache node type."
  type        = string
  default     = "cache.m7g.large"
}

variable "gitlab_redis_engine_version" {
  description = "ElastiCache Redis version. 7.1 is the newest the redis engine offers in us-east-1."
  type        = string
  default     = "7.1"
}

# ---- Sizing ----

variable "gitlab_webservice_replicas" {
  type    = number
  default = 2
}

variable "gitlab_sidekiq_replicas" {
  type    = number
  default = 2
}

variable "gitlab_gitaly_storage_size" {
  description = "Gitaly repository volume (gp3). This is where git repositories actually live."
  type        = string
  default     = "100Gi"
}

variable "gitlab_runner_helper_image" {
  description = <<-EOT
    Helper image for the Runner's Kubernetes executor. Unlike the runner image
    itself, this one is published per-architecture rather than as a manifest
    list, so on Graviton it must carry the arm64- prefix or every CI job dies
    with "exec format error". The tag tracks the gitlab-runner SUBCHART's app
    version (0.92.2 -> 19.3.2), not the GitLab version.
  EOT
  type        = string
  default     = "registry.gitlab.com/gitlab-org/gitlab-runner/gitlab-runner-helper:arm64-v19.3.2"
}
