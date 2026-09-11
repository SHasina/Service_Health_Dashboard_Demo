variable "namespace" {
  description = "Name of the namespace to create."
  type        = string
}

variable "enable_istio_inject" {
  description = "Label the namespace for automatic Istio sidecar injection."
  type        = bool
  default     = true
}
