variable "project_id" {
  type = string
}

variable "channels" {
  description = "Mapa clave -> {type, display_name, labels} de canales a crear."
  type = map(object({
    type         = string
    display_name = optional(string)
    labels       = map(string)
  }))
}

variable "user_labels" {
  type    = map(string)
  default = {}
}

resource "google_monitoring_notification_channel" "this" {
  for_each = var.channels

  project      = var.project_id
  type         = each.value.type
  display_name = coalesce(each.value.display_name, "[Modulo B] ${each.key}")
  labels       = each.value.labels
  user_labels  = var.user_labels
}

output "ids" {
  value = [for c in google_monitoring_notification_channel.this : c.id]
}
