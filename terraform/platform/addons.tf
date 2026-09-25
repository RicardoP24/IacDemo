# ------------------------------------------------ AWS Load Balancer Controller
# Turns each tenant Ingress into rules on one shared ALB (IngressGroup) and
# attaches the WAF web ACL to it. IAM through EKS Pod Identity (no static keys).

module "lbc_pod_identity" {
  source  = "terraform-aws-modules/eks-pod-identity/aws"
  version = "~> 2.9"

  name                            = "${local.cluster_name}-aws-lbc"
  attach_aws_lb_controller_policy = true

  associations = {
    this = {
      cluster_name    = local.cluster_name
      namespace       = "kube-system"
      service_account = "aws-load-balancer-controller"
    }
  }
}

resource "helm_release" "aws_load_balancer_controller" {
  name       = "aws-load-balancer-controller"
  namespace  = "kube-system"
  repository = "https://aws.github.io/eks-charts"
  chart      = "aws-load-balancer-controller"
  version    = var.chart_versions.aws_load_balancer_controller

  values = [yamlencode({
    clusterName = local.cluster_name
    region      = var.region
    vpcId       = local.infra.vpc_id
    serviceAccount = {
      name = "aws-load-balancer-controller"
    }
    enableWafv2  = true
    enableWaf    = false
    enableShield = false
  })]

  depends_on = [module.lbc_pod_identity]
}

# ------------------------------------------------------------- metrics-server
# Required by the tenant HorizontalPodAutoscalers.

resource "helm_release" "metrics_server" {
  name       = "metrics-server"
  namespace  = "kube-system"
  repository = "https://kubernetes-sigs.github.io/metrics-server"
  chart      = "metrics-server"
  version    = var.chart_versions.metrics_server
}

# --------------------------------------------------------------------- Kyverno
# Admission control (prevention): only signed images from our ECR, pinned by digest.

module "kyverno_pod_identity" {
  source  = "terraform-aws-modules/eks-pod-identity/aws"
  version = "~> 2.9"

  name = "${local.cluster_name}-kyverno"

  # Read-only ECR access to fetch cosign signatures during verification.
  additional_policy_arns = {
    ecr_read = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
  }

  associations = {
    this = {
      cluster_name    = local.cluster_name
      namespace       = "kyverno"
      service_account = "kyverno-admission-controller"
    }
  }
}

resource "helm_release" "kyverno" {
  name             = "kyverno"
  namespace        = "kyverno"
  create_namespace = true
  repository       = "https://kyverno.github.io/kyverno"
  chart            = "kyverno"
  version          = var.chart_versions.kyverno

  # Demo sizing: one replica per controller (production: 3 for the admission controller).
  values = [yamlencode({
    admissionController = {
      replicas = 1
      rbac = {
        serviceAccount = {
          name = "kyverno-admission-controller"
        }
      }
    }
    backgroundController = { replicas = 1 }
    cleanupController    = { replicas = 1 }
    reportsController    = { replicas = 1 }
  })]

  depends_on = [module.kyverno_pod_identity]
}

resource "helm_release" "cluster_policies" {
  name      = "cluster-policies"
  namespace = "kyverno"
  chart     = "${path.module}/../../helm/cluster-policies"

  values = [yamlencode({
    trustedRegistry = local.infra.ecr_registry
    cosignPublicKey = var.cosign_public_key
  })]

  depends_on = [helm_release.kyverno]
}

# ------------------------------------------------------- Falco + Falco Talon
# Falco: runtime intrusion detection (eBPF syscalls).
# Falco Talon: automated response, which turns detection into prevention.

locals {
  falco_rules = <<-EOT
    - rule: Shell in tenant container
      desc: An interactive shell was started inside a tenant workload.
      condition: >
        spawned_process and container and shell_procs and proc.tty != 0
        and k8s.ns.name in (${join(", ", var.tenants)})
      output: >
        Shell in tenant container (tenant=%k8s.ns.name pod=%k8s.pod.name
        container=%container.name image=%container.image.repository
        cmdline=%proc.cmdline user=%user.name)
      priority: WARNING
      tags: [iacdemo, tenant, mitre_execution]
  EOT

  talon_rules = <<-EOT
    - action: Isolate pod
      actionner: kubernetes:networkpolicy
    - action: Label pod as quarantined
      actionner: kubernetes:label
      parameters:
        labels:
          iacdemo.io/quarantine: "true"
    - rule: Quarantine tenant pod with interactive shell
      match:
        rules:
          - Shell in tenant container
      actions:
        - action: Isolate pod
        - action: Label pod as quarantined
  EOT
}

resource "helm_release" "falco" {
  name             = "falco"
  namespace        = "falco"
  create_namespace = true
  repository       = "https://falcosecurity.github.io/charts"
  chart            = "falco"
  version          = var.chart_versions.falco

  values = [yamlencode({
    driver = {
      kind = "modern_ebpf"
    }
    tty = true
    customRules = {
      "iacdemo-rules.yaml" = local.falco_rules
    }
    falco = {
      json_output = true
      http_output = {
        enabled = var.falco_response_actions
        url     = "http://falco-talon:2803"
      }
    }
    responseActions = {
      enabled = var.falco_response_actions
    }
    falco-talon = {
      replicaCount = 1
      config = {
        rulesOverride = local.talon_rules
      }
    }
  })]
}
