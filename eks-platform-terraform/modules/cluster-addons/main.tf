# This module assumes the `helm` and `kubernetes` providers are already
# configured in the root module against the EKS cluster created by
# module.eks. It installs the cluster-internal pieces of the reference
# architecture that live inside Kubernetes rather than as AWS resources:
# Cilium (CNI/eBPF), Istio (ingress/egress gateways + mesh), Kyverno
# (policy), and the observability stack (Prometheus/Grafana, Loki, Hubble UI).

#############################
# Cilium - primary CNI, replaces aws-vpc-cni
#############################
resource "helm_release" "cilium" {
  count            = var.install_cilium ? 1 : 0
  name             = "cilium"
  repository       = "https://helm.cilium.io/"
  chart            = "cilium"
  version          = var.cilium_version
  namespace        = "kube-system"

  values = [yamlencode({
    eni = {
      enabled = false
    }
    ipam = {
      mode = "cluster-pool"
      operator = {
        clusterPoolIPv4PodCIDRList = [var.pod_cidr]
      }
    }
    tunnel                  = "vxlan"
    kubeProxyReplacement    = true
    hubble = {
      enabled = true
      relay   = { enabled = true }
      ui      = { enabled = true }
    }
    prometheus = { enabled = true }
    operator = {
      prometheus = { enabled = true }
    }
  })]
}

#############################
# Istio - base + istiod (control plane). Ingress/egress gateway
# Deployments+Services are best managed as separate application
# workloads (IstioOperator or per-gateway Helm release) once the
# mesh is up; the control plane is provisioned here.
#############################
resource "helm_release" "istio_base" {
  count            = var.install_istio ? 1 : 0
  name             = "istio-base"
  repository       = "https://istio-release.storage.googleapis.com/charts"
  chart            = "base"
  version          = var.istio_version
  namespace        = "istio-system"
  create_namespace = true

  depends_on = [helm_release.cilium]
}

resource "helm_release" "istiod" {
  count      = var.install_istio ? 1 : 0
  name       = "istiod"
  repository = "https://istio-release.storage.googleapis.com/charts"
  chart      = "istiod"
  version    = var.istio_version
  namespace  = "istio-system"

  values = [yamlencode({
    meshConfig = {
      enableAutoMtls = true
    }
  })]

  depends_on = [helm_release.istio_base]
}

resource "helm_release" "istio_ingress_gateway" {
  count            = var.install_istio ? 1 : 0
  name             = "istio-ingressgateway"
  repository       = "https://istio-release.storage.googleapis.com/charts"
  chart            = "gateway"
  version          = var.istio_version
  namespace        = "istio-ingress"
  create_namespace = true

  values = [yamlencode({
    service = {
      type = "LoadBalancer"
      annotations = {
        "service.beta.kubernetes.io/aws-load-balancer-type"            = "external"
        "service.beta.kubernetes.io/aws-load-balancer-nlb-target-type" = "ip"
        "service.beta.kubernetes.io/aws-load-balancer-scheme"          = "internet-facing"
      }
    }
  })]

  depends_on = [helm_release.istiod]
}

resource "helm_release" "istio_egress_gateway" {
  count            = var.install_istio ? 1 : 0
  name             = "istio-egressgateway"
  repository       = "https://istio-release.storage.googleapis.com/charts"
  chart            = "gateway"
  version          = var.istio_version
  namespace        = "istio-egress"
  create_namespace = true

  values = [yamlencode({
    service = {
      type = "ClusterIP"
    }
  })]

  depends_on = [helm_release.istiod]
}

#############################
# Kyverno - policy engine
#############################
resource "helm_release" "kyverno" {
  count            = var.install_kyverno ? 1 : 0
  name             = "kyverno"
  repository       = "https://kyverno.github.io/kyverno/"
  chart            = "kyverno"
  namespace        = "kyverno"
  create_namespace = true
}

#############################
# Observability: kube-prometheus-stack + Loki
#############################
resource "helm_release" "kube_prometheus_stack" {
  count            = var.install_observability ? 1 : 0
  name             = "kube-prometheus-stack"
  repository       = "https://prometheus-community.github.io/helm-charts"
  chart            = "kube-prometheus-stack"
  namespace        = "monitoring"
  create_namespace = true

  values = [yamlencode({
    grafana = {
      enabled = true
    }
  })]
}

resource "helm_release" "loki" {
  count            = var.install_observability ? 1 : 0
  name             = "loki"
  repository       = "https://grafana.github.io/helm-charts"
  chart            = "loki-stack"
  namespace        = "monitoring"
  create_namespace = true

  depends_on = [helm_release.kube_prometheus_stack]
}
