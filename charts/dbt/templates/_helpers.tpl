{{/*
Licensed to the Apache Software Foundation (ASF) under one or more
contributor license agreements. See the NOTICE file distributed with
this work for additional information regarding copyright ownership.
*/}}

{{/* Expand the name of the chart. */}}
{{- define "dbt.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/* Fully qualified app name. */}}
{{- define "dbt.fullname" -}}
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

{{- define "dbt.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "dbt.labels" -}}
helm.sh/chart: {{ include "dbt.chart" . }}
{{ include "dbt.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{- define "dbt.selectorLabels" -}}
app.kubernetes.io/name: {{ include "dbt.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{- define "dbt.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "dbt.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{/* Image reference: global registry wins unless the image sets its own. */}}
{{- define "dbt.image" -}}
{{- $registry := .Values.image.registry | default .Values.global.imageRegistry | default "" -}}
{{- $repo := .Values.image.repository -}}
{{- $tag := .Values.image.tag | default .Chart.AppVersion -}}
{{- if .Values.image.digest -}}
{{- if $registry }}{{ printf "%s/%s@%s" $registry $repo .Values.image.digest }}{{ else }}{{ printf "%s@%s" $repo .Values.image.digest }}{{ end }}
{{- else -}}
{{- if $registry }}{{ printf "%s/%s:%s" $registry $repo $tag }}{{ else }}{{ printf "%s:%s" $repo $tag }}{{ end }}
{{- end -}}
{{- end }}

{{- define "dbt.gitSync.image" -}}
{{- $registry := .Values.project.git.image.registry | default .Values.global.imageRegistry | default "" -}}
{{- if $registry }}{{ printf "%s/%s:%s" $registry .Values.project.git.image.repository .Values.project.git.image.tag }}{{ else }}{{ printf "%s:%s" .Values.project.git.image.repository .Values.project.git.image.tag }}{{ end }}
{{- end }}

{{- define "dbt.imagePullSecrets" -}}
{{- $secrets := concat (.Values.global.imagePullSecrets | default list) (.Values.imagePullSecrets | default list) -}}
{{- if $secrets }}
imagePullSecrets:
{{- range $secrets }}
  - name: {{ if kindIs "string" . }}{{ . }}{{ else }}{{ .name }}{{ end }}
{{- end }}
{{- end }}
{{- end }}

{{/* Name of the Secret holding profiles.yml: operator-provided or chart-managed. */}}
{{- define "dbt.profilesSecretName" -}}
{{- if .Values.profiles.existingSecret }}{{ .Values.profiles.existingSecret }}{{ else }}{{ printf "%s-profiles" (include "dbt.fullname" .) }}{{ end }}
{{- end }}

{{/* Where the dbt project root lives inside the pod (git-sync adds its own subdirectory). */}}
{{- define "dbt.projectDir" -}}
{{- $base := "/dbt/project" -}}
{{- if .Values.project.git.enabled -}}
{{- $link := printf "%s/%s" $base (.Values.project.git.linkName | default "current") -}}
{{- if .Values.project.git.subPath }}{{ printf "%s/%s" $link .Values.project.git.subPath }}{{ else }}{{ $link }}{{ end }}
{{- else -}}
{{- if .Values.project.subPath }}{{ printf "%s/%s" $base .Values.project.subPath }}{{ else }}{{ $base }}{{ end }}
{{- end -}}
{{- end }}

{{/*
Trust material is mounted only when the platform gave us all three pieces. Written as a test
rather than a required value so a partial injection degrades to "no CA mounted" instead of
failing the install — the same contract the other charts follow.
*/}}
{{- define "dbt.tlsTrustEnabled" -}}
{{- $tls := .Values.global.security.tls | default dict -}}
{{- $ts := $tls.truststore | default dict -}}
{{- if and $tls.enabled $ts.enabled $tls.truststoreSecret -}}true{{- end -}}
{{- end }}

{{- define "dbt.caBundlePath" -}}
{{- $tls := .Values.global.security.tls | default dict -}}
{{- $ts := $tls.truststore | default dict -}}
{{- printf "%s/%s" (default "/etc/security/truststore" $tls.mountPath) (default "ca.crt" $ts.pemKey) -}}
{{- end }}
