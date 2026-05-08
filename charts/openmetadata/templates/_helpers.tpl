{{/*
Expand the name of the chart.
*/}}
{{- define "openmetadata.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
*/}}
{{- define "openmetadata.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- if contains $name .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}
{{- end }}

{{- define "openmetadata.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "openmetadata.labels" -}}
helm.sh/chart: {{ include "openmetadata.chart" . }}
{{ include "openmetadata.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: openmetadata
{{- end }}

{{- define "openmetadata.selectorLabels" -}}
app.kubernetes.io/name: {{ include "openmetadata.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{- define "openmetadata.ingestionLabels" -}}
helm.sh/chart: {{ include "openmetadata.chart" . }}
app.kubernetes.io/name: {{ include "openmetadata.name" . }}-ingestion
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/component: ingestion
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: openmetadata
{{- end }}

{{- define "openmetadata.ingestionSelectorLabels" -}}
app.kubernetes.io/name: {{ include "openmetadata.name" . }}-ingestion
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
ServiceAccount name
*/}}
{{- define "openmetadata.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "openmetadata.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{- define "openmetadata.ingestionServiceAccountName" -}}
{{- if .Values.ingestion.serviceAccount.create }}
{{- default (printf "%s-ingestion" (include "openmetadata.fullname" .)) .Values.ingestion.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.ingestion.serviceAccount.name }}
{{- end }}
{{- end }}

{{/*
Resolve image with registry override support.
Usage: {{ include "openmetadata.resolveImage" (dict "root" . "image" .Values.image) }}
*/}}
{{- define "openmetadata.resolveImage" -}}
{{- $root := .root }}
{{- $img  := .image }}
{{- $registry := $root.Values.global.imageRegistry }}
{{- if $img.registry }}
  {{- $src := $img.registry }}
  {{- if $root.Values.global.registryOverrides }}
    {{- $override := index $root.Values.global.registryOverrides $src }}
    {{- if $override }}
      {{- $registry = $override }}
    {{- else }}
      {{- $registry = $src }}
    {{- end }}
  {{- else }}
    {{- $registry = $src }}
  {{- end }}
{{- end }}
{{- printf "%s/%s:%s" $registry $img.repository $img.tag }}
{{- end }}

{{/*
Map global.security.auth.mode to the OpenMetadata AUTHENTICATION_PROVIDER env value.
Accepts "oidc", "ldap", "none", or "no-auth" (the form select uses "no-auth").
*/}}
{{- define "openmetadata.authProvider" -}}
{{- $mode := .Values.global.security.auth.mode | default "no-auth" -}}
{{- if eq $mode "oidc" -}}custom-oidc
{{- else if eq $mode "ldap" -}}ldap
{{- else -}}no-auth
{{- end }}
{{- end }}

{{/*
Resolve database host — either the postgresql subchart service or the external DB host.
*/}}
{{- define "openmetadata.dbHost" -}}
{{- if .Values.postgresql.enabled -}}
{{- printf "%s-postgresql" .Release.Name -}}
{{- else -}}
{{- required "externalDatabase.host is required when postgresql.enabled=false" .Values.externalDatabase.host -}}
{{- end }}
{{- end }}

{{/*
Resolve OpenSearch host.
The official opensearch-project chart names the service <clusterName>-<nodeGroup>.
*/}}
{{- define "openmetadata.opensearchHost" -}}
{{- if .Values.opensearch.enabled -}}
{{- $cluster := .Values.opensearch.clusterName | default "opensearch-cluster" -}}
{{- $group   := .Values.opensearch.nodeGroup   | default "master" -}}
{{- printf "%s-%s" $cluster $group -}}
{{- else -}}
{{- required "externalSearch.host is required when opensearch.enabled=false" .Values.externalSearch.host -}}
{{- end }}
{{- end }}

{{/*
Normalise imagePullSecrets: accepts both string entries and {name:...} objects,
as KDPS injects them as plain strings while Kubernetes requires {name:...} objects.
*/}}
{{- define "openmetadata.imagePullSecrets" -}}
{{- $list := list -}}
{{- range (default (list) .Values.global.imagePullSecrets) }}
  {{- if kindIs "string" . -}}
    {{- $list = append $list (dict "name" .) -}}
  {{- else -}}
    {{- $list = append $list . -}}
  {{- end -}}
{{- end -}}
{{- if gt (len $list) 0 -}}
{{- toYaml $list -}}
{{- end -}}
{{- end }}

{{/*
Name of the credentials Secret.
*/}}
{{- define "openmetadata.credentialsSecretName" -}}
{{- printf "%s-credentials" (include "openmetadata.fullname" .) }}
{{- end }}

{{/*
Name of the non-sensitive config ConfigMap.
*/}}
{{- define "openmetadata.configMapName" -}}
{{- printf "%s-config" (include "openmetadata.fullname" .) }}
{{- end }}

{{/*
OIDC public key URL — derived from issuerUrl (Keycloak convention).
Can be overridden by setting global.security.auth.oidc.jwksUri.
*/}}
{{- define "openmetadata.oidcPublicKeyUrl" -}}
{{- $oidc := .Values.global.security.auth.oidc }}
{{- if $oidc.jwksUri }}
{{- $oidc.jwksUri }}
{{- else if $oidc.issuerUrl }}
{{- printf "%s/protocol/openid-connect/certs" $oidc.issuerUrl }}
{{- end }}
{{- end }}
