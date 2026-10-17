output "pubsub_channel_id" {
  value = google_monitoring_notification_channel.pubsub.id
}

output "topic_id" {
  value = google_pubsub_topic.incidents.id
}

output "function_name" {
  value = google_cloudfunctions2_function.enricher.name
}

output "log_name" {
  value = local.log_name
}

output "enriched_policy_name" {
  value = google_monitoring_alert_policy.enriched.name
}

output "log_explorer_url" {
  value = "https://console.cloud.google.com/logs/query;query=${urlencode(local.log_filter)}?project=${var.project_id}"
}

output "ledger_log_name" {
  value = local.ledger_log_name
}
