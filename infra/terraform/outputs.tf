output "namespace" {
  value = module.namespace.namespace_name
}

output "frontend_service" {
  value = module.app.frontend_service_name
}

output "backend_service" {
  value = module.app.backend_service_name
}
