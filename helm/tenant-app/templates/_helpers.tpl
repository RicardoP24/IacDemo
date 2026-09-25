{{- define "tenant-app.tenant" -}}
{{- required "tenant is required" .Values.tenant -}}
{{- end -}}

{{- define "tenant-app.labels" -}}
app.kubernetes.io/part-of: iacdemo
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version }}
iacdemo.io/tenant: {{ include "tenant-app.tenant" . }}
{{- end -}}

{{/* Image reference pinned by digest: <registry>/<repository>@sha256:... */}}
{{- define "tenant-app.image" -}}
{{- $registry := required "imageRegistry is required" .root.Values.imageRegistry -}}
{{- $digest := required (printf "%s.image.digest is required" .component) .image.digest -}}
{{- printf "%s/%s@%s" $registry .image.repository $digest -}}
{{- end -}}

{{/* Hardened container settings shared by every container (Pod Security "restricted"). */}}
{{- define "tenant-app.containerSecurityContext" -}}
allowPrivilegeEscalation: false
readOnlyRootFilesystem: true
runAsNonRoot: true
capabilities:
  drop: ["ALL"]
seccompProfile:
  type: RuntimeDefault
{{- end -}}
