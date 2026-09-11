module "namespace" {
  source = "./modules/namespace"

  namespace          = var.namespace
  enable_istio_inject = var.enable_istio
}

module "app" {
  source = "./modules/app"

  namespace = module.namespace.namespace_name

  depends_on = [module.namespace]
}

module "istio" {
  source = "./modules/istio"

  count = var.enable_istio ? 1 : 0

  namespace     = module.namespace.namespace_name
  chart_version = var.istio_chart_version

  depends_on = [module.namespace, module.app]
}
