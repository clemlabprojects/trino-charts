{{/* webhook.name: base name, optionally overridden */}}
{{- define "webhook.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/* webhook.fullname: final resource name, supports fullnameOverride */}}
{{- define "webhook.fullname" -}}
{{- if .Values.fullnameOverride -}}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else -}}
  {{- $name := include "webhook.name" . -}}
  {{- if contains .Release.Name $name -}}
    {{- .Release.Name | trunc 63 | trimSuffix "-" -}}
  {{- else -}}
    {{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" -}}
  {{- end -}}
{{- end -}}
{{- end -}}

{{- define "webhook.labels" -}}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version | replace "+" "_" }}
app.kubernetes.io/name: {{ include "webhook.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Chart.AppVersion }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end -}}

{{- define "webhook.image" -}}
{{- $globalReg := .Values.global.imageRegistry | default "" -}}
{{- $reg       := .Values.image.registry      | default "" -}}
{{- $repo      := .Values.image.repository    | default "" -}}
{{- $name      := .Values.image.name          | default "" -}}
{{- $tag       := .Values.image.tag           | default "latest" -}}
{{- $digest    := .Values.image.digest        | default "" -}}
{{- $sole      := .Values.image.useRepositoryAsSoleImageReference | default false -}}

{{- /* Compose base repo/name */ -}}
{{- $base := "" -}}
{{- if $repo -}}
  {{- if $name -}}
    {{- $base = printf "%s/%s" $repo $name -}}
  {{- else -}}
    {{- $base = $repo -}}
  {{- end -}}
{{- else -}}
  {{- $base = $name -}}
{{- end -}}

{{- /* If sole, do not prefix with any registry */ -}}
{{- if $sole -}}
  {{- if $digest -}}
    {{- printf "%s@%s" $base $digest -}}
  {{- else -}}
    {{- printf "%s:%s" $base $tag -}}
  {{- end -}}
{{- else -}}
  {{- $prefix := (default $reg $globalReg) -}}
  {{- $ref := (ternary (printf "%s/%s" $prefix $base) $base (ne $prefix "")) -}}
  {{- if $digest -}}
    {{- printf "%s@%s" $ref $digest -}}
  {{- else -}}
    {{- printf "%s:%s" $ref $tag -}}
  {{- end -}}
{{- end -}}
{{- end -}}

{{- define "webhook.serviceAccountName" -}}
{{ include "webhook.fullname" . }}
{{- end -}}
