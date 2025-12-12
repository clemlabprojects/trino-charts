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

{{/* Security profile wiring: expose auth settings as env vars for Superset to consume in custom config */}}
{{- define "superset.security.env" -}}
{{- $auth := .Values.global.security.auth | default dict -}}
{{- if $auth.mode }}
- name: SECURITY_AUTH_MODE
  value: {{ $auth.mode | quote }}
{{- if eq $auth.mode "ldap" }}
- name: SECURITY_LDAP_URL
  value: {{ $auth.ldap.url | quote }}
- name: SECURITY_LDAP_BIND_DN
  value: {{ $auth.ldap.bindDn | quote }}
- name: SECURITY_LDAP_BIND_PASSWORD
  value: {{ $auth.ldap.bindPassword | quote }}
{{- end }}
{{- if or (eq $auth.mode "ldap") (eq $auth.mode "ad") }}
- name: SECURITY_LDAP_USER_DN_TEMPLATE
  value: {{ $auth.ldap.userDnTemplate | quote }}
- name: SECURITY_LDAP_USER_SEARCH_FILTER
  value: {{ $auth.ldap.userSearchFilter | quote }}
- name: SECURITY_LDAP_BASE_DN
  value: {{ $auth.ldap.baseDn | quote }}
- name: SECURITY_LDAP_GROUP_SEARCH_BASE
  value: {{ $auth.ldap.groupSearchBase | quote }}
- name: SECURITY_LDAP_GROUP_SEARCH_FILTER
  value: {{ $auth.ldap.groupSearchFilter | quote }}
- name: SECURITY_LDAP_REFERRAL
  value: {{ $auth.ldap.referral | quote }}
- name: SECURITY_LDAP_STARTTLS
  value: {{ $auth.ldap.startTls | default false | quote }}
{{- end }}
{{- if eq $auth.mode "ad" }}
- name: SECURITY_AD_URL
  value: {{ $auth.ad.url | quote }}
- name: SECURITY_AD_BASE_DN
  value: {{ $auth.ad.baseDn | quote }}
- name: SECURITY_AD_BIND_DN
  value: {{ $auth.ad.bindDn | quote }}
- name: SECURITY_AD_BIND_PASSWORD
  value: {{ $auth.ad.bindPassword | quote }}
- name: SECURITY_AD_USER_SEARCH_FILTER
  value: {{ $auth.ad.userSearchFilter | quote }}
- name: SECURITY_AD_DOMAIN
  value: {{ $auth.ad.domain | quote }}
{{- end }}
{{- if eq $auth.mode "oidc" }}
- name: SECURITY_OIDC_ISSUER
  value: {{ $auth.oidc.issuerUrl | quote }}
- name: SECURITY_OIDC_CLIENT_ID
  value: {{ $auth.oidc.clientId | quote }}
- name: SECURITY_OIDC_CLIENT_SECRET
  value: {{ $auth.oidc.clientSecret | quote }}
- name: SECURITY_OIDC_SCOPES
  value: {{ $auth.oidc.scopes | quote }}
- name: SECURITY_OIDC_REDIRECT_URI
  value: {{ $auth.oidc.redirectUri | quote }}
- name: SECURITY_OIDC_USER_CLAIM
  value: {{ $auth.oidc.userClaim | quote }}
- name: SECURITY_OIDC_GROUPS_CLAIM
  value: {{ $auth.oidc.groupsClaim | quote }}
- name: SECURITY_OIDC_SKIP_TLS_VERIFY
  value: {{ $auth.oidc.skipTlsVerify | default false | quote }}
- name: SECURITY_OIDC_CA_SECRET
  value: {{ $auth.oidc.caSecret | quote }}
{{- end }}
{{- end }}
{{- end -}}

{{/* Optional admin mapping (users/groups -> Admin role) */}}
{{- define "superset.admin.env" -}}
{{- $adm := .Values.global.security.adminUsers | default "" -}}
{{- $admGroups := .Values.global.security.adminGroups | default "" -}}
{{- if $adm }}
- name: SECURITY_ADMIN_USERS
  value: {{ $adm | quote }}
{{- end }}
{{- if $admGroups }}
- name: SECURITY_ADMIN_GROUPS
  value: {{ $admGroups | quote }}
{{- end }}
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
import logging
logging.getLogger("flask_appbuilder.security").setLevel(logging.DEBUG)
logging.getLogger("ldap").setLevel(logging.DEBUG)
logging.getLogger("superset.security").setLevel(logging.DEBUG)
LOG_LEVEL="DEBUG"
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

# -------------------- Security Profiles --------------------
AUTH_TYPE = os.getenv("SECURITY_AUTH_MODE", "none").upper()
if AUTH_TYPE == "OIDC":
    from flask_appbuilder.security.manager import AUTH_OAUTH
    AUTH_TYPE = AUTH_OAUTH
    OAUTH_PROVIDERS = [
        {
            'name': 'generic',
            'token_key': 'access_token',
            'icon': 'fa-user',
            'remote_app': {
                'client_id': env('SECURITY_OIDC_CLIENT_ID'),
                'client_secret': env('SECURITY_OIDC_CLIENT_SECRET'),
                'api_base_url': env('SECURITY_OIDC_ISSUER'),
                'access_token_url': env('SECURITY_OIDC_ISSUER') + '/protocol/openid-connect/token',
                'authorize_url': env('SECURITY_OIDC_ISSUER') + '/protocol/openid-connect/auth',
                'client_kwargs': {
                    'scope': env('SECURITY_OIDC_SCOPES', 'openid email profile'),
                },
            },
            'redirect_uri': env('SECURITY_OIDC_REDIRECT_URI'),
        }
    ]
elif AUTH_TYPE in ("LDAP", "AD"):
    from flask_appbuilder.security.manager import AUTH_LDAP
    AUTH_TYPE = AUTH_LDAP
    AUTH_LDAP_SERVER = env('SECURITY_LDAP_URL') or env('SECURITY_AD_URL')
    AUTH_LDAP_USE_TLS = env('SECURITY_LDAP_STARTTLS', 'false').lower() == 'true'
    AUTH_LDAP_BIND_USER = env('SECURITY_LDAP_BIND_DN') or env('SECURITY_AD_BIND_DN')
    AUTH_LDAP_BIND_PASSWORD = env('SECURITY_LDAP_BIND_PASSWORD') or env('SECURITY_AD_BIND_PASSWORD')
    AUTH_LDAP_SEARCH = env('SECURITY_LDAP_BASE_DN') or env('SECURITY_AD_BASE_DN')
    AUTH_LDAP_SEARCH_FILTER = env('SECURITY_LDAP_USER_SEARCH_FILTER') or env('SECURITY_AD_USER_SEARCH_FILTER')
    AUTH_LDAP_UID_FIELD = 'uid'

    # Group settings
    AUTH_ROLES_SYNC_AT_LOGIN = True
    AUTH_LDAP_GROUP_FIELD = 'memberOf'
    AUTH_LDAP_GROUP_SEARCH = env('SECURITY_LDAP_GROUP_SEARCH_BASE', '')
    AUTH_LDAP_GROUP_SEARCH_FILTER = env('SECURITY_LDAP_GROUP_SEARCH_FILTER', '')
    AUTH_LDAP_GROUP_SEARCH_SCOPE = 'SUBTREE'
    AUTH_LDAP_GROUP_MEMBER_ATTR = 'member'
    # Auto-create users on successful LDAP auth
    AUTH_USER_REGISTRATION = True
    # For initial tests, make first LDAP user admin; change to Gamma to have no rights
    AUTH_USER_REGISTRATION_ROLE = "Gamma"
else:
    from flask_appbuilder.security.manager import AUTH_DB
    AUTH_TYPE = AUTH_DB

# --- Admin/user/group mapping ---
ADMIN_ROLE_NAME = env('SECURITY_ADMIN_ROLE', 'Admin')
ADMIN_USERS = [u.strip() for u in env('SECURITY_ADMIN_USERS', '').split(',') if u.strip()]
ADMIN_GROUPS = [g.strip() for g in env('SECURITY_ADMIN_GROUPS', '').split(',') if g.strip()]

AUTH_ROLES_MAPPING = {}
for u in ADMIN_USERS:
    AUTH_ROLES_MAPPING[u] = [ADMIN_ROLE_NAME]
for g in ADMIN_GROUPS:
    AUTH_ROLES_MAPPING[f"group:{g}"] = [ADMIN_ROLE_NAME]

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


{{/* Kerberos helpers: simple and explicit */}}

{{- define "superset.kerberos.env" -}}
{{- $global := .Values.global | default dict -}}
{{- $sec    := $global.security | default dict -}}
{{- $kerb   := $sec.kerberos | default dict -}}
{{- $kinit  := $kerb.kinitSidecar | default dict -}}
{{- if $kerb.enabled }}
- name: KRB5CCNAME
  value: {{ default "/var/run/krb5/krb5cc_superset" $kinit.cacheFile | quote }}
{{- end }}
{{- end }}

{{- define "superset.kerberos.volumeMounts" -}}
{{- $global := .Values.global | default dict -}}
{{- $sec    := $global.security | default dict -}}
{{- $kerb   := $sec.kerberos | default dict -}}
{{- $kinit  := $kerb.kinitSidecar | default dict -}}
{{- if $kerb.enabled }}
  {{- if $kerb.configMapName }}
- name: krb5-conf
  mountPath: {{ default "/etc/krb5.conf" $kerb.mountPath }}
  subPath: {{ default "krb5.conf" $kerb.key }}
  readOnly: true
  {{- end }}
  {{- if $kinit.cacheDir }}
- name: krb5-cache
  mountPath: {{ $kinit.cacheDir }}
  {{- end }}
{{- end }}
{{- end }}

{{- define "superset.kerberos.volumes" -}}
{{- $global := .Values.global | default dict -}}
{{- $sec    := $global.security | default dict -}}
{{- $kerb   := $sec.kerberos | default dict -}}
{{- $kinit  := $kerb.kinitSidecar | default dict -}}
{{- if $kerb.enabled }}
  {{- if $kerb.configMapName }}
- name: krb5-conf
  configMap:
    name: {{ $kerb.configMapName }}
    items:
      - key: {{ default "krb5.conf" $kerb.key }}
        path: krb5.conf
  {{- end }}
  {{- if $kinit.cacheDir }}
- name: krb5-cache
  emptyDir: {}
  {{- end }}
{{- end }}
{{- end }}

{{- define "superset.kerberos.sidecar" -}}
{{- $global := .Values.global | default dict -}}
{{- $sec    := $global.security | default dict -}}
{{- $kerb   := $sec.kerberos | default dict -}}
{{- $kinit  := $kerb.kinitSidecar | default dict -}}
{{- if $kerb.enabled }}
{{- $img := $kinit.image | default dict -}}
- name: kinit-renew
  {{- if or $img.repository $img.tag }}
  image: {{ printf "%s:%s" (default .Values.image.repository $img.repository) (default .Values.image.tag $img.tag) | quote }}
  {{- else }}
  image: {{ include "superset.image" (dict "root" . "image" .Values.image) | quote }}
  {{- end }}
  imagePullPolicy: {{ default .Values.image.pullPolicy $img.pullPolicy }}
  command:
    - /bin/sh
    - -c
    - >
      export KRB5CCNAME={{ default "/var/run/krb5/krb5cc_superset" $kinit.cacheFile }};
      svc={{ default "superset-dashboard" $kerb.serviceLabel }};
      ns={{ .Release.Namespace }};
      realm={{ default "EXAMPLE.COM" $kerb.realm }};
      princ={{ default "" $kinit.principal }};
      [ -z "$princ" ] && princ="${svc}-${ns}@${realm}";
      while true; do
        kinit -kt {{ printf "%s/%s" (default "/etc/security/keytabs" $kerb.keytab.mountPath) (default "service.keytab" $kerb.keytab.secretDataKey) }} "$princ"{{- if $kinit.extraArgs }} {{ join " " $kinit.extraArgs }}{{- end }} && \
        sleep {{ default 3600 $kinit.intervalSeconds }};
      done
  volumeMounts:
    {{ include "superset.truststore.volumeMount" . | nindent 4 }}
    {{- if $kerb.configMapName }}
    - name: krb5-conf
      mountPath: {{ default "/etc/krb5.conf" $kerb.mountPath }}
      subPath: {{ default "krb5.conf" $kerb.key }}
      readOnly: true
    {{- end }}
    {{- if $kinit.cacheDir }}
    - name: krb5-cache
      mountPath: {{ $kinit.cacheDir }}
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
