variable "kubeconfig_path" {
  description = "Path to the kubeconfig file managing the kind cluster."
  type        = string
  default     = "~/.kube/config"
}

variable "kube_context" {
  description = "kubeconfig context for the kind cluster (kind prefixes cluster names with 'kind-')."
  type        = string
  default     = "kind-health-dashboard"
}

variable "namespace" {
  description = "Namespace the application and mesh resources are deployed into."
  type        = string
  default     = "health-dashboard"
}

variable "enable_istio" {
  description = "Whether to install Istio and mesh policies. Disable to run the app on plain Kubernetes (Phase 4 baseline)."
  type        = bool
  default     = true
}

variable "istio_chart_version" {
  description = "Version of the Istio Helm charts (istio-base, istiod, gateway) to install."
  type        = string
  default     = "1.23.2"
}
