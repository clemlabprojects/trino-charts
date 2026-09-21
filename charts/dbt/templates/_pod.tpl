{{/*
Shared pod internals for the documentation Deployment and the scheduled Job: they run
the same image against the same project, profile and security material, and differ only
in the command. Keeping one definition means a security fix cannot land in one and miss
the other.
*/}}

{{- define "dbt.volumes" -}}
- name: project
  {{- if .Values.project.existingClaim }}
  persistentVolumeClaim:
    claimName: {{ .Values.project.existingClaim }}
  {{- else }}
  emptyDir: {}
  {{- end }}
- name: artifacts
  {{- if .Values.persistence.enabled }}
  persistentVolumeClaim:
    claimName: {{ .Values.persistence.existingClaim | default (printf "%s-artifacts" (include "dbt.fullname" .)) }}
  {{- else }}
  emptyDir: {}
  {{- end }}
- name: profiles
  secret:
    secretName: {{ include "dbt.profilesSecretName" . }}
    items:
      - key: profiles.yml
        path: profiles.yml
- name: home
  emptyDir: {}
{{- if include "dbt.tlsTrustEnabled" . }}
- name: truststore
  secret:
    secretName: {{ .Values.global.security.tls.truststoreSecret }}
{{- end }}
{{- if .Values.global.security.kerberos.enabled }}
- name: keytab
  secret:
    secretName: {{ required "global.security.kerberos.keytab.secretName is required when Kerberos is enabled" .Values.global.security.kerberos.keytab.secretName }}
    defaultMode: 0400
{{- if .Values.global.security.kerberos.configMapName }}
- name: krb5-config
  configMap:
    name: {{ .Values.global.security.kerberos.configMapName }}
{{- end }}
{{- end }}
{{- if and (eq .Values.trino.auth.method "certificate") .Values.trino.auth.clientCertificateSecret }}
- name: client-cert
  secret:
    secretName: {{ .Values.trino.auth.clientCertificateSecret }}
    defaultMode: 0400
{{- end }}
{{- if .Values.project.git.enabled }}
{{- if .Values.project.git.secretRef.name }}
- name: git-credentials
  secret:
    secretName: {{ .Values.project.git.secretRef.name }}
    defaultMode: 0400
{{- end }}
{{- end }}
{{- with .Values.extraVolumes }}
{{- toYaml . }}
{{- end }}
{{- end -}}

{{- define "dbt.volumeMounts" -}}
- name: project
  mountPath: /dbt/project
- name: artifacts
  mountPath: /dbt/target
- name: profiles
  mountPath: /etc/dbt
  readOnly: true
- name: home
  mountPath: /home/dbt
{{- if include "dbt.tlsTrustEnabled" . }}
- name: truststore
  mountPath: {{ default "/etc/security/truststore" .Values.global.security.tls.mountPath }}
  readOnly: true
{{- end }}
{{- if .Values.global.security.kerberos.enabled }}
- name: keytab
  mountPath: {{ .Values.global.security.kerberos.keytab.mountPath }}
  readOnly: true
{{- if .Values.global.security.kerberos.configMapName }}
- name: krb5-config
  mountPath: /etc/krb5.conf
  subPath: krb5.conf
  readOnly: true
{{- end }}
{{- end }}
{{- if and (eq .Values.trino.auth.method "certificate") .Values.trino.auth.clientCertificateSecret }}
- name: client-cert
  mountPath: /etc/dbt/client-cert
  readOnly: true
{{- end }}
{{- with .Values.extraVolumeMounts }}
{{- toYaml . }}
{{- end }}
{{- end -}}

{{- define "dbt.env" -}}
- name: DBT_PROFILES_DIR
  value: /etc/dbt
{{- /* A project names the profile it expects; this deployment renders one. Telling dbt which
       profile to use lets any project run unchanged, without editing dbt_project.yml. */}}
- name: DBT_PROFILE_NAME
  value: {{ .Values.profiles.profileName | quote }}
- name: DBT_PROJECT_DIR
  value: {{ include "dbt.projectDir" . | quote }}
- name: DBT_TARGET_PATH
  value: /dbt/target
- name: DBT_LOG_PATH
  value: /dbt/target/logs
{{- if include "dbt.tlsTrustEnabled" . }}
- name: DBT_CA_BUNDLE
  value: {{ include "dbt.caBundlePath" . | quote }}
{{- end }}
{{- if .Values.global.security.kerberos.enabled }}
- name: DBT_KRB5_KEYTAB
  value: {{ printf "%s/%s" .Values.global.security.kerberos.keytab.mountPath .Values.global.security.kerberos.keytab.secretDataKey | quote }}
- name: DBT_KRB5_PRINCIPAL
  value: {{ .Values.global.security.kerberos.principal | quote }}
{{- end }}
{{- if .Values.project.git.enabled }}
- name: DBT_WAIT_FOR_PROJECT
  value: "true"
{{- end }}
{{- with .Values.env }}
{{- toYaml . }}
{{- end }}
{{- end -}}

{{/*
git-sync. Used twice: as an init container so the project exists before dbt starts,
and as a sidecar in the documentation pod so a push is picked up without a restart.
A scheduled run only gets the init container: a run must work on one fixed commit.
*/}}
{{- define "dbt.gitSyncContainer" -}}
{{- $g := .root.Values.project.git }}
name: {{ .oneTime | ternary "git-sync-init" "git-sync" }}
image: {{ include "dbt.gitSync.image" .root }}
imagePullPolicy: {{ .root.Values.image.pullPolicy }}
args:
  - --repo={{ required "project.git.repo is required when project.git.enabled is true" $g.repo }}
  - --ref={{ $g.branch }}
  - --root=/dbt/project
  - --link={{ $g.linkName | default "current" }}
  - --depth={{ $g.depth }}
  - --period={{ $g.period }}
{{- if .oneTime }}
  - --one-time
{{- end }}
{{- if $g.secretRef.name }}
{{- if $g.secretRef.sshKey }}
  - --ssh-key-file=/etc/git-secret/{{ $g.secretRef.sshKey }}
{{- if $g.knownHostsKey }}
  - --ssh-known-hosts-file=/etc/git-secret/{{ $g.knownHostsKey }}
{{- else }}
  - --ssh-known-hosts=false
{{- end }}
{{- end }}
{{- end }}
env:
{{- if and $g.secretRef.name $g.secretRef.tokenKey }}
  - name: GITSYNC_PASSWORD
    valueFrom:
      secretKeyRef:
        name: {{ $g.secretRef.name }}
        key: {{ $g.secretRef.tokenKey }}
        optional: true
{{- end }}
securityContext:
  {{- toYaml .root.Values.securityContext | nindent 2 }}
  {{- if .root.Values.runAsUser }}
  runAsUser: {{ .root.Values.runAsUser }}
  {{- end }}
volumeMounts:
  - name: project
    mountPath: /dbt/project
{{- if $g.secretRef.name }}
  - name: git-credentials
    mountPath: /etc/git-secret
    readOnly: true
{{- end }}
{{- with $g.resources }}
resources:
  {{- toYaml . | nindent 2 }}
{{- end }}
{{- end -}}
