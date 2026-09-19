###############################################################################
# GitLab -- Helm release pinned to the infra node group, plus its bundled
# Runner, cert-manager and Envoy Gateway.
#
# Browser access: Envoy Gateway gets an internet-facing NLB (via the AWS Load
# Balancer Controller), external-dns points gitlab.<domain> at it, and
# cert-manager issues a Let's Encrypt certificate for it. Net result is
# https://gitlab.<domain> in a browser with no certificate warning.
###############################################################################

locals {
  # Pin GitLab to the *managed* infra nodes rather than the whole infra tier.
  # EKS labels every managed node group node with this automatically. Using it
  # instead of `workload: infra` keeps GitLab off the Karpenter infra pool,
  # which includes spot -- Gitaly owns an EBS volume holding your git
  # repositories and must not be interrupted. CI job pods are the opposite
  # case and are deliberately allowed onto spot (see gitlab-runner below).
  gitlab_node_selector = {
    "eks.amazonaws.com/nodegroup" = "${var.cluster_name}-infra"
  }

  gitlab_tolerations = [{
    key      = "workload"
    operator = "Equal"
    value    = "infra"
    effect   = "NoSchedule"
  }]

  gitlab_bucket_names = { for k, b in aws_s3_bucket.gitlab : k => b.id }
}

resource "kubernetes_namespace" "gitlab" {
  count = local.gitlab_enabled ? 1 : 0

  metadata {
    name = var.gitlab_namespace
  }

  depends_on = [module.node_group]
}

# ---------------------------------------------------------------------------
# Secrets the chart expects to already exist
# ---------------------------------------------------------------------------

resource "kubernetes_secret" "gitlab_postgres" {
  count = local.gitlab_enabled ? 1 : 0

  metadata {
    name      = "gitlab-postgres-password"
    namespace = kubernetes_namespace.gitlab[0].metadata[0].name
  }

  data = {
    password = random_password.gitlab_db[0].result
  }
}

resource "kubernetes_secret" "gitlab_redis" {
  count = local.gitlab_enabled ? 1 : 0

  metadata {
    name      = "gitlab-redis-password"
    namespace = kubernetes_namespace.gitlab[0].metadata[0].name
  }

  data = {
    password = random_password.gitlab_redis[0].result
  }
}

# Object storage for artifacts/LFS/uploads/packages/backups. `use_iam_profile`
# makes Fog pick up the IRSA credentials instead of a static access key.
resource "kubernetes_secret" "gitlab_object_storage" {
  count = local.gitlab_enabled ? 1 : 0

  metadata {
    name      = "gitlab-object-storage"
    namespace = kubernetes_namespace.gitlab[0].metadata[0].name
  }

  data = {
    connection = yamlencode({
      provider        = "AWS"
      region          = var.aws_region
      use_iam_profile = true
    })
  }
}

# The container registry reads its own storage config, in Docker-registry
# format rather than Fog format.
resource "kubernetes_secret" "gitlab_registry_storage" {
  count = local.gitlab_enabled ? 1 : 0

  metadata {
    name      = "gitlab-registry-storage"
    namespace = kubernetes_namespace.gitlab[0].metadata[0].name
  }

  data = {
    config = yamlencode({
      s3 = {
        bucket = local.gitlab_bucket_names["registry"]
        region = var.aws_region
        v4auth = true
        # No accesskey/secretkey: the registry picks up IRSA from the pod.
      }
    })
  }
}

# ---------------------------------------------------------------------------
# GitLab
# ---------------------------------------------------------------------------

resource "helm_release" "gitlab" {
  count = local.gitlab_enabled ? 1 : 0

  name       = "gitlab"
  namespace  = kubernetes_namespace.gitlab[0].metadata[0].name
  repository = "https://charts.gitlab.io/"
  chart      = "gitlab"
  version    = var.gitlab_chart_version

  # A first install runs migrations and pulls ~20 images. Waiting is correct
  # but slow, so it is opt-in via gitlab_wait_for_rollout.
  wait    = var.gitlab_wait_for_rollout
  timeout = 2400

  values = [
    yamlencode({
      global = {
        edition = "ce"

        hosts = {
          domain = var.gitlab_domain
          https  = true
        }

        # Chart v10 fronts GitLab with Gateway API (Envoy Gateway) rather than
        # an nginx Ingress. cert-manager and the HTTP->HTTPS redirect are wired
        # up by the chart itself.
        gatewayApi = {
          enabled              = true
          installEnvoy         = true
          configureCertmanager = true
          httpToHttpsRedirect  = true
        }
        ingress = {
          enabled = false
        }

        # --- external PostgreSQL (RDS) ---
        psql = {
          host     = aws_db_instance.gitlab[0].address
          port     = 5432
          database = local.gitlab_db_name
          username = local.gitlab_db_username
          password = {
            useSecret = true
            secret    = kubernetes_secret.gitlab_postgres[0].metadata[0].name
            key       = "password"
          }
        }

        # --- external Redis (ElastiCache) ---
        # scheme=rediss because the replication group has
        # transit_encryption_enabled; without it every connection is refused.
        redis = {
          host   = aws_elasticache_replication_group.gitlab[0].primary_endpoint_address
          port   = 6379
          scheme = "rediss"
          auth = {
            enabled = true
            secret  = kubernetes_secret.gitlab_redis[0].metadata[0].name
            key     = "password"
          }
        }

        # --- external object storage (S3 via IRSA) ---
        appConfig = {
          object_store = {
            enabled        = true
            proxy_download = true
            connection = {
              secret = kubernetes_secret.gitlab_object_storage[0].metadata[0].name
              key    = "connection"
            }
          }
          artifacts       = { bucket = local.gitlab_bucket_names["artifacts"] }
          lfs             = { bucket = local.gitlab_bucket_names["lfs"] }
          uploads         = { bucket = local.gitlab_bucket_names["uploads"] }
          packages        = { bucket = local.gitlab_bucket_names["packages"] }
          externalDiffs   = { bucket = local.gitlab_bucket_names["externalDiffs"] }
          ciSecureFiles   = { bucket = local.gitlab_bucket_names["ciSecureFiles"] }
          dependencyProxy = { bucket = local.gitlab_bucket_names["dependencyProxy"] }
          terraformState  = { bucket = local.gitlab_bucket_names["terraformState"] }
          pages           = { bucket = local.gitlab_bucket_names["pages"] }
          backups = {
            bucket    = local.gitlab_bucket_names["backups"]
            tmpBucket = local.gitlab_bucket_names["tmp"]
          }
        }

        # IRSA: every GitLab ServiceAccount assumes the S3 role.
        serviceAccount = {
          enabled = true
          create  = true
          annotations = {
            "eks.amazonaws.com/role-arn" = aws_iam_role.gitlab_s3[0].arn
          }
        }

        # Honoured by _application.tpl for every GitLab component.
        nodeSelector = local.gitlab_node_selector
        tolerations  = local.gitlab_tolerations
      }

      # Let's Encrypt account for the chart-managed issuer.
      certmanager-issuer = {
        email = var.gitlab_acme_email
      }

      # cert-manager ships with the chart; keep its pods on infra too.
      certmanager = {
        installCRDs  = true
        nodeSelector = local.gitlab_node_selector
        tolerations  = local.gitlab_tolerations
        webhook = {
          nodeSelector = local.gitlab_node_selector
          tolerations  = local.gitlab_tolerations
        }
        cainjector = {
          nodeSelector = local.gitlab_node_selector
          tolerations  = local.gitlab_tolerations
        }
        startupapicheck = {
          nodeSelector = local.gitlab_node_selector
          tolerations  = local.gitlab_tolerations
        }
      }

      # The Envoy Gateway control plane.
      "envoy-gateway" = {
        deployment = {
          pod = {
            nodeSelector = local.gitlab_node_selector
            tolerations  = local.gitlab_tolerations
          }
        }

        # certgen is a Helm hook Job that mints Envoy Gateway's internal certs.
        # It is the one pod the chart does not cover via global.nodeSelector,
        # and because it is a hook the whole release blocks until it completes.
        certgen = {
          job = {
            nodeSelector = local.gitlab_node_selector
            tolerations  = local.gitlab_tolerations
          }
        }
      }

      # This is what turns the Gateway into a browser-reachable endpoint:
      # Envoy Gateway copies these onto the Service it creates, and the AWS
      # Load Balancer Controller turns that into an internet-facing NLB.
      gatewayApiResources = {
        gateway = {
          infrastructure = {
            annotations = {
              "service.beta.kubernetes.io/aws-load-balancer-type"            = "external"
              "service.beta.kubernetes.io/aws-load-balancer-nlb-target-type" = "ip"
              "service.beta.kubernetes.io/aws-load-balancer-scheme"          = "internet-facing"
              "service.beta.kubernetes.io/aws-load-balancer-name"            = "${var.cluster_name}-gitlab"
            }
          }
        }
      }

      # Prometheus/Grafana belong on the monitoring tier, not bundled in here.
      prometheus = {
        install = false
      }

      # --- component sizing, tuned for m7g.xlarge infra nodes ---
      gitlab = {
        webservice = {
          minReplicas = var.gitlab_webservice_replicas
          maxReplicas = var.gitlab_webservice_replicas + 2
          resources   = { requests = { cpu = "500m", memory = "2Gi" } }
        }
        sidekiq = {
          minReplicas = var.gitlab_sidekiq_replicas
          maxReplicas = var.gitlab_sidekiq_replicas + 2
          resources   = { requests = { cpu = "400m", memory = "1500Mi" } }
        }
        "gitlab-shell" = {
          minReplicas = 2
          maxReplicas = 3
        }
        toolbox = {
          resources = { requests = { cpu = "100m", memory = "512Mi" } }
          # Backups run from here; it needs the S3 role too.
          backups = {
            objectStorage = {
              config = {
                secret = kubernetes_secret.gitlab_object_storage[0].metadata[0].name
                key    = "connection"
              }
            }
          }
        }
        gitaly = {
          persistence = {
            size         = var.gitlab_gitaly_storage_size
            storageClass = "gp3"
          }
          resources = { requests = { cpu = "500m", memory = "2Gi" } }
        }
      }

      registry = {
        enabled = true
        storage = {
          secret = kubernetes_secret.gitlab_registry_storage[0].metadata[0].name
          key    = "config"
        }
      }

      # --- bundled GitLab Runner ---
      # Ships with the chart and self-registers against this GitLab, which
      # avoids the usual chicken-and-egg of needing a registration token from
      # a UI that does not exist yet.
      "gitlab-runner" = {
        install = true

        # The runner *manager* sits with GitLab on stable on-demand nodes.
        nodeSelector = local.gitlab_node_selector
        tolerations  = local.gitlab_tolerations

        rbac = {
          create = true
        }

        runners = {
          # CI *job* pods are the ideal spot workload: short-lived and
          # restartable. Selecting on `workload: infra` (rather than the
          # node group label above) lets them land on either the managed
          # nodes or the Karpenter infra pool, which includes spot.
          config = <<-TOML
            [[runners]]
              [runners.kubernetes]
                namespace = "{{.Release.Namespace}}"
                image = "alpine:3.21"
                cpu_request = "500m"
                memory_request = "1Gi"
                helper_image = "${var.gitlab_runner_helper_image}"
                [runners.kubernetes.node_selector]
                  "workload" = "infra"
                  "kubernetes.io/arch" = "arm64"
                [[runners.kubernetes.node_tolerations]]
                  key = "workload"
                  operator = "Equal"
                  value = "infra"
                  effect = "NoSchedule"
          TOML
        }
      }
    })
  ]

  depends_on = [
    aws_db_instance.gitlab,
    aws_elasticache_replication_group.gitlab,
    aws_iam_role_policy.gitlab_s3,
    kubernetes_storage_class_v1.gp3,
    helm_release.aws_lbc,
    helm_release.external_dns,
    aws_eks_addon.coredns,
  ]
}
