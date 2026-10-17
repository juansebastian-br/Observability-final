variable "project_id" { type = string }
variable "region" { type = string }
variable "name_prefix" { type = string }
variable "namespace" { type = string }
variable "service_name" { type = string }

variable "lookback_seconds" {
  type    = number
  default = 600
}

variable "max_traces" {
  description = "Cuántos trace_id incluir en el payload enriquecido."
  type        = number
  default     = 3
}

variable "notification_channel_ids" {
  description = "Canales humanos que reciben la notificación enriquecida."
  type        = list(string)
}

variable "user_labels" {
  type    = map(string)
  default = {}
}
