{{/* Name of the Secret that holds the database credentials. */}}
{{- define "csat.dbSecretName" -}}
{{- default "csat-db" .Values.mysql.existingSecret -}}
{{- end -}}
