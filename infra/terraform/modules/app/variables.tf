variable "namespace" {
  description = "Namespace to deploy application workloads into."
  type        = string
}

variable "backend_image" {
  type    = string
  default = "health-dashboard/backend:local"
}

variable "frontend_image" {
  type    = string
  default = "health-dashboard/frontend:local"
}

variable "mock_image" {
  type    = string
  default = "health-dashboard/mock-service:local"
}

variable "image_pull_policy" {
  description = "Images are built locally and loaded into kind via `kind load docker-image`, so they never need to be pulled from a registry."
  type        = string
  default     = "IfNotPresent"
}

variable "mock_services" {
  description = "Mock downstream services to deploy, keyed by name, with the MOCK_MODE each should run in."
  type        = map(string)
  default = {
    user-service    = "healthy"
    order-service   = "slow"
    payment-service = "healthy"
  }
}
