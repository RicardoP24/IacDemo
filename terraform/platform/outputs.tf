output "tenant_namespaces" {
  value = [for ns in kubernetes_namespace_v1.tenant : ns.metadata[0].name]
}
