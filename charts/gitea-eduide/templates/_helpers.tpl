{{/*
Chart name / fullname helpers.
*/}}
{{- define "gitea-eduide.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "gitea-eduide.fullname" -}}
{{- if .Values.fullnameOverride -}}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- $name := include "gitea-eduide.name" . -}}
{{- if contains $name .Release.Name -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{- define "gitea-eduide.labels" -}}
app.kubernetes.io/name: {{ include "gitea-eduide.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" }}
{{- end -}}

{{/*
Fullname of the Gitea subchart release. Replicates the official chart's
"gitea.fullname": if the release name already contains the chart name it is
used as-is, otherwise "<release>-<name>". Honors gitea.fullnameOverride /
gitea.nameOverride if the operator sets them.
*/}}
{{- define "gitea-eduide.giteaFullname" -}}
{{- if .Values.gitea.fullnameOverride -}}
{{- .Values.gitea.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- $name := default "gitea" .Values.gitea.nameOverride -}}
{{- if contains $name .Release.Name -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{/*
In-cluster HTTP address of the Gitea instance created by the subchart.
Its http Service is "<giteaFullname>-http" on gitea.service.http.port (3000).
*/}}
{{- define "gitea-eduide.giteaHttpUrl" -}}
{{- $port := 3000 -}}
{{- if and .Values.gitea.service .Values.gitea.service.http .Values.gitea.service.http.port -}}
{{- $port = .Values.gitea.service.http.port -}}
{{- end -}}
{{- printf "http://%s-http:%v" (include "gitea-eduide.giteaFullname" .) $port -}}
{{- end -}}

{{/*
ServiceAccount name used by the configure Job.
*/}}
{{- define "gitea-eduide.serviceAccountName" -}}
{{- if .Values.configure.serviceAccountName -}}
{{- .Values.configure.serviceAccountName -}}
{{- else -}}
{{- printf "%s-configure" (include "gitea-eduide.fullname" .) -}}
{{- end -}}
{{- end -}}
