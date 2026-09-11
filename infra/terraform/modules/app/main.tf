locals {
  common_resources = {
    requests = { cpu = "50m", memory = "64Mi" }
    limits   = { cpu = "200m", memory = "128Mi" }
  }
}

# --- Service accounts (least-privilege identities, also used for Istio AuthorizationPolicy) ---

resource "kubernetes_service_account_v1" "backend" {
  metadata {
    name      = "backend"
    namespace = var.namespace
  }
  automount_service_account_token = false
}

resource "kubernetes_service_account_v1" "frontend" {
  metadata {
    name      = "frontend"
    namespace = var.namespace
  }
  automount_service_account_token = false
}

resource "kubernetes_service_account_v1" "mocks" {
  metadata {
    name      = "mocks"
    namespace = var.namespace
  }
  automount_service_account_token = false
}

# --- Backend service registry, pointing at in-cluster DNS names for the mocks ---

resource "kubernetes_config_map_v1" "backend_services" {
  metadata {
    name      = "backend-services-config"
    namespace = var.namespace
  }

  data = {
    "services.yaml" = yamlencode({
      services = [
        for name in keys(var.mock_services) : {
          name = name
          url  = "http://${name}:8000/health"
        }
      ]
    })
  }
}

# --- Mock downstream services (one image, reused per entry in var.mock_services) ---

resource "kubernetes_deployment_v1" "mock" {
  for_each = var.mock_services

  metadata {
    name      = each.key
    namespace = var.namespace
    labels    = { app = each.key }
  }

  spec {
    replicas = 1
    selector {
      match_labels = { app = each.key }
    }
    template {
      metadata {
        labels = { app = each.key }
      }
      spec {
        service_account_name = kubernetes_service_account_v1.mocks.metadata[0].name

        security_context {
          run_as_non_root = true
          run_as_user     = 10001
          run_as_group    = 10001
          seccomp_profile {
            type = "RuntimeDefault"
          }
        }

        container {
          name  = each.key
          image = var.mock_image
          image_pull_policy = var.image_pull_policy

          security_context {
            allow_privilege_escalation = false
            run_as_non_root            = true
            capabilities {
              drop = ["ALL"]
            }
          }

          env {
            name  = "MOCK_NAME"
            value = each.key
          }
          env {
            name  = "MOCK_MODE"
            value = each.value
          }

          port {
            container_port = 8000
          }

          resources {
            requests = local.common_resources.requests
            limits   = local.common_resources.limits
          }

          # TCP checks rather than HTTP GET /health: MOCK_MODE=slow makes /health
          # sleep past any reasonable probe timeout by design (it exercises the
          # backend's own HTTP client timeout), so pod liveness/readiness must not
          # depend on that endpoint's latency.
          #
          # timeout_seconds/failure_threshold are widened beyond the Kubernetes
          # defaults (1s / 3) on every probe in this module: on a resource-
          # constrained single-node local host, brief CPU scheduling delays under
          # the sidecar's own probe-forwarding hop were enough to trip the default
          # 1-second timeout and get a healthy container killed and restarted.
          # This still catches a genuinely hung process within ~30-60s.
          liveness_probe {
            tcp_socket {
              port = 8000
            }
            initial_delay_seconds = 3
            period_seconds        = 10
            timeout_seconds       = 5
            failure_threshold     = 6
          }
          readiness_probe {
            tcp_socket {
              port = 8000
            }
            initial_delay_seconds = 1
            period_seconds        = 5
            timeout_seconds       = 5
            failure_threshold     = 6
          }
        }
      }
    }
  }
}

resource "kubernetes_service_v1" "mock" {
  for_each = var.mock_services

  metadata {
    name      = each.key
    namespace = var.namespace
  }
  spec {
    selector = { app = each.key }
    port {
      port        = 8000
      target_port = 8000
    }
  }
}

# --- Backend ---

resource "kubernetes_deployment_v1" "backend" {
  metadata {
    name      = "backend"
    namespace = var.namespace
    labels    = { app = "backend" }
  }

  spec {
    # Tried 2 replicas so the DestinationRule's outlier detection would have
    # more than one instance to load-balance across and eject from. Reverted
    # to 1: on this host's single-node cluster, a second backend+sidecar pair
    # pushed CPU contention high enough that both replicas crash-looped on
    # liveness-probe failures (confirmed via stable memory throughout - this
    # was scheduling starvation, not OOM) while the original stayed healthy
    # for 32h+ under identical config. The DestinationRule itself is still
    # valid, real config either way; it simply has nothing to eject from
    # with a single replica.
    replicas = 1

    # Default RollingUpdate (25%/25%) surges a second pod before retiring the
    # first. On this single-node host that surge pod repeatedly failed its
    # first liveness checks under cold-start CPU contention, and because
    # maxUnavailable rounds down to 0 at replicas=1, the deployment couldn't
    # retire the (healthy) old pod until the (flaky) new one proved ready -
    # a real deadlock, observed directly. maxUnavailable=100%/maxSurge=0
    # makes every rollout a straight replace instead of a surge, so there is
    # only ever one pod/one hash to reason about.
    strategy {
      type = "RollingUpdate"
      rolling_update {
        max_unavailable = "100%"
        max_surge       = "0"
      }
    }

    selector {
      match_labels = { app = "backend" }
    }
    template {
      metadata {
        labels = { app = "backend" }
      }
      spec {
        service_account_name = kubernetes_service_account_v1.backend.metadata[0].name

        security_context {
          run_as_non_root = true
          run_as_user     = 10001
          run_as_group    = 10001
          seccomp_profile {
            type = "RuntimeDefault"
          }
        }

        container {
          name  = "backend"
          image = var.backend_image
          image_pull_policy = var.image_pull_policy

          security_context {
            allow_privilege_escalation = false
            run_as_non_root            = true
            capabilities {
              drop = ["ALL"]
            }
          }

          env {
            name  = "SERVICES_CONFIG_PATH"
            value = "/app/config/services.yaml"
          }
          env {
            name  = "CORS_ALLOW_ORIGINS"
            value = "http://localhost:8080"
          }

          port {
            container_port = 8000
          }

          volume_mount {
            name       = "services-config"
            mount_path = "/app/config/services.yaml"
            sub_path   = "services.yaml"
            read_only  = true
          }

          resources {
            requests = local.common_resources.requests
            limits   = local.common_resources.limits
          }

          liveness_probe {
            http_get {
              path = "/healthz"
              port = 8000
            }
            initial_delay_seconds = 3
            period_seconds        = 10
            timeout_seconds       = 5
            failure_threshold     = 6
          }
          readiness_probe {
            http_get {
              path = "/readyz"
              port = 8000
            }
            initial_delay_seconds = 1
            period_seconds        = 5
            timeout_seconds       = 5
            failure_threshold     = 6
          }
        }

        volume {
          name = "services-config"
          config_map {
            name = kubernetes_config_map_v1.backend_services.metadata[0].name
          }
        }
      }
    }
  }
}

resource "kubernetes_service_v1" "backend" {
  metadata {
    name      = "backend"
    namespace = var.namespace
  }
  spec {
    selector = { app = "backend" }
    port {
      port        = 8000
      target_port = 8000
    }
  }
}

# --- Frontend ---

resource "kubernetes_deployment_v1" "frontend" {
  metadata {
    name      = "frontend"
    namespace = var.namespace
    labels    = { app = "frontend" }
  }

  spec {
    replicas = 1
    selector {
      match_labels = { app = "frontend" }
    }
    template {
      metadata {
        labels = { app = "frontend" }
      }
      spec {
        service_account_name = kubernetes_service_account_v1.frontend.metadata[0].name

        security_context {
          run_as_non_root = true
          run_as_user     = 10001
          run_as_group    = 10001
          seccomp_profile {
            type = "RuntimeDefault"
          }
        }

        container {
          name  = "frontend"
          image = var.frontend_image
          image_pull_policy = var.image_pull_policy

          security_context {
            allow_privilege_escalation = false
            run_as_non_root            = true
            capabilities {
              drop = ["ALL"]
            }
          }

          port {
            container_port = 8080
          }

          resources {
            requests = local.common_resources.requests
            limits   = local.common_resources.limits
          }

          liveness_probe {
            http_get {
              path = "/"
              port = 8080
            }
            initial_delay_seconds = 3
            period_seconds        = 10
            timeout_seconds       = 5
            failure_threshold     = 6
          }
          readiness_probe {
            http_get {
              path = "/"
              port = 8080
            }
            initial_delay_seconds = 1
            period_seconds        = 5
            timeout_seconds       = 5
            failure_threshold     = 6
          }
        }
      }
    }
  }
}

resource "kubernetes_service_v1" "frontend" {
  metadata {
    name      = "frontend"
    namespace = var.namespace
  }
  spec {
    selector = { app = "frontend" }
    port {
      port        = 80
      target_port = 8080
      node_port   = 30080
    }
    type = "NodePort"
  }
}

# --- NetworkPolicies ---
# Declared as real IaC, but only truly enforced once Istio's sidecars and
# AuthorizationPolicy take over in the istio module - kind's default CNI
# (kindnet) does not enforce NetworkPolicy on its own. See ARCHITECTURE.md.

resource "kubernetes_network_policy_v1" "default_deny" {
  metadata {
    name      = "default-deny"
    namespace = var.namespace
  }
  spec {
    pod_selector {}
    policy_types = ["Ingress", "Egress"]
  }
}

resource "kubernetes_network_policy_v1" "allow_dns_egress" {
  metadata {
    name      = "allow-dns-egress"
    namespace = var.namespace
  }
  spec {
    pod_selector {}
    policy_types = ["Egress"]
    egress {
      to {
        namespace_selector {
          match_labels = { "kubernetes.io/metadata.name" = "kube-system" }
        }
      }
      ports {
        port     = 53
        protocol = "UDP"
      }
      ports {
        port     = 53
        protocol = "TCP"
      }
    }
  }
}

# Every pod carries an istio-proxy sidecar once injected, and the sidecar
# needs to reach istiod for its initial config sync and workload certificate
# (mTLS) - without this, default-deny leaves sidecars stuck NotReady forever.
resource "kubernetes_network_policy_v1" "allow_istiod_egress" {
  metadata {
    name      = "allow-istiod-egress"
    namespace = var.namespace
  }
  spec {
    pod_selector {}
    policy_types = ["Egress"]
    egress {
      to {
        namespace_selector {
          match_labels = { "kubernetes.io/metadata.name" = "istio-system" }
        }
      }
      ports {
        port     = 15012
        protocol = "TCP"
      }
      ports {
        port     = 15010
        protocol = "TCP"
      }
    }
  }
}


# The frontend is reached from outside the cluster via its NodePort (kind's
# host port mapping), so its ingress can't be scoped to a pod/namespace
# selector the way in-mesh traffic is - an ingress rule with no `from` allows
# any source on this port, while default-deny still blocks everything else.
resource "kubernetes_network_policy_v1" "allow_frontend_nodeport_ingress" {
  metadata {
    name      = "allow-frontend-nodeport-ingress"
    namespace = var.namespace
  }
  spec {
    pod_selector {
      match_labels = { app = "frontend" }
    }
    policy_types = ["Ingress"]
    ingress {
      ports {
        port = 8080
      }
    }
  }
}

resource "kubernetes_network_policy_v1" "frontend_to_backend" {
  metadata {
    name      = "frontend-to-backend"
    namespace = var.namespace
  }
  spec {
    pod_selector {
      match_labels = { app = "backend" }
    }
    policy_types = ["Ingress"]
    ingress {
      from {
        pod_selector {
          match_labels = { app = "frontend" }
        }
      }
      ports {
        port = 8000
      }
    }
  }
}

resource "kubernetes_network_policy_v1" "backend_to_mocks" {
  for_each = var.mock_services

  metadata {
    name      = "backend-to-${each.key}"
    namespace = var.namespace
  }
  spec {
    pod_selector {
      match_labels = { app = each.key }
    }
    policy_types = ["Ingress"]
    ingress {
      from {
        pod_selector {
          match_labels = { app = "backend" }
        }
      }
      ports {
        port = 8000
      }
    }
  }
}

resource "kubernetes_network_policy_v1" "allow_frontend_egress_to_backend" {
  metadata {
    name      = "allow-frontend-egress"
    namespace = var.namespace
  }
  spec {
    pod_selector {
      match_labels = { app = "frontend" }
    }
    policy_types = ["Egress"]
    egress {
      to {
        pod_selector {
          match_labels = { app = "backend" }
        }
      }
      ports {
        port = 8000
      }
    }
  }
}

resource "kubernetes_network_policy_v1" "allow_backend_egress_to_mocks" {
  metadata {
    name      = "allow-backend-egress"
    namespace = var.namespace
  }
  spec {
    pod_selector {
      match_labels = { app = "backend" }
    }
    policy_types = ["Egress"]
    dynamic "egress" {
      for_each = var.mock_services
      content {
        to {
          pod_selector {
            match_labels = { app = egress.key }
          }
        }
        ports {
          port = 8000
        }
      }
    }
  }
}
