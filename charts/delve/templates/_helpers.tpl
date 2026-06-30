{{/* Expand the chart name. */}}
{{- define "delve.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/* Fully qualified app name, based on the release name. */}}
{{- define "delve.fullname" -}}
{{- if .Values.fullnameOverride -}}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s" .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}

{{/* Common labels. */}}
{{- define "delve.labels" -}}
app.kubernetes.io/name: {{ include "delve.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end -}}

{{/* ServiceAccount name. */}}
{{- define "delve.serviceAccountName" -}}
{{- default (include "delve.fullname" .) .Values.serviceAccount.name -}}
{{- end -}}

{{/* Name of the Secret carrying the Django SECRET_KEY. */}}
{{- define "delve.secretKeyRefName" -}}
{{- default .Values.database.secretName .Values.secretKeyRef.name -}}
{{- end -}}

{{/*
Shared environment block for web, worker, and migrate. DB credentials and the
Django SECRET_KEY come from the VSO-synced secret; everything else is literal.
*/}}
{{- define "delve.env" -}}
- name: DELVE_SECRET_KEY
  valueFrom:
    secretKeyRef:
      name: {{ include "delve.secretKeyRefName" . }}
      key: {{ .Values.secretKeyRef.key }}
- name: DELVE_DEBUG
  value: "False"
- name: DELVE_ALLOWED_HOSTS
  value: "{{ .Values.allowedHosts }},localhost,127.0.0.1"
- name: DELVE_DATABASE_ENGINE
  value: "{{ .Values.database.engine }}"
- name: DELVE_DATABASE_NAME
  value: "{{ .Values.database.name }}"
- name: DELVE_DATABASE_HOST
  value: "{{ .Values.database.host }}"
- name: DELVE_DATABASE_PORT
  value: "{{ .Values.database.port }}"
- name: DELVE_DATABASE_USER
  valueFrom:
    secretKeyRef:
      name: {{ .Values.database.secretName }}
      key: username
- name: DELVE_DATABASE_PASSWORD
  valueFrom:
    secretKeyRef:
      name: {{ .Values.database.secretName }}
      key: password
- name: DELVE_SERVER_PORT
  value: "{{ .Values.service.port }}"
- name: DELVE_SERVER_LOG_STDOUT
  value: "{{ .Values.logStdout | ternary "True" "False" }}"
{{- if .Values.tls.enabled }}
- name: DELVE_SSL_CERTIFICATE
  value: "{{ .Values.tls.mountPath }}/tls.crt"
- name: DELVE_SSL_PRIVATE_KEY
  value: "{{ .Values.tls.mountPath }}/tls.key"
{{- end }}
{{- if .Values.oidc.enabled }}
- name: DELVE_OIDC_ENABLED
  value: "True"
- name: DELVE_OIDC_SCOPES
  value: "{{ .Values.oidc.scopes }}"
- name: DELVE_OIDC_CA_FILE
  value: "{{ .Values.oidc.caMountPath }}/{{ .Values.oidc.caFileName }}"
- name: DELVE_OIDC_CLIENT_ID
  valueFrom:
    secretKeyRef:
      name: {{ .Values.oidc.secretName }}
      key: OIDC_CLIENT_ID
- name: DELVE_OIDC_CLIENT_SECRET
  valueFrom:
    secretKeyRef:
      name: {{ .Values.oidc.secretName }}
      key: OIDC_CLIENT_SECRET
- name: DELVE_OIDC_ISSUER_URL
  valueFrom:
    secretKeyRef:
      name: {{ .Values.oidc.secretName }}
      key: OIDC_ISSUER_URL
{{- end }}
{{- end -}}

{{/*
Volumes for the web pod: the internal TLS cert (re-encrypt) and the OIDC issuer
CA. Both are gated on their feature flags so Phase 1 renders neither.
*/}}
{{- define "delve.webVolumes" -}}
{{- if .Values.tls.enabled }}
- name: internal-tls
  secret:
    secretName: {{ .Values.tls.secretName }}
{{- end }}
{{- if .Values.oidc.enabled }}
- name: oidc-ca
  secret:
    secretName: {{ .Values.oidc.secretName }}
    items:
      - key: {{ .Values.oidc.caPemKey }}
        path: {{ .Values.oidc.caFileName }}
{{- end }}
{{- end -}}

{{/* Matching volumeMounts for the web container. */}}
{{- define "delve.webVolumeMounts" -}}
{{- if .Values.tls.enabled }}
- name: internal-tls
  mountPath: {{ .Values.tls.mountPath }}
  readOnly: true
{{- end }}
{{- if .Values.oidc.enabled }}
- name: oidc-ca
  mountPath: {{ .Values.oidc.caMountPath }}
  readOnly: true
{{- end }}
{{- end -}}
