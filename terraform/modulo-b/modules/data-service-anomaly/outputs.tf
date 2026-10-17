output "policy_names" {
  value = { for k, p in google_monitoring_alert_policy.this : k => p.name }
}

output "mql_queries" {
  description = "Consultas MQL renderizadas (condiciones y señales), para depurar o graficar en Metrics Explorer."
  value = merge(
    { for k, p in local.policies : "condition_${k}" => p.query },
    {
      signals_error      = local.error_signals
      signals_latency    = local.latency_signals
      signals_correlated = local.correlated_active
    }
  )
}

output "correlated_policy_name" {
  value = google_monitoring_alert_policy.this["correlated"].name
}

output "dashboard_url" {
  value = "https://console.cloud.google.com/monitoring/dashboards/builder/${element(split("/", google_monitoring_dashboard.this.id), 3)}?project=${var.project_id}"
}
