# Istio is installed via its official Helm charts. The mesh-specific custom
# resources (PeerAuthentication, AuthorizationPolicy, Gateway, VirtualService,
# the local-rate-limit EnvoyFilter) are applied with `kubectl apply` via
# local-exec rather than the kubernetes_manifest resource: kubernetes_manifest
# resolves each CRD's schema at plan time, which fails on a first-ever apply
# because istiod's CRDs do not exist yet until the helm_release below has
# already run. Shelling out after the Helm releases succeed sidesteps that
# ordering problem entirely. State for these five objects is therefore
# reconciled by Kubernetes/kubectl idempotency, not tracked in the Terraform
# state file - an explicit, documented tradeoff (see ARCHITECTURE.md).

resource "helm_release" "istio_base" {
  name             = "istio-base"
  repository       = "https://istio-release.storage.googleapis.com/charts"
  chart            = "base"
  version          = var.chart_version
  namespace        = "istio-system"
  create_namespace = true
}

resource "helm_release" "istio_cni" {
  name       = "istio-cni"
  repository = "https://istio-release.storage.googleapis.com/charts"
  chart      = "cni"
  version    = var.chart_version
  namespace  = "kube-system"

  # The app namespace enforces the Restricted Pod Security Standard, which
  # forbids the NET_ADMIN/NET_RAW capabilities and root user that Istio's
  # classic istio-init container needs to set up iptables redirection. The
  # CNI plugin does that redirection from a node-level DaemonSet instead, so
  # injected pods need no privileged init container at all.
  depends_on = [helm_release.istio_base]
}

resource "helm_release" "istiod" {
  name       = "istiod"
  repository = "https://istio-release.storage.googleapis.com/charts"
  chart      = "istiod"
  version    = var.chart_version
  namespace  = "istio-system"

  # Tell istiod's sidecar-injection webhook to rely on the CNI plugin for
  # traffic redirection instead of generating an istio-init container per
  # pod, since istio-init cannot satisfy the Restricted Pod Security Standard.
  set {
    name  = "istio_cni.enabled"
    value = "true"
  }

  # Extends the workload mTLS certificate lifetime from Istio's 24h default
  # to a week, purely so this local demo cluster survives idle overnight/
  # multi-day gaps between sessions without every sidecar's cert quietly
  # expiring and breaking in-mesh calls (the actual cause of the 502s hit
  # here). DEFAULT_WORKLOAD_CERT_TTL as an istiod env var is known to not
  # take effect in this Istio release; SECRET_TTL in proxyMetadata is the
  # value the istio-agent actually honors when requesting a cert from the
  # CA. A shorter cert lifetime is a real defense-in-depth property (it
  # bounds how long a stolen certificate stays useful) - this relaxation is
  # deliberate for a disposable local cluster and is not a production
  # setting; a real deployment should keep this at or below the 24h default.
  set {
    name  = "meshConfig.defaultConfig.proxyMetadata.SECRET_TTL"
    value = "168h"
  }

  depends_on = [helm_release.istio_base, helm_release.istio_cni]
}

resource "helm_release" "istio_ingressgateway" {
  name       = "istio-ingressgateway"
  repository = "https://istio-release.storage.googleapis.com/charts"
  chart      = "gateway"
  version    = var.chart_version
  namespace  = "istio-system"

  # kind has no LoadBalancer controller, so the chart's default
  # service.type=LoadBalancer would never get an external IP and
  # `helm_release`'s wait-for-ready would block until it times out.
  set {
    name  = "service.type"
    value = "ClusterIP"
  }

  depends_on = [helm_release.istiod]
}

resource "null_resource" "istio_injection_rollout" {
  triggers = {
    namespace = var.namespace
  }

  provisioner "local-exec" {
    command = "kubectl --context ${var.kube_context} -n ${var.namespace} rollout restart deployment"
  }

  depends_on = [helm_release.istiod, helm_release.istio_cni]
}

locals {
  manifest_dir      = "${path.module}/../../manifests/istio"
  rendered_manifests = {
    for f in fileset(local.manifest_dir, "*.yaml") :
    f => templatefile("${local.manifest_dir}/${f}", { namespace = var.namespace })
  }
}

resource "local_file" "rendered_istio_manifests" {
  for_each = local.rendered_manifests

  filename = "${path.module}/.rendered/${each.key}"
  content  = each.value
}

resource "null_resource" "apply_istio_manifests" {
  triggers = {
    manifests_hash = sha256(join("", values(local.rendered_manifests)))
  }

  provisioner "local-exec" {
    command = "kubectl --context ${var.kube_context} apply -f \"${path.module}/.rendered\""
  }

  depends_on = [
    helm_release.istiod,
    helm_release.istio_ingressgateway,
    null_resource.istio_injection_rollout,
    local_file.rendered_istio_manifests,
  ]
}
