variable "namespace" {
  description = "Namespace the application runs in (mesh policies are scoped here)."
  type        = string
}

variable "chart_version" {
  description = "Version of the istio-base/istiod/gateway Helm charts to install."
  type        = string
}

variable "kube_context" {
  description = "kubectl context used by local-exec to apply Istio custom resources once their CRDs exist."
  type        = string
  default     = "kind-health-dashboard"
}
