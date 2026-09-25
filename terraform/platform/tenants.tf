# One namespace per client, with guardrails applied *before* any workload lands:
#   Pod Security "restricted", ResourceQuota, LimitRange, default-deny network,
#   and a namespaced RBAC role for the client's developers.

resource "kubernetes_namespace_v1" "tenant" {
  for_each = toset(var.tenants)

  metadata {
    name = each.key
    labels = {
      "iacdemo.io/tenant"                          = each.key
      "pod-security.kubernetes.io/enforce"         = "restricted"
      "pod-security.kubernetes.io/enforce-version" = "latest"
      "pod-security.kubernetes.io/audit"           = "restricted"
      "pod-security.kubernetes.io/warn"            = "restricted"
    }
  }
}

resource "kubernetes_resource_quota_v1" "tenant" {
  for_each = kubernetes_namespace_v1.tenant

  metadata {
    name      = "tenant-quota"
    namespace = each.key
  }

  spec {
    hard = {
      "requests.cpu"           = var.tenant_quota.requests_cpu
      "requests.memory"        = var.tenant_quota.requests_memory
      "limits.cpu"             = var.tenant_quota.limits_cpu
      "limits.memory"          = var.tenant_quota.limits_memory
      "pods"                   = var.tenant_quota.pods
      "services.loadbalancers" = 0 # tenants share the ALB; no dedicated load balancers
      "services.nodeports"     = 0
    }
  }
}

resource "kubernetes_limit_range_v1" "tenant" {
  for_each = kubernetes_namespace_v1.tenant

  metadata {
    name      = "tenant-defaults"
    namespace = each.key
  }

  spec {
    limit {
      type = "Container"
      default = {
        cpu    = "200m"
        memory = "128Mi"
      }
      default_request = {
        cpu    = "50m"
        memory = "64Mi"
      }
      max = {
        cpu    = "1"
        memory = "512Mi"
      }
    }
  }
}

# Zero-trust baseline: nothing in, nothing out. Workloads open only what they need.
resource "kubernetes_network_policy_v1" "default_deny" {
  for_each = kubernetes_namespace_v1.tenant

  metadata {
    name      = "default-deny-all"
    namespace = each.key
  }

  spec {
    pod_selector {}
    policy_types = ["Ingress", "Egress"]
  }
}

resource "kubernetes_network_policy_v1" "allow_dns" {
  for_each = kubernetes_namespace_v1.tenant

  metadata {
    name      = "allow-dns-egress"
    namespace = each.key
  }

  spec {
    pod_selector {}
    policy_types = ["Egress"]

    egress {
      to {
        namespace_selector {
          match_labels = {
            "kubernetes.io/metadata.name" = "kube-system"
          }
        }
        pod_selector {
          match_labels = {
            "k8s-app" = "kube-dns"
          }
        }
      }

      ports {
        protocol = "UDP"
        port     = "53"
      }

      ports {
        protocol = "TCP"
        port     = "53"
      }
    }
  }
}

# Read-only access for each client's developers, limited to their own namespace.
# Map an IAM role to the group "iacdemo:<tenant>:developers" with an EKS access entry.
resource "kubernetes_role_v1" "tenant_developer" {
  for_each = kubernetes_namespace_v1.tenant

  metadata {
    name      = "tenant-developer"
    namespace = each.key
  }

  rule {
    api_groups = ["", "apps", "autoscaling", "networking.k8s.io"]
    resources  = ["pods", "pods/log", "services", "deployments", "replicasets", "horizontalpodautoscalers", "ingresses", "events"]
    verbs      = ["get", "list", "watch"]
  }
}

resource "kubernetes_role_binding_v1" "tenant_developer" {
  for_each = kubernetes_namespace_v1.tenant

  metadata {
    name      = "tenant-developer"
    namespace = each.key
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "Role"
    name      = kubernetes_role_v1.tenant_developer[each.key].metadata[0].name
  }

  subject {
    kind      = "Group"
    name      = "iacdemo:${each.key}:developers"
    api_group = "rbac.authorization.k8s.io"
  }
}
