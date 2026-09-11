output "ingressgateway_release" {
  value = helm_release.istio_ingressgateway.name
}
