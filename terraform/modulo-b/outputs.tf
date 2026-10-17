output "alert_policies" {
  description = "Políticas creadas: detector -> nombre del recurso."
  value = merge(
    module.data_service_anomaly.policy_names,
    var.enable_trace_enrichment ? { enriched = module.alert_enrichment[0].enriched_policy_name } : {}
  )
}

output "dashboard_url" {
  value = module.data_service_anomaly.dashboard_url
}

output "mql_queries" {
  value = module.data_service_anomaly.mql_queries
}

output "notification_channel_ids" {
  value = local.human_channel_ids
}

output "enrichment" {
  value = var.enable_trace_enrichment ? {
    topic        = module.alert_enrichment[0].topic_id
    function     = module.alert_enrichment[0].function_name
    log_name     = module.alert_enrichment[0].log_name
    ledger_log   = module.alert_enrichment[0].ledger_log_name
    log_explorer = module.alert_enrichment[0].log_explorer_url
  } : null
}
