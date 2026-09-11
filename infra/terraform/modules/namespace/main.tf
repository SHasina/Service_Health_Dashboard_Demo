resource "kubernetes_namespace" "this" {
  metadata {
    name = var.namespace

    labels = merge(
      {
        "pod-security.kubernetes.io/enforce" = "restricted"
        "pod-security.kubernetes.io/warn"    = "restricted"
        "pod-security.kubernetes.io/audit"   = "restricted"
      },
      var.enable_istio_inject ? { "istio-injection" = "enabled" } : {}
    )
  }
}
