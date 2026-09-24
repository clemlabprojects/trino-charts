{{- define "ambari.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "ambari.fullname" -}}
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

{{- define "ambari.labels" -}}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{ include "ambari.selectorLabels" . }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: kdps
{{- end -}}

{{- define "ambari.selectorLabels" -}}
app.kubernetes.io/name: {{ include "ambari.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{- define "ambari.serviceAccountName" -}}
{{- if .Values.serviceAccount.create -}}
{{- default (include "ambari.fullname" .) .Values.serviceAccount.name -}}
{{- else -}}
{{- default "default" .Values.serviceAccount.name -}}
{{- end -}}
{{- end -}}

{{- define "ambari.image" -}}
{{- $reg := .Values.image.registry | default .Values.global.imageRegistry -}}
{{- $tag := .Values.image.tag | default .Chart.AppVersion -}}
{{- if .Values.image.digest -}}
{{- printf "%s/%s@%s" $reg .Values.image.repository .Values.image.digest -}}
{{- else -}}
{{- printf "%s/%s:%s" $reg .Values.image.repository $tag -}}
{{- end -}}
{{- end -}}

{{/* The Secret holding the database password, whatever produced it. */}}
{{/*
Whether anything is being read out of Vault. There is deliberately no separate master switch:
turning Vault on and then naming nothing to read from it is a mistake, not a configuration.
*/}}
{{- define "ambari.vault.csiEnabled" -}}
{{- if and .Values.global.vault.enabled (or .Values.vault.csi.database.enabled .Values.vault.csi.routeCert.enabled .Values.vault.csi.masterKey.enabled .Values.vault.csi.apiCert.enabled) -}}
true
{{- end -}}
{{- end -}}

{{- define "ambari.db.secretName" -}}
{{- if .Values.database.existingSecret -}}
{{- .Values.database.existingSecret -}}
{{- else if and (include "ambari.vault.csiEnabled" .) .Values.vault.csi.database.enabled -}}
{{- .Values.vault.csi.database.secretName | default (printf "%s-db" (include "ambari.fullname" .)) -}}
{{- else -}}
{{- printf "%s-db" (include "ambari.fullname" .) -}}
{{- end -}}
{{- end -}}

{{- define "ambari.db.passwordKey" -}}
{{- if .Values.database.existingSecret -}}
{{- .Values.database.existingSecretPasswordKey -}}
{{- else if and (include "ambari.vault.csiEnabled" .) .Values.vault.csi.database.enabled -}}
{{- .Values.vault.csi.database.passwordKey -}}
{{- else -}}
password
{{- end -}}
{{- end -}}

{{/* Certificate Secret for the Route: named after the route host unless told otherwise. */}}
{{- define "ambari.route.tlsSecretName" -}}
{{- if .Values.route.tls.secretName -}}
{{- .Values.route.tls.secretName -}}
{{- else -}}
{{- printf "%s-tls" (required "route.host is required when route.enabled" .Values.route.host) -}}
{{- end -}}
{{- end -}}

{{- define "ambari.ingress.tlsSecretName" -}}
{{- if .Values.ingress.tls.secretName -}}
{{- .Values.ingress.tls.secretName -}}
{{- else -}}
{{- printf "%s-tls" (required "ingress.host is required when ingress.enabled" .Values.ingress.host) -}}
{{- end -}}
{{- end -}}

{{- define "ambari.vault.secretProviderClassName" -}}
{{- printf "%s-vault" (include "ambari.fullname" .) -}}
{{- end -}}

{{- define "ambari.imagePullSecrets" -}}
{{- $secrets := concat (.Values.global.imagePullSecrets | default list) (.Values.imagePullSecrets | default list) -}}
{{- if $secrets }}
imagePullSecrets:
{{- range $secrets }}
  - name: {{ if kindIs "string" . }}{{ . }}{{ else }}{{ .name }}{{ end }}
{{- end }}
{{- end -}}
{{- end -}}

{{/*
Where the master key comes from. Required: the chart refuses to render without it, because a server
without a master key silently encrypts the KDPS view's kubeconfig with a published constant.
*/}}
{{- define "ambari.masterKey.secretName" -}}
{{- if .Values.masterKey.existingSecret -}}
{{- .Values.masterKey.existingSecret -}}
{{- else if and (include "ambari.vault.csiEnabled" .) .Values.vault.csi.masterKey.enabled -}}
{{- .Values.vault.csi.masterKey.secretName | default (printf "%s-master-key" (include "ambari.fullname" .)) -}}
{{- else if .Values.masterKey.value -}}
{{- printf "%s-master-key" (include "ambari.fullname" .) -}}
{{- else -}}
{{- fail "a master key is required: set masterKey.existingSecret, or vault.csi.masterKey.enabled, or masterKey.value" -}}
{{- end -}}
{{- end -}}

{{- define "ambari.masterKey.secretKey" -}}
{{- if .Values.masterKey.existingSecret -}}
{{- .Values.masterKey.existingSecretKey -}}
{{- else if and (include "ambari.vault.csiEnabled" .) .Values.vault.csi.masterKey.enabled -}}
{{- .Values.vault.csi.masterKey.key -}}
{{- else -}}
{{- .Values.masterKey.existingSecretKey -}}
{{- end -}}
{{- end -}}

{{/*
The kubernetes.io/tls Secret holding the certificate Ambari itself serves.
*/}}
{{- define "ambari.api.vaultCert" -}}
{{- if and (include "ambari.vault.csiEnabled" .) .Values.vault.csi.apiCert.enabled (not .Values.api.tls.existingSecret) -}}
true
{{- end -}}
{{- end -}}

{{- define "ambari.api.tlsSecretName" -}}
{{- if .Values.api.tls.existingSecret -}}
{{- .Values.api.tls.existingSecret -}}
{{- else if and (include "ambari.vault.csiEnabled" .) .Values.vault.csi.apiCert.enabled -}}
{{- .Values.vault.csi.apiCert.secretName | default (printf "%s-api-tls" (include "ambari.fullname" .)) -}}
{{- else -}}
{{- fail "api.tls.enabled needs a certificate: set api.tls.existingSecret or vault.csi.apiCert.enabled" -}}
{{- end -}}
{{- end -}}

{{/*
The name of the port the Service and the probes should talk to. With Ambari terminating TLS there is
no plain listener left: the client connector is one or the other, never both.
*/}}
{{- define "ambari.serverPortName" -}}
{{- if .Values.api.tls.enabled -}}https{{- else -}}http{{- end -}}
{{- end -}}

{{/*
Everything the deployment wants to say about ambari.properties, as one key=value per line. The
entrypoint applies these after `ambari-server setup`, which rewrites that file.
*/}}
{{- define "ambari.extraProperties" -}}
{{- $lines := list -}}
{{- $lines = append $lines (printf "agent.ssl=%t" .Values.agent.enabled) -}}
{{- if .Values.api.tls.enabled -}}
{{- $lines = append $lines "api.ssl=true" -}}
{{- $lines = append $lines "client.api.ssl.keys_dir=/opt/ambari-https" -}}
{{- $lines = append $lines (printf "client.api.ssl.port=%v" .Values.api.tls.port) -}}
{{- else -}}
{{- $lines = append $lines "api.ssl=false" -}}
{{- end -}}
{{- range $k, $v := .Values.database.properties -}}
{{- $lines = append $lines (printf "server.jdbc.properties.%s=%v" $k $v) -}}
{{- end -}}
{{- join "\n" $lines -}}
{{- end -}}
