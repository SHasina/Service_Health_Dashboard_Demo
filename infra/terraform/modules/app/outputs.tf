output "backend_service_name" {
  value = kubernetes_service_v1.backend.metadata[0].name
}

output "frontend_service_name" {
  value = kubernetes_service_v1.frontend.metadata[0].name
}
