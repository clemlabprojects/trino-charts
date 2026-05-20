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
{{- $oidcSecretRef := $auth.oidc.secretRef | default dict }}
{{- if $oidcSecretRef.name }}
{{- /* Ambari-managed: read clientId and clientSecret from K8s Secret via secretKeyRef
     to avoid storing credentials in Helm release history. */}}
- name: SECURITY_OIDC_CLIENT_ID
  valueFrom:
    secretKeyRef:
      name: {{ $oidcSecretRef.name | quote }}
      key: {{ default "client_id" $oidcSecretRef.clientIdKey | quote }}
- name: SECURITY_OIDC_CLIENT_SECRET
  valueFrom:
    secretKeyRef:
      name: {{ $oidcSecretRef.name | quote }}
      key: {{ default "client_secret" $oidcSecretRef.clientSecretKey | quote }}
{{- else }}
{{- /* Manual / fallback: plain Helm values (operator-supplied) */}}
- name: SECURITY_OIDC_CLIENT_ID
  value: {{ $auth.oidc.clientId | quote }}
- name: SECURITY_OIDC_CLIENT_SECRET
  value: {{ $auth.oidc.clientSecret | quote }}
{{- end }}
- name: SECURITY_OIDC_SCOPES
  value: {{ $auth.oidc.scopes | default "openid email profile" | quote }}
- name: SECURITY_OIDC_REDIRECT_URI
  value: {{ $auth.oidc.redirectUri | quote }}
- name: SECURITY_OIDC_USER_CLAIM
  value: {{ $auth.oidc.userClaim | default "preferred_username" | quote }}
- name: SECURITY_OIDC_GROUPS_CLAIM
  value: {{ $auth.oidc.groupsClaim | default "groups" | quote }}
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
MAP_TILES_SERVER_URL = env("OPENSTREETMAP_SERVER_URL", "").rstrip("/")
MAPBOX_STYLE = MAP_TILES_SERVER_URL+"/styles/basic-preview/style.json"

# Optional but recommended
DEFAULT_MAP_TILE = "osm_local"
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
    from superset.security import SupersetSecurityManager
    AUTH_TYPE = AUTH_OAUTH
    # Auto-create users seen via OIDC. Without this, FAB returns a generic
    # "Invalid login" right after a successful Keycloak callback because the
    # user does not yet exist locally.
    AUTH_USER_REGISTRATION = True
    AUTH_USER_REGISTRATION_ROLE = env('SECURITY_OIDC_DEFAULT_ROLE', 'Gamma')
    AUTH_ROLES_SYNC_AT_LOGIN = True

    _USER_CLAIM = env('SECURITY_OIDC_USER_CLAIM', 'preferred_username')
    _GROUPS_CLAIM = env('SECURITY_OIDC_GROUPS_CLAIM', 'groups')

    class CustomSsoSecurityManager(SupersetSecurityManager):
        # Without an explicit mapping, FAB's "generic" provider does not know
        # how to turn Keycloak's userinfo response into a User row, so login
        # fails with: "Error returning OAuth user info" / "Invalid login.
        # Please try again." even though the OIDC handshake succeeded.
        def oauth_user_info(self, provider, response=None):
            if provider != 'generic':
                return {}
            me = self.appbuilder.sm.oauth_remotes[provider].userinfo()
            username = me.get(_USER_CLAIM) or me.get('preferred_username') or me.get('sub')
            groups = me.get(_GROUPS_CLAIM) or []
            if isinstance(groups, str):
                groups = [groups]
            # role_keys feeds AUTH_ROLES_MAPPING below. FAB's contract is that
            # AUTH_ROLES_MAPPING maps an external "role key" (could be a group
            # name, a role name, or in our extended convention here, a username)
            # to a list of FAB roles. We append the username so the per-user
            # ADMIN_USERS list works for OIDC — LDAP got this for free via the
            # group DN match, but OIDC has no concept of per-user role grants
            # without our help.
            role_keys = list(groups)
            if username:
                role_keys.append(str(username))
            return {
                'username': username,
                'name': me.get('name') or username,
                'email': me.get('email', ''),
                'first_name': me.get('given_name', ''),
                'last_name': me.get('family_name', ''),
                'role_keys': role_keys,
            }

    CUSTOM_SECURITY_MANAGER = CustomSsoSecurityManager

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
                'userinfo_endpoint': env('SECURITY_OIDC_ISSUER') + '/protocol/openid-connect/userinfo',
                # Required for Authlib to validate the ID token signature: fetches the
                # OIDC discovery doc, which carries the jwks_uri Authlib reads at verify
                # time. Without this, login fails with: Missing "jwks_uri" in metadata.
                'server_metadata_url': env('SECURITY_OIDC_ISSUER') + '/.well-known/openid-configuration',
                'jwks_uri': env('SECURITY_OIDC_ISSUER') + '/protocol/openid-connect/certs',
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
# AUTH_ROLES_MAPPING is the FAB lookup table that turns "role keys" (any external
# identifier — usernames, group short names, group DNs, IdP roles) into local
# Superset/FAB roles. The CustomSsoSecurityManager for OIDC feeds username +
# the user's groups claim into role_keys; the LDAP path feeds the user's
# memberOf DN list. Both end up looked up here, so we populate the table with
# every form a key might take.
ADMIN_ROLE_NAME = env('SECURITY_ADMIN_ROLE', 'Admin')
ADMIN_USERS = [u.strip() for u in env('SECURITY_ADMIN_USERS', '').split(',') if u.strip()]
ADMIN_GROUPS_RAW = [g.strip() for g in env("SECURITY_ADMIN_GROUPS", "").split(",") if g.strip()]
LDAP_GROUPS_BASE = env("SECURITY_LDAP_GROUP_SEARCH_BASE", "")  # e.g. cn=groups,cn=accounts,dc=...
LDAP_GROUP_RDN_ATTR = env("SECURITY_LDAP_GROUP_RDN_ATTR", "cn")  # cn | uid | whatever

def _is_dn(s: str) -> bool:
    return "=" in s and "," in s  # good enough for our purposes

# Build the mapping once, populating every key form we know how to receive.
# Earlier revisions of this template reset AUTH_ROLES_MAPPING to {} between
# the user and group blocks, which silently wiped out the per-user grants —
# don't reintroduce that.
AUTH_ROLES_MAPPING = {}

# Per-user grants (used by OIDC via username injected into role_keys,
# and by LDAP if the IdP ever surfaces the bare username as a key — rare but
# safe to have).
for u in ADMIN_USERS:
    AUTH_ROLES_MAPPING[u] = [ADMIN_ROLE_NAME]

# Per-group grants. Accepts:
#   - short name (e.g. "hadoop_admins")  → used by OIDC groups claim
#   - full LDAP DN (e.g. "cn=hadoop_admins,cn=groups,...") → used by LDAP memberOf
# When only the short name is supplied AND a base DN is known, the DN form is
# also added so LDAP and OIDC users with the same logical group both match.
for g in ADMIN_GROUPS_RAW:
    if _is_dn(g):
        AUTH_ROLES_MAPPING[g] = [ADMIN_ROLE_NAME]
    else:
        if LDAP_GROUPS_BASE:
            dn = f"{LDAP_GROUP_RDN_ATTR}={g},{LDAP_GROUPS_BASE}"
            AUTH_ROLES_MAPPING[dn] = [ADMIN_ROLE_NAME]
        AUTH_ROLES_MAPPING[g] = [ADMIN_ROLE_NAME]

AUTH_ROLES_SYNC_AT_LOGIN = True
logging.getLogger("flask_appbuilder.security.manager").setLevel(logging.DEBUG)

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
# --- Hive fix: stop Superset from running Presto-style "SHOW CATALOGS" on Hive ---
def FLASK_APP_MUTATOR(app):
    from superset.db_engine_specs.hive import HiveEngineSpec

    @classmethod
    def _no_catalogs(cls, database, inspector):
        return set()

    HiveEngineSpec.get_catalog_names = _no_catalogs
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
{{- $tls := ((((.Values.global).security).tls) | default dict) -}}
{{- $truststore := ($tls.truststore | default dict) -}}
{{- if and $tls.enabled $truststore.enabled $tls.truststoreSecret }}
{{- $env := $tls.env | default dict -}}
{{- $pathEnv := default "TRUSTSTORE_PATH" $env.pathEnv -}}
{{- $mountPath := default "/etc/security/truststore/ca.crt" $tls.mountPath -}}
- name: {{ $pathEnv | quote }}
  value: {{ $mountPath | quote }}
# Python (requests / urllib3 / oauthlib) reads the CA bundle from REQUESTS_CA_BUNDLE
# (preferred) and CURL_CA_BUNDLE (fallback). Flask-AppBuilder's OAuth code-exchange
# call goes through requests, so without these the back-channel POST to Keycloak
# fails with SSLCertVerificationError ("unable to get local issuer certificate")
# whenever the IdP cert is signed by an internal CA.
- name: "REQUESTS_CA_BUNDLE"
  value: {{ $mountPath | quote }}
- name: "CURL_CA_BUNDLE"
  value: {{ $mountPath | quote }}
- name: "SSL_CERT_FILE"
  value: {{ $mountPath | quote }}
{{- end }}
{{- end }}

{{- define "superset.truststore.volumeMount" -}}
{{- $tls := ((((.Values.global).security).tls) | default dict) -}}
{{- $truststore := ($tls.truststore | default dict) -}}
{{- if and $tls.enabled $truststore.enabled $tls.truststoreSecret }}
- name: truststore
  mountPath: {{ default "/etc/security/truststore/ca.crt" $tls.mountPath | quote }}
  subPath: {{ default "ca.crt" $truststore.pemKey | quote }}
  readOnly: true
{{- end }}
{{- end }}

{{- define "superset.truststore.volume" -}}
{{- $tls := ((((.Values.global).security).tls) | default dict) -}}
{{- $truststore := ($tls.truststore | default dict) -}}
{{- if and $tls.enabled $truststore.enabled $tls.truststoreSecret }}
- name: truststore
  secret:
    secretName: {{ $tls.truststoreSecret }}
    items:
      - key: {{ default "ca.crt" $truststore.pemKey }}
        path: {{ default "ca.crt" $truststore.pemKey }}
{{- end }}
{{- end }}

{{/* Vault CSI helpers */}}
{{- define "superset.vault.secretProviderClassName" -}}
{{- if and .Values.vault .Values.vault.csi .Values.vault.csi.secretProviderClassName }}
{{- .Values.vault.csi.secretProviderClassName -}}
{{- else -}}
{{- printf "%s-vault" (include "superset.fullname" .) -}}
{{- end -}}
{{- end }}

{{- define "superset.vault.volumeMount" -}}
{{- if and .Values.global.vault.enabled .Values.vault.csi.enabled }}
- name: vault-secrets
  mountPath: {{ default "/vault/secrets" .Values.vault.csi.mountPath | quote }}
  readOnly: {{ default true .Values.vault.csi.readOnly }}
{{- end }}
{{- end }}

{{- define "superset.vault.volume" -}}
{{- if and .Values.global.vault.enabled .Values.vault.csi.enabled }}
- name: vault-secrets
  csi:
    driver: secrets-store.csi.k8s.io
    readOnly: {{ default true .Values.vault.csi.readOnly }}
    volumeAttributes:
      secretProviderClass: {{ include "superset.vault.secretProviderClassName" . | quote }}
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
  {{- if $kerb.keytab.secretName }}
- name: keytab-secret
  mountPath: {{ default "/etc/security/keytabs" $kerb.keytab.mountPath }}
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
  {{- if $kerb.keytab.secretName }}
- name: keytab-secret
  secret:
    secretName: {{ $kerb.keytab.secretName }}
    items:
      - key: {{ default "service.keytab" $kerb.keytab.secretDataKey }}
        path: {{ default "service.keytab" $kerb.keytab.secretDataKey }}
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
    {{- if $kerb.keytab.secretName }}
    - name: keytab-secret
      mountPath: {{ default "/etc/security/keytabs" $kerb.keytab.mountPath }}
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
