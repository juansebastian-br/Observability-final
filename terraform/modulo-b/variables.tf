variable "project_id" {
  description = "Proyecto GCP donde corre el Módulo A (clúster otel-lab)."
  type        = string
}

variable "region" {
  description = "Región para la Cloud Function de enriquecimiento y su bucket."
  type        = string
  default     = "us-central1"
}

# --- Servicio observado -------------------------------------------------------

variable "namespace" {
  description = "Namespace de Kubernetes del servicio (resource.namespace_name en k8s_container)."
  type        = string
  default     = "observability-lab"
}

variable "service_name" {
  description = "service.name de OpenTelemetry del servicio observado."
  type        = string
  default     = "data-service"
}

variable "metric_type" {
  description = "Histograma HTTP server estándar de OTel exportado por el collector (semconv estable, en segundos)."
  type        = string
  default     = "workload.googleapis.com/http.server.request.duration"
}

variable "excluded_routes" {
  description = "Rutas excluidas del cálculo (probes de Kubernetes que diluyen error rate y p99)."
  type        = list(string)
  default     = ["/health"]
}

# --- Reglas de detección --------------------------------------------------------

variable "latency_slo_seconds" {
  description = "SLO de latencia p99 del servicio (SLO_threshold)."
  type        = number
  default     = 1.5
}

variable "sigma_multiplier" {
  description = "k en baseline + k·σ."
  type        = number
  default     = 2
}

variable "baseline_window" {
  description = "Ventana móvil para calcular baseline (media) y σ del error rate. Duración MQL (p. ej. 30m, 1h)."
  type        = string
  default     = "30m"
}

variable "evaluation_window" {
  description = "Ventana de la señal actual (error rate y p99). El baseline se desplaza esta misma duración para no incluir la señal actual."
  type        = string
  default     = "5m"
}

variable "error_rate_floor" {
  description = "Piso absoluto del umbral dinámico: evita alertar por 1 error cuando σ≈0 (baseline estable en 0%)."
  type        = number
  default     = 0.05
}

variable "min_requests" {
  description = "Mínimo de requests en la ventana de evaluación para considerar la señal estadísticamente válida."
  type        = number
  default     = 10
}

variable "latency_anomaly_floor_seconds" {
  description = "Piso del detector de anomalía de latencia (solo señal), para ignorar desviaciones sobre latencias triviales."
  type        = number
  default     = 0.5
}

variable "static_error_rate_threshold" {
  description = "Umbral fijo de la política estática de comparación (shadow), estilo alerta tradicional."
  type        = number
  default     = 0.01
}

variable "condition_duration" {
  description = "Tiempo que la condición debe sostenerse antes de abrir incidente (igual para todas las políticas, para comparar en igualdad)."
  type        = string
  default     = "60s"
}

variable "notify_single_signal_anomalies" {
  description = "Si true, los detectores de anomalía de una sola señal también notifican. Por defecto quedan en modo shadow."
  type        = bool
  default     = false
}

# --- Notificación ---------------------------------------------------------------

variable "notification_channels" {
  description = <<-EOT
    Canales a crear, como propiedad configurable (terraform.tfvars). Clave = identificador lógico.
    Ejemplos de type/labels: email {email_address}, slack {channel_name} + auth_token vía sensitive_labels,
    webhook_tokenauth {url}. Ver terraform.tfvars.example.
  EOT
  type = map(object({
    type         = string
    display_name = optional(string)
    labels       = map(string)
  }))
  default = {}
}

variable "existing_notification_channel_ids" {
  description = "IDs de canales ya existentes (projects/<p>/notificationChannels/<id>) para reutilizar."
  type        = list(string)
  default     = []
}

# --- Enriquecimiento con trace_id ---------------------------------------------

variable "enable_trace_enrichment" {
  description = "Despliega el pipeline Pub/Sub + Cloud Function + alerta de logs que adjunta el trace_id."
  type        = bool
  default     = true
}

variable "enrichment_lookback_seconds" {
  description = "Cuánto antes del inicio del incidente se buscan requests fallidos."
  type        = number
  default     = 600
}
