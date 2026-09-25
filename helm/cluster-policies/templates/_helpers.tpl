{{/* Match Pod CREATE/UPDATE in tenant namespaces only. */}}
{{- define "cluster-policies.tenantPods" -}}
namespaceSelector:
  matchExpressions:
    - key: {{ .Values.tenantLabel }}
      operator: Exists
resourceRules:
  - apiGroups: [""]
    apiVersions: ["v1"]
    operations: ["CREATE", "UPDATE"]
    resources: ["pods"]
{{- end -}}
