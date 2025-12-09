{{/*

 Licensed to the Apache Software Foundation (ASF) under one or more
 contributor license agreements.  See the NOTICE file distributed with
 this work for additional information regarding copyright ownership.
 The ASF licenses this file to You under the Apache License, Version 2.0
 (the "License"); you may not use this file except in compliance with
 the License.  You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

 Unless required by applicable law or agreed to in writing, software
 distributed under the License is distributed on an "AS IS" BASIS,
 WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 See the License for the specific language governing permissions and
 limitations under the License.

*/}}

{{/* vim: set filetype=mustache: */}}
{{/*
Expand the name of the chart.
*/}}
{{- define "superset.name" -}}
  {{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
Create a default fully qualified app name.
We truncate at 63 chars because some Kubernetes name fields are limited to this (by the DNS naming spec).
If release name contains chart name it will be used as a full name.
*/}}
{{- define "superset.fullname" -}}
  {{- if .Values.fullnameOverride -}}
    {{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" -}}
  {{- else -}}
    {{- $name := default .Chart.Name .Values.nameOverride -}}
    {{- if contains $name .Release.Name -}}
      {{- .Release.Name | trunc 63 | trimSuffix "-" -}}
    {{- else -}}
      {{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" -}}
    {{- end -}}
  {{- end -}}
{{- end -}}

{{/*
Create the name of the service account to use
*/}}
{{- define "superset.serviceAccountName" -}}
  {{- if .Values.serviceAccount.create -}}
    {{- default (include "superset.fullname" .) .Values.serviceAccountName -}}
  {{- else -}}
    {{- default "default" .Values.serviceAccountName -}}
  {{- end -}}
{{- end -}}

{{/*
Create chart name and version as used by the chart label.
*/}}
{{- define "superset.chart" -}}
  {{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" -}}
{{- end -}}


{{- define "superset-config" }}
import os
from flask_caching.backends.rediscache import RedisCache

def env(key, default=None):
    return os.getenv(key, default)

# Redis Base URL
{{- if .Values.supersetNode.connections.redis_password }}
REDIS_BASE_URL=f"{env('REDIS_PROTO')}://{env('REDIS_USER', '')}:{env('REDIS_PASSWORD')}@{env('REDIS_HOST')}:{env('REDIS_PORT')}"
{{- else }}
REDIS_BASE_URL=f"{env('REDIS_PROTO')}://{env('REDIS_HOST')}:{env('REDIS_PORT')}"
{{- end }}

# Redis URL Params
{{- if .Values.supersetNode.connections.redis_ssl.enabled }}
REDIS_URL_PARAMS = f"?ssl_cert_reqs={env('REDIS_SSL_CERT_REQS')}"
{{- else }}
REDIS_URL_PARAMS = ""
{{- end}}

# Build Redis URLs
CACHE_REDIS_URL = f"{REDIS_BASE_URL}/{env('REDIS_DB', 1)}{REDIS_URL_PARAMS}"
CELERY_REDIS_URL = f"{REDIS_BASE_URL}/{env('REDIS_CELERY_DB', 0)}{REDIS_URL_PARAMS}"

MAPBOX_API_KEY = env('MAPBOX_API_KEY', '')
CACHE_CONFIG = {
      'CACHE_TYPE': 'RedisCache',
      'CACHE_DEFAULT_TIMEOUT': 300,
      'CACHE_KEY_PREFIX': 'superset_',
      'CACHE_REDIS_URL': CACHE_REDIS_URL,
}
DATA_CACHE_CONFIG = CACHE_CONFIG

SQLALCHEMY_DATABASE_URI = f"postgresql+psycopg2://{env('DB_USER')}:{env('DB_PASS')}@{env('DB_HOST')}:{env('DB_PORT')}/{env('DB_NAME')}"
SQLALCHEMY_TRACK_MODIFICATIONS = True

class CeleryConfig:
  imports  = ("superset.sql_lab", )
  broker_url = CELERY_REDIS_URL
  result_backend = CELERY_REDIS_URL

CELERY_CONFIG = CeleryConfig
RESULTS_BACKEND = RedisCache(
      host=env('REDIS_HOST'),
      {{- if .Values.supersetNode.connections.redis_password }}
      password=env('REDIS_PASSWORD'),
      {{- end }}
      port=env('REDIS_PORT'),
      key_prefix='superset_results',
      {{- if .Values.supersetNode.connections.redis_ssl.enabled }}
      ssl=True,
      ssl_cert_reqs=env('REDIS_SSL_CERT_REQS'),
      {{- end }}
)

{{ if .Values.configOverrides }}
# Overrides
{{- range $key, $value := .Values.configOverrides }}
# {{ $key }}
{{ tpl $value $ }}
{{- end }}
{{- end }}

{{ if .Values.configOverridesFiles }}
# Overrides from files
{{- $files := .Files }}
{{- range $key, $value := .Values.configOverridesFiles }}
# {{ $key }}
{{ $files.Get $value }}
{{- end }}
{{- end }}

{{- end }}

{{- define "supersetCeleryBeat.selectorLabels" -}}
app: {{ include "superset.name" . }}-celerybeat
release: {{ .Release.Name }}
{{- end }}

{{- define "supersetCeleryFlower.selectorLabels" -}}
app: {{ include "superset.name" . }}-flower
release: {{ .Release.Name }}
{{- end }}

{{- define "supersetNode.selectorLabels" -}}
app: {{ include "superset.name" . }}
release: {{ .Release.Name }}
{{- end }}

{{- define "supersetWebsockets.selectorLabels" -}}
app: {{ include "superset.name" . }}-ws
release: {{ .Release.Name }}
{{- end }}

{{- define "supersetWorker.selectorLabels" -}}
app: {{ include "superset.name" . }}-worker
release: {{ .Release.Name }}
{{- end }}

{{/* Common truststore snippets for TLS-enabled workloads */}}
{{- define "superset.truststore.env" -}}
{{- if and .Values.global.security.tls.enabled .Values.global.security.tls.truststore.enabled .Values.global.security.tls.truststoreSecret }}
{{- $tls := .Values.global.security.tls | default dict -}}
{{- $env := $tls.env | default dict -}}
{{- $pathEnv := default "TRUSTSTORE_PATH" $env.pathEnv -}}
{{- $mountPath := default "/etc/security/truststore/ca.crt" $tls.mountPath -}}
- name: {{ $pathEnv | quote }}
  value: {{ $mountPath | quote }}
{{- end }}
{{- end }}

{{- define "superset.truststore.volumeMount" -}}
- name: truststore
  mountPath: {{ default "/etc/security/truststore/ca.crt" .Values.global.security.tls.mountPath | quote }}
  subPath: {{ default "ca.crt" .Values.global.security.tls.truststore.pemKey | quote }}
  readOnly: true
{{- end }}

{{- define "superset.truststore.volume" -}}
{{- if and .Values.global.security.tls.enabled .Values.global.security.tls.truststore.enabled .Values.global.security.tls.truststoreSecret }}
- name: truststore
  secret:
    secretName: {{ .Values.global.security.tls.truststoreSecret }}
    items:
      - key: {{ default "ca.crt" .Values.global.security.tls.truststore.pemKey }}
        path: {{ default "ca.crt" .Values.global.security.tls.truststore.pemKey }}
{{- end }}
{{- end }}

{{/* Kerberos helpers to avoid nil-pointer issues and keep defaults applied */}}
{{- define "superset.kerberos.state" -}}
{{- $kerb := .Values.global.security.kerberos | default dict -}}
{{- $kinit := $kerb.kinitSidecar | default dict -}}
{{- $cacheDir := default "/var/run/krb5" $kinit.cacheDir -}}
{{- $cacheFile := default "/var/run/krb5/krb5cc_superset" $kinit.cacheFile -}}
{{- dict "kerb" $kerb "kinit" $kinit "cacheDir" $cacheDir "cacheFile" $cacheFile -}}
{{- end }}

{{- define "superset.kerberos.env" -}}
{{- $st := include "superset.kerberos.state" . | fromYaml -}}
{{- $kerb := $st.kerb -}}
{{- $kinit := $st.kinit -}}
{{- $cacheFile := $st.cacheFile -}}
{{- if and $kerb.enabled $kinit.enabled $cacheFile }}
- name: KRB5CCNAME
  value: {{ $cacheFile | quote }}
{{- end }}
{{- end }}

{{- define "superset.kerberos.volumeMounts" -}}
{{- $st := include "superset.kerberos.state" . | fromYaml -}}
{{- $kerb := $st.kerb -}}
{{- $kinit := $st.kinit -}}
{{- if and $kerb.enabled $kerb.configMapName }}
- name: krb5-conf
  mountPath: {{ default "/etc/krb5.conf" $kerb.mountPath }}
  subPath: {{ default "krb5.conf" $kerb.key }}
  readOnly: true
{{- end }}
{{- if and $kerb.enabled $kinit.cacheDir }}
- name: krb5-cache
  mountPath: {{ $kinit.cacheDir }}
{{- end }}
{{- end }}

{{- define "superset.kerberos.volumes" -}}
{{- $st := include "superset.kerberos.state" . | fromYaml -}}
{{- $kerb := $st.kerb -}}
{{- $kinit := $st.kinit -}}
{{- if and $kerb.enabled $kerb.configMapName }}
- name: krb5-conf
  configMap:
    name: {{ $kerb.configMapName }}
    {{- if $kerb.key }}
    items:
      - key: {{ $kerb.key }}
        path: krb5.conf
    {{- end }}
{{- end }}
{{- if and $kerb.enabled $kinit.cacheDir }}
- name: krb5-cache
  emptyDir: {}
{{- end }}
{{- end }}

{{- define "superset.kerberos.sidecar" -}}
{{- $st := include "superset.kerberos.state" . | fromYaml -}}
{{- $kerb := $st.kerb -}}
{{- $kinit := $st.kinit -}}
{{- $cacheFile := $st.cacheFile -}}
{{- $cacheDir := $st.cacheDir -}}
{{- if and $kerb.enabled $kinit.enabled }}
- name: kinit-renew
  image: {{- /* reuse override if provided, else main superset image */ -}}
    {{- $img := $kinit.image | default dict -}}
    {{- if or $img.repository $img.tag }}
      {{- printf "%s:%s" (default (printf "%s/%s" .Values.image.registry .Values.image.repository | trimPrefix "/") $img.repository) (default .Values.image.tag $img.tag) | quote -}}
    {{- else -}}
      {{ include "superset.image" (dict "root" . "image" .Values.image) | quote }}
    {{- end }}
  imagePullPolicy: {{ default .Values.image.pullPolicy $img.pullPolicy }}
  command:
    - /bin/sh
    - -c
    - >
      export KRB5CCNAME={{ default "/var/run/krb5/krb5cc_superset" $cacheFile }};
      svc={{ default "superset-dashboard" $kerb.serviceLabel }};
      ns={{ .Release.Namespace }};
      realm={{ default "EXAMPLE.COM" $kerb.realm }};
      princ={{ default "" $kinit.principal }};
      [ -z "$princ" ] && princ="${svc}-${ns}@${realm}";
      while true; do
        kinit -kt {{ printf "%s/%s" (default "/etc/security/keytabs" $kerb.keytab.mountPath) (default "service.keytab" $kerb.keytab.secretDataKey) }} "$princ" {{- if $kinit.extraArgs }} {{ join " " $kinit.extraArgs }}{{- end }} && \
        sleep {{ default 3600 $kinit.intervalSeconds }};
      done
  volumeMounts:
    {{ include "superset.truststore.volumeMount" . | nindent 4 }}
    {{- if and $kerb.enabled $kerb.configMapName }}
    - name: krb5-conf
      mountPath: {{ default "/etc/krb5.conf" $kerb.mountPath }}
      subPath: {{ default "krb5.conf" $kerb.key }}
      readOnly: true
    {{- end }}
    {{- if and $kerb.enabled $cacheDir }}
    - name: krb5-cache
      mountPath: {{ $cacheDir }}
    {{- end }}
{{- end }}
{{- end }}

{{- define "superset.image" -}}
{{- $globalReg := .root.Values.global.imageRegistry | default "" -}}
{{- $img       := .image -}}
{{- $reg       := $img.registry                      | default "" -}}
{{- $repo      := $img.repository                    | default "" -}}
{{- $name      := $img.name                          | default "" -}}
{{- $tag       := $img.tag                           | default (default "" .root.Chart.AppVersion) -}}
{{- $digest    := $img.digest                        | default "" -}}
{{- $sole      := $img.useRepositoryAsSoleImageReference | default false -}}

{{- /* Compose base repo/name following your rules */ -}}
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

{{- if $sole -}}
  {{- /* Do not prefix with any registry */ -}}
  {{- if $digest -}}
    {{- printf "%s@%s" $base $digest -}}
  {{- else -}}
    {{- printf "%s:%s" $base (default "latest" $tag) -}}
  {{- end -}}
{{- else -}}
  {{- $prefix := (default $reg $globalReg) -}}
  {{- $ref := (ternary (printf "%s/%s" $prefix $base) $base (ne $prefix "")) -}}
  {{- if $digest -}}
    {{- printf "%s@%s" $ref $digest -}}
  {{- else -}}
    {{- /* If no tag and no digest, fall back to latest to match your helper behavior */ -}}
    {{- printf "%s:%s" $ref (default "latest" $tag) -}}
  {{- end -}}
{{- end -}}
{{- end -}}

{{/* Merge imagePullSecrets: global + local */}}
{{- define "superset.imagePullSecrets" -}}
{{- $list := list -}}
{{- range (default (list) .Values.global.imagePullSecrets) }}
  {{- if kindIs "string" . -}}
    {{- $list = append $list (dict "name" .) -}}
  {{- else -}}
    {{- $list = append $list . -}}
  {{- end -}}
{{- end -}}
{{- range (default (list) .Values.imagePullSecrets) }}
  {{- if kindIs "string" . -}}
    {{- $list = append $list (dict "name" .) -}}
  {{- else -}}
    {{- $list = append $list . -}}
  {{- end -}}
{{- end -}}
{{- if gt (len $list) 0 -}}
{{- toYaml $list -}}
{{- end -}}
{{- end -}}
