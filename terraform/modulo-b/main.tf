locals {
  name_prefix = "modulo-b"
  user_labels = {
    module  = "modulo-b"
    service = var.service_name
  }

  apis = var.enable_trace_enrichment ? [
    "monitoring.googleapis.com", "logging.googleapis.com", "cloudtrace.googleapis.com",
    "pubsub.googleapis.com", "cloudfunctions.googleapis.com", "run.googleapis.com",
    "eventarc.googleapis.com", "cloudbuild.googleapis.com", "artifactregistry.googleapis.com",
    "storage.googleapis.com",
  ] : ["monitoring.googleapis.com", "logging.googleapis.com", "cloudtrace.googleapis.com"]
}

# Never disable APIs on destroy: Módulo A depends on several of them.
resource "google_project_service" "apis" {
  for_each           = toset(local.apis)
  project            = var.project_id
  service            = each.value
  disable_on_destroy = false
}

module "notification_channels" {
  source      = "./modules/notification-channels"
  project_id  = var.project_id
  channels    = var.notification_channels
  user_labels = local.user_labels

  depends_on = [google_project_service.apis]
}

locals {
  human_channel_ids = concat(module.notification_channels.ids, var.existing_notification_channel_ids)
}

module "alert_enrichment" {
  source = "./modules/alert-enrichment"
  count  = var.enable_trace_enrichment ? 1 : 0

  project_id               = var.project_id
  region                   = var.region
  name_prefix              = local.name_prefix
  namespace                = var.namespace
  service_name             = var.service_name
  lookback_seconds         = var.enrichment_lookback_seconds
  notification_channel_ids = local.human_channel_ids
  user_labels              = local.user_labels

  depends_on = [google_project_service.apis]
}

module "data_service_anomaly" {
  source = "./modules/data-service-anomaly"

  project_id                     = var.project_id
  namespace                      = var.namespace
  service_name                   = var.service_name
  metric_type                    = var.metric_type
  excluded_routes                = var.excluded_routes
  latency_slo_seconds            = var.latency_slo_seconds
  sigma_multiplier               = var.sigma_multiplier
  baseline_window                = var.baseline_window
  baseline_offset                = var.baseline_offset
  baseline_min_requests          = var.baseline_min_requests
  evaluation_window              = var.evaluation_window
  error_rate_floor               = var.error_rate_floor
  min_requests                   = var.min_requests
  latency_anomaly_floor_seconds  = var.latency_anomaly_floor_seconds
  static_error_rate_threshold    = var.static_error_rate_threshold
  condition_duration             = var.condition_duration
  notify_single_signal_anomalies = var.notify_single_signal_anomalies
  notification_channel_ids       = local.human_channel_ids
  enrichment_channel_ids         = var.enable_trace_enrichment ? [module.alert_enrichment[0].pubsub_channel_id] : []
  user_labels                    = local.user_labels

  depends_on = [google_project_service.apis]
}
