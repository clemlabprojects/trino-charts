{{/* vim: set filetype=mustache: */}}
{{/*
Expand the name of the chart.
*/}}
{{- define "trino.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
We truncate at 63 chars because some Kubernetes name fields are limited to this (by the DNS naming spec).
If release name contains chart name it will be used as a full name.
*/}}
{{- define "trino.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- if hasPrefix .Release.Name $name }}
{{- $name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}
{{- end }}

{{/*
Create chart name and version as used by the chart label.
*/}}
{{- define "trino.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "trino.coordinator" -}}
{{- if .Values.coordinatorNameOverride }}
{{- .Values.coordinatorNameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- if hasPrefix .Release.Name $name }}
{{- printf "%s-%s" $name "coordinator" | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s-%s" .Release.Name $name "coordinator" | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}
{{- end }}

{{- define "trino.worker" -}}
{{- if .Values.workerNameOverride }}
{{- .Values.workerNameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- if hasPrefix .Release.Name $name }}
{{- printf "%s-%s" $name "worker" | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s-%s" .Release.Name $name "worker" | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}
{{- end }}


{{- define "trino.catalog" -}}
{{ template "trino.fullname" . }}-catalog
{{- end -}}

{{/*
Common labels
*/}}
{{- define "trino.labels" -}}
helm.sh/chart: {{ include "trino.chart" . }}
{{ include "trino.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- if .Values.commonLabels }}
{{ tpl (toYaml .Values.commonLabels) . }}
{{- end }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "trino.selectorLabels" -}}
app.kubernetes.io/name: {{ include "trino.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Create the name of the service account to use
*/}}
{{- define "trino.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "trino.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{/*
Return the proper image name
{{ include "trino.image" . }}

Code is inspired from bitnami/common

*/}}
{{/*
Return the proper image name
{{ include "trino.image" (dict "root" . "image" .Values.image) }}
*/}}
{{- define "trino.image" -}}
{{- $globalReg := .root.Values.global.imageRegistry | default "" -}}
{{- $img       := .image -}}
{{- $reg       := $img.registry                      | default "" -}}
{{- $repo      := $img.repository                    | default "" -}}
{{- $tag       := $img.tag                           | default (default "" .root.Chart.AppVersion) -}}
{{- $digest    := $img.digest                        | default "" -}}
{{- $sole      := $img.useRepositoryAsSoleImageReference | default false -}}

{{- /* Logic 1: If useRepositoryAsSoleImageReference is true, just return repository */ -}}
{{- if $sole -}}
  {{- printf "%s" $repo -}}

{{- /* Logic 2: Normal construction */ -}}
{{- else -}}
  
  {{- /* Determine registry prefix: local > global > empty */ -}}
  {{- $prefix := (default $reg $globalReg) -}}
  
  {{- /* Build the base part (registry/repo) */ -}}
  {{- $base := $repo -}}
  {{- if ne $prefix "" -}}
    {{- $base = printf "%s/%s" $prefix $repo -}}
  {{- end -}}

  {{- /* Append tag or digest */ -}}
  {{- if $digest -}}
    {{- printf "%s@%s" $base $digest -}}
  {{- else -}}
    {{- printf "%s:%s" $base (default "latest" $tag) -}}
  {{- end -}}

{{- end -}}
{{- end -}}

{{/*
Create the secret name for the file-based authentication's password file
*/}}
{{- define "trino.passwordSecretName" -}}
{{- if and .Values.auth .Values.auth.passwordAuthSecret }}
{{- .Values.auth.passwordAuthSecret | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- if hasPrefix .Release.Name $name }}
{{- printf "%s-%s" $name "password-file" | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s-%s" .Release.Name $name "password-file" | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}
{{- end }}

{{/*
Create the secret name for the group-provider file
*/}}
{{- define "trino.groupsSecretName" -}}
{{- if and .Values.auth .Values.auth.groupsAuthSecret }}
{{- .Values.auth.groupsAuthSecret }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- if hasPrefix .Release.Name $name }}
{{- printf "%s-%s" $name "groups-file" | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s-%s" .Release.Name $name "groups-file" | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}
{{- end }}

{{/*
Returns "true" when Ranger integration should be enabled (based on accessControl.type).
*/}}
{{- define "trino.ranger.enabled" -}}
{{- if eq (default "" .Values.accessControl.type) "ranger" -}}true{{- else -}}false{{- end -}}
{{- end -}}

{{/* Render env list safely, and append Hadoop conf var when requested */}}
{{- define "trino.env" -}}
{{- $base := default (list) .Values.env -}}
{{- $addHadoop := and .Values.hadoopConf.enabled .Values.hadoopConf.setEnv -}}
{{- $addTls := and .Values.global.security.tls.enabled .Values.global.security.tls.truststore.enabled .Values.global.security.tls.truststoreSecret -}}
{{- if gt (len $base) 0 }}
{{ toYaml $base | nindent 0 }}
{{- end }}
{{- if $addHadoop }}
- name: HADOOP_CONF_DIR
  value: /etc/hadoop/conf
{{- end }}
{{- if $addTls }}
- name: {{ default "TRUSTSTORE_PATH" .Values.global.security.tls.env.pathEnv | quote }}
  value: {{ ternary "/etc/security/truststore/ca.crt" (default "/etc/security/truststore/truststore.jks" .Values.global.security.tls.mountPath) (eq (default "jks" .Values.global.security.tls.truststore.format | lower) "pem") | quote }}
{{- if ne (default "jks" .Values.global.security.tls.truststore.format | lower) "pem" }}
- name: {{ default "TRUSTSTORE_PASSWORD" .Values.global.security.tls.env.passwordEnv | quote }}
  valueFrom:
    secretKeyRef:
      name: {{ .Values.global.security.tls.truststoreSecret }}
      key: {{ default "truststore.password" .Values.global.security.tls.truststorePasswordKey }}
{{- end }}
{{- end }}
{{- end }}
{{/* Truststore helpers (mount) */}}
{{- define "trino.truststore.volumeMount" -}}
{{- if and .Values.global.security.tls.enabled .Values.global.security.tls.truststore.enabled .Values.global.security.tls.truststoreSecret }}
- name: truststore
  mountPath: {{ ternary "/etc/security/truststore/ca.crt" (default "/etc/security/truststore/truststore.jks" .Values.global.security.tls.mountPath) (eq (default "jks" .Values.global.security.tls.truststore.format | lower) "pem") | quote }}
  subPath: {{ ternary (default "ca.crt" .Values.global.security.tls.truststore.pemKey) (default "truststore.jks" .Values.global.security.tls.truststoreKey) (eq (default "jks" .Values.global.security.tls.truststore.format | lower) "pem") | quote }}
  readOnly: true
{{- end }}
{{- end }}

{{- define "trino.truststore.volume" -}}
{{- if and .Values.global.security.tls.enabled .Values.global.security.tls.truststore.enabled .Values.global.security.tls.truststoreSecret }}
- name: truststore
  secret:
    secretName: {{ .Values.global.security.tls.truststoreSecret }}
    items:
      - key: {{ ternary (default "ca.crt" .Values.global.security.tls.truststore.pemKey) (default "truststore.jks" .Values.global.security.tls.truststoreKey) (eq (default "jks" .Values.global.security.tls.truststore.format | lower) "pem") }}
        path: {{ ternary (default "ca.crt" .Values.global.security.tls.truststore.pemKey) (default "truststore.jks" .Values.global.security.tls.truststoreKey) (eq (default "jks" .Values.global.security.tls.truststore.format | lower) "pem") }}
{{- end }}
{{- end }}
