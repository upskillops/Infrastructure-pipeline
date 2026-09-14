variable "cilium_version" {
  type    = string
  default = "1.16.5"
}

variable "istio_version" {
  type    = string
  default = "1.23.2"
}

variable "pod_cidr" {
  description = "Cilium overlay pod CIDR (separate from VPC CIDR, per reference diagram)"
  type        = string
  default     = "100.64.0.0/16"
}

variable "cluster_name" {
  type = string
}

variable "install_cilium" {
  type    = bool
  default = true
}

variable "install_istio" {
  type    = bool
  default = true
}

variable "install_kyverno" {
  type    = bool
  default = true
}

variable "install_observability" {
  description = "Install kube-prometheus-stack (Prometheus + Grafana) and Loki"
  type        = bool
  default     = true
}
