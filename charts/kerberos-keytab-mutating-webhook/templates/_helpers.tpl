{{- define "webhook.name" -}}
{{- default .Chart.Name .Values.appName | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "webhook.fullname" -}}
{{- printf "%s-%s" .Release.Name (include "webhook.name" .) | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "webhook.labels" -}}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version | replace "+" "_" }}
app.kubernetes.io/name: {{ include "webhook.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Chart.AppVersion }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end -}}

{{- define "webhook.image" -}}
{{- $r := .Values.image.registry   | default "" -}}
{{- $repo := .Values.image.repository | default "" -}}
{{- $name := .Values.image.name    | default "" -}}
{{- $tag := .Values.image.tag      | default "latest" -}}
{{- if $r }}{{ $r }}/{{ end -}}
{{- if $repo }}{{ $repo }}{{- if $name }}/{{ end -}}{{ end -}}
{{- if $name }}{{ $name }}{{ end -}}:{{ $tag }}
{{- end -}}

{{- define "webhook.serviceAccountName" -}}
{{ include "webhook.fullname" . }}
{{- end -}}
