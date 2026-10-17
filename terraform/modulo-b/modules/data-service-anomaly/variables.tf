variable "project_id" { type = string }
variable "namespace" { type = string }
variable "service_name" { type = string }
variable "metric_type" { type = string }
variable "excluded_routes" { type = list(string) }

variable "latency_slo_seconds" { type = number }
variable "sigma_multiplier" { type = number }
variable "baseline_window" { type = string }
variable "evaluation_window" { type = string }
variable "error_rate_floor" { type = number }
variable "min_requests" { type = number }
variable "latency_anomaly_floor_seconds" { type = number }
variable "static_error_rate_threshold" { type = number }
variable "condition_duration" { type = string }
variable "notify_single_signal_anomalies" { type = bool }

variable "notification_channel_ids" {
  description = "Canales humanos (email, Slack, ...)."
  type        = list(string)
}

variable "enrichment_channel_ids" {
  description = "Canal Pub/Sub del enriquecedor; solo lo usa la política correlacionada."
  type        = list(string)
  default     = []
}

variable "user_labels" {
  type    = map(string)
  default = {}
}
