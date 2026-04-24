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

{{- define "trino.catalog.coordinator" -}}
{{ template "trino.fullname" . }}-catalog-coordinator
{{- end -}}

{{- define "trino.catalog.worker" -}}
{{ template "trino.fullname" . }}-catalog-worker
{{- end -}}

{{/* Security profile wiring: map global.security.auth.* to Trino config/environment */}}
{{- define "trino.security.env" -}}
{{- $auth := .Values.global.security.auth | default dict -}}
{{- if $auth.mode }}
- name: TRINO_SECURITY_MODE
  value: {{ $auth.mode | quote }}
{{- if eq $auth.mode "ldap" }}
- name: TRINO_LDAP_URL
  value: {{ $auth.ldap.url | quote }}
- name: TRINO_LDAP_USER_BIND
  value: {{ $auth.ldap.bindDn | quote }}
- name: TRINO_LDAP_PASSWORD
  value: {{ $auth.ldap.bindPassword | quote }}
- name: TRINO_LDAP_USER_DN_TEMPLATE
  value: {{ $auth.ldap.userDnTemplate | quote }}
- name: TRINO_LDAP_BASE_DN
  value: {{ $auth.ldap.baseDn | quote }}
- name: TRINO_LDAP_GROUP_SEARCH_BASE
  value: {{ $auth.ldap.groupSearchBase | quote }}
- name: TRINO_LDAP_GROUP_SEARCH_FILTER
  value: {{ $auth.ldap.groupSearchFilter | quote }}
{{- end }}
{{- if eq $auth.mode "ad" }}
- name: TRINO_AD_URL
  value: {{ $auth.ad.url | quote }}
- name: TRINO_AD_BASE_DN
  value: {{ $auth.ad.baseDn | quote }}
- name: TRINO_AD_BIND_DN
  value: {{ $auth.ad.bindDn | quote }}
- name: TRINO_AD_BIND_PASSWORD
  value: {{ $auth.ad.bindPassword | quote }}
- name: TRINO_AD_USER_SEARCH_FILTER
  value: {{ $auth.ad.userSearchFilter | quote }}
- name: TRINO_AD_DOMAIN
  value: {{ $auth.ad.domain | quote }}
{{- end }}
{{- if eq $auth.mode "oidc" }}
{{- $oidc := $auth.oidc | default dict }}
{{- $secretRef := $oidc.secretRef | default dict }}
- name: TRINO_OIDC_ISSUER
  value: {{ $oidc.issuerUrl | quote }}
{{- if $secretRef.name }}
- name: OIDC_CLIENT_ID
  valueFrom:
    secretKeyRef:
      name: {{ $secretRef.name | quote }}
      key: {{ default "client_id" $secretRef.clientIdKey | quote }}
- name: OIDC_CLIENT_SECRET
  valueFrom:
    secretKeyRef:
      name: {{ $secretRef.name | quote }}
      key: {{ default "client_secret" $secretRef.clientSecretKey | quote }}
{{- else }}
- name: OIDC_CLIENT_ID
  value: {{ $oidc.clientId | quote }}
- name: OIDC_CLIENT_SECRET
  value: {{ $oidc.clientSecret | quote }}
{{- end }}
- name: TRINO_OIDC_SCOPES
  value: {{ default "openid email profile" $oidc.scopes | quote }}
{{- if $oidc.redirectUri }}
- name: TRINO_OIDC_REDIRECT_URI
  value: {{ $oidc.redirectUri | quote }}
{{- end }}
- name: TRINO_OIDC_USER_CLAIM
  value: {{ default "preferred_username" $oidc.userClaim | quote }}
{{- if $oidc.groupsClaim }}
- name: TRINO_OIDC_GROUPS_CLAIM
  value: {{ $oidc.groupsClaim | quote }}
{{- end }}
- name: TRINO_OIDC_SKIP_TLS_VERIFY
  value: {{ $oidc.skipTlsVerify | default false | quote }}
{{- end }}
{{- end }}
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
Return busybox image honoring global registry defaults.
*/}}
{{- define "trino.busybox.image" -}}
{{- $img := dict "registry" (default "" .root.Values.busyboxImage.registry)
                 "repository" (default "busybox" .root.Values.busyboxImage.repository)
                 "tag" (default "1.36" .root.Values.busyboxImage.tag)
                 "digest" (default "" .root.Values.busyboxImage.digest)
                 "useRepositoryAsSoleImageReference" (default false .root.Values.busyboxImage.useRepositoryAsSoleImageReference) -}}
{{- include "trino.image" (dict "root" .root "image" $img) -}}
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
{{- $tlsEnv := default (dict "pathEnv" "TRUSTSTORE_PATH" "passwordEnv" "TRUSTSTORE_PASSWORD") .Values.global.security.tls.env -}}
{{- if gt (len $base) 0 }}
{{ toYaml $base | nindent 0 }}
{{- end }}
{{- if $addHadoop }}
- name: HADOOP_CONF_DIR
  value: /etc/hadoop/conf
{{- end }}
{{- if $addTls }}
- name: {{ default "TRUSTSTORE_PATH" $tlsEnv.pathEnv | quote }}
  value: {{ ternary "/etc/security/truststore/ca.crt" (default "/etc/security/truststore/truststore.jks" .Values.global.security.tls.mountPath) (eq (default "jks" .Values.global.security.tls.truststore.format | lower) "pem") | quote }}
{{- if ne (default "jks" .Values.global.security.tls.truststore.format | lower) "pem" }}
- name: {{ default "TRUSTSTORE_PASSWORD" $tlsEnv.passwordEnv | quote }}
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

{{/* Vault CSI helpers */}}
{{- define "trino.vault.secretProviderClassName" -}}
{{- if and .Values.vault .Values.vault.csi .Values.vault.csi.secretProviderClassName }}
{{- .Values.vault.csi.secretProviderClassName -}}
{{- else -}}
{{- printf "%s-vault" (include "trino.fullname" .) -}}
{{- end -}}
{{- end }}

{{- define "trino.vault.volumeMount" -}}
{{- if and .Values.global.vault.enabled .Values.vault.csi.enabled }}
- name: vault-secrets
  mountPath: {{ default "/vault/secrets" .Values.vault.csi.mountPath | quote }}
  readOnly: {{ default true .Values.vault.csi.readOnly }}
{{- end }}
{{- end }}

{{- define "trino.vault.volume" -}}
{{- if and .Values.global.vault.enabled .Values.vault.csi.enabled }}
- name: vault-secrets
  csi:
    driver: secrets-store.csi.k8s.io
    readOnly: {{ default true .Values.vault.csi.readOnly }}
    volumeAttributes:
      secretProviderClass: {{ include "trino.vault.secretProviderClassName" . | quote }}
{{- end }}
{{- end }}
