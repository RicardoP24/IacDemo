# ------------------------------------------------------------------ Argo CD
# GitOps delivery: Argo CD pulls the tenant workloads from Git and keeps the cluster
# identical to it (self-heal reverts manual changes). The repository is public, so
# Argo CD only reads it: no Git credentials are stored in the cluster.

resource "kubernetes_namespace_v1" "argocd" {
  metadata {
    name = "argocd"
    labels = {
      "pod-security.kubernetes.io/enforce" = "restricted"
      "pod-security.kubernetes.io/audit"   = "restricted"
      "pod-security.kubernetes.io/warn"    = "restricted"
    }
  }
}

resource "helm_release" "argocd" {
  name       = "argocd"
  namespace  = kubernetes_namespace_v1.argocd.metadata[0].name
  repository = "https://argoproj.github.io/argo-helm"
  chart      = "argo-cd"
  version    = var.chart_versions.argocd

  values = [file("${path.module}/argocd-values.yaml")]
}

# AppProject (what Argo CD may deploy, and where) + ApplicationSet (one Application
# per file in tenants/). Infrastructure values that come from Terraform are passed to
# every tenant here; the release (image digests) is committed to Git by the pipeline.
resource "helm_release" "gitops" {
  name      = "gitops"
  namespace = kubernetes_namespace_v1.argocd.metadata[0].name
  chart     = "${path.module}/../../helm/gitops"

  values = [yamlencode({
    repoURL        = var.gitops_repo_url
    targetRevision = var.gitops_revision
    tenants        = var.tenants
    platformValues = {
      imageRegistry = local.infra.ecr_registry
      ingress = {
        wafAclArn = local.infra.waf_acl_arn
      }
      networkPolicy = {
        albSourceCidrs = local.infra.public_subnet_cidrs
      }
    }
  })]

  # Namespaces, guardrails and admission policies are in place before Argo CD deploys anything.
  depends_on = [
    helm_release.argocd,
    helm_release.cluster_policies,
    helm_release.aws_load_balancer_controller,
    kubernetes_resource_quota_v1.tenant,
    kubernetes_limit_range_v1.tenant,
    kubernetes_network_policy_v1.default_deny,
    kubernetes_network_policy_v1.allow_dns,
    kubernetes_role_binding_v1.tenant_developer,
  ]
}
