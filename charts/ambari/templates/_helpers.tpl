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
{{- if and .Values.global.vault.enabled (or .Values.vault.csi.database.enabled .Values.vault.csi.routeCert.enabled .Values.vault.csi.masterKey.enabled .Values.vault.csi.apiCert.enabled .Values.vault.csi.adminPassword.enabled) -}}
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

{{/*
How the Route terminates TLS. Left empty, it follows the server: with Ambari serving HTTPS the router
must not be the one to decrypt it, so the Route re-encrypts when it has been given the CA to verify
Ambari's certificate with, and passes the connection through otherwise (that works with any
certificate, self-signed or privately issued). Without api.tls it stays edge, as it always was.
A misspelt mode is refused rather than handed to the router, which would reject the Route.
*/}}
{{- define "ambari.route.tlsMode" -}}
{{- $mode := .Values.route.tls.mode | default "" -}}
{{- if not (has $mode (list "" "edge" "edgeWithCert" "passthrough" "reencrypt")) -}}
{{- fail (printf "route.tls.mode must be edge, edgeWithCert, passthrough or reencrypt (or empty, to follow api.tls.enabled), not %q" $mode) -}}
{{- end -}}
{{- if $mode -}}
{{- $mode -}}
{{- else if not .Values.api.tls.enabled -}}
edge
{{- else if .Values.route.tls.destinationCACertificate -}}
reencrypt
{{- else -}}
passthrough
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
Where the first administrator password comes from. Required unless adminPassword.allowDefault is set:
without it the server comes up with the public admin/admin, and the Route serves it as soon as the
pod is Ready. Empty when the default is allowed and no password is given.
*/}}
{{- define "ambari.adminPassword.secretName" -}}
{{- if .Values.adminPassword.existingSecret -}}
{{- .Values.adminPassword.existingSecret -}}
{{- else if and (include "ambari.vault.csiEnabled" .) .Values.vault.csi.adminPassword.enabled -}}
{{- .Values.vault.csi.adminPassword.secretName | default (printf "%s-admin-password" (include "ambari.fullname" .)) -}}
{{- else if .Values.adminPassword.value -}}
{{- printf "%s-admin-password" (include "ambari.fullname" .) -}}
{{- else if not .Values.adminPassword.allowDefault -}}
{{- fail "the first administrator password is required: set adminPassword.existingSecret, or vault.csi.adminPassword.enabled, or adminPassword.value (adminPassword.allowDefault=true keeps admin/admin, for development only)" -}}
{{- end -}}
{{- end -}}

{{- define "ambari.adminPassword.secretKey" -}}
{{- if .Values.adminPassword.existingSecret -}}
{{- .Values.adminPassword.existingSecretKey -}}
{{- else if and (include "ambari.vault.csiEnabled" .) .Values.vault.csi.adminPassword.enabled -}}
{{- .Values.vault.csi.adminPassword.key -}}
{{- else -}}
{{- .Values.adminPassword.existingSecretKey -}}
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
Whether /var/log/ambari-server is on a claim rather than an emptyDir. Any other type is refused, so a
misspelt one does not quietly leave the logs in the container.
*/}}
{{- define "ambari.logs.onClaim" -}}
{{- if .Values.logs.persistence.enabled -}}
{{- $type := .Values.logs.persistence.type -}}
{{- if eq $type "pvc" -}}
true
{{- else if ne $type "emptyDir" -}}
{{- fail (printf "logs.persistence.type must be emptyDir or pvc, not %q" $type) -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{/*
Whether the data claim is mounted. It holds the KDPS internal CA and Ambari's credential store, so
without it every new pod signs certificates with a CA of its own and forgets the saved Git
credentials. Running without one is therefore refused unless persistence.acknowledgeEphemeral says
that is what is wanted.
*/}}
{{- define "ambari.persistence.onClaim" -}}
{{- if .Values.persistence.enabled -}}
true
{{- else if not .Values.persistence.acknowledgeEphemeral -}}
{{- fail "persistence.enabled=false keeps the KDPS internal CA and the saved Git credentials in the pod: every new pod would sign certificates with a new CA, so the services deployed before and after it would no longer trust each other, and forget the Git credentials of GitOps releases. Keep persistence.enabled=true, or set persistence.acknowledgeEphemeral=true for a throwaway install" -}}
{{- end -}}
{{- end -}}

{{/*
The server is given stopTimeoutSeconds to stop before the entrypoint kills it, and Kubernetes kills
the whole pod terminationGracePeriodSeconds after asking it to stop. A grace period no longer than
the stop timeout would cut every slow shutdown short, which is what the stop timeout is there to
prevent; the 5 extra seconds are for the entrypoint itself, which prints the server's last log lines
after it has gone.
*/}}
{{- define "ambari.stopTimeoutSeconds" -}}
{{- $stop := int .Values.stopTimeoutSeconds -}}
{{- $grace := int .Values.terminationGracePeriodSeconds -}}
{{- if lt $stop 1 -}}
{{- fail (printf "stopTimeoutSeconds must be at least 1, not %v" .Values.stopTimeoutSeconds) -}}
{{- end -}}
{{- if lt $grace (add $stop 5) -}}
{{- fail (printf "terminationGracePeriodSeconds (%d) must be at least stopTimeoutSeconds (%d) + 5, or Kubernetes kills the server before it has stopped" $grace $stop) -}}
{{- end -}}
{{- $stop -}}
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

{{/*
Who may open a connection to the server when networkPolicy.enabled is set, as NetworkPolicyPeer
entries: the namespaces of the router or ingress controller, the configured address ranges, and any
peer given verbatim. Empty when none is configured, and the policy then admits nobody, never everybody:
a rule whose `from` list is empty would let every pod in the cluster in.
*/}}
{{- define "ambari.networkPolicy.peers" -}}
{{- $peers := list -}}
{{- range .Values.networkPolicy.ingressNamespaceSelectors -}}
{{- if not . -}}
{{- fail "networkPolicy.ingressNamespaceSelectors: an empty selector matches every namespace, which is what the policy is there to prevent; name the labels of the router's or ingress controller's namespace" -}}
{{- end -}}
{{- $peers = append $peers (dict "namespaceSelector" (dict "matchLabels" .)) -}}
{{- end -}}
{{- range .Values.networkPolicy.allowedCIDRs -}}
{{- $peers = append $peers (dict "ipBlock" (dict "cidr" .)) -}}
{{- end -}}
{{- range .Values.networkPolicy.extraFrom -}}
{{- $peers = append $peers . -}}
{{- end -}}
{{- if $peers -}}
{{- toYaml $peers -}}
{{- end -}}
{{- end -}}
