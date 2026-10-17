# Correlated incident -> Pub/Sub -> Cloud Function (finds trace_id of the failed request) ->
# structured log entry -> log-based alert whose payload/documentation carries the trace_id.
# The log-based alert only fires when the correlated policy opens an incident, so it adds no noise.

data "google_project" "this" {
  project_id = var.project_id
}

locals {
  log_name         = "aiops-alert-enrichment"
  monitoring_agent = "serviceAccount:service-${data.google_project.this.number}@gcp-sa-monitoring-notification.iam.gserviceaccount.com"
  pubsub_agent     = "serviceAccount:service-${data.google_project.this.number}@gcp-sa-pubsub.iam.gserviceaccount.com"
  log_filter       = "logName=\"projects/${var.project_id}/logs/${local.log_name}\" AND jsonPayload.incident_state=\"open\""
}

# --- Incident fan-out ------------------------------------------------------------

resource "google_pubsub_topic" "incidents" {
  project = var.project_id
  name    = "${var.name_prefix}-incidents"
  labels  = var.user_labels
}

resource "google_monitoring_notification_channel" "pubsub" {
  project      = var.project_id
  type         = "pubsub"
  display_name = "[Modulo B] Enriquecedor de alertas (Pub/Sub)"
  labels       = { topic = google_pubsub_topic.incidents.id }
  user_labels  = var.user_labels
}

# The monitoring notification agent exists once a pubsub channel exists.
resource "google_pubsub_topic_iam_member" "monitoring_publisher" {
  project = var.project_id
  topic   = google_pubsub_topic.incidents.name
  role    = "roles/pubsub.publisher"
  member  = local.monitoring_agent

  depends_on = [google_monitoring_notification_channel.pubsub]
}

# --- Identities ----------------------------------------------------------------

resource "google_service_account" "enricher" {
  project      = var.project_id
  account_id   = "${var.name_prefix}-enricher"
  display_name = "Modulo B - alert enricher runtime"
}

resource "google_service_account" "builder" {
  project      = var.project_id
  account_id   = "${var.name_prefix}-fn-builder"
  display_name = "Modulo B - Cloud Functions build"
}

resource "google_project_iam_member" "enricher" {
  for_each = toset([
    "roles/logging.viewer",    # read data-service error logs
    "roles/logging.logWriter", # write the enrichment entry
    "roles/cloudtrace.user",   # fallback: slowest trace in the window
    "roles/run.invoker",       # Eventarc -> function
    "roles/eventarc.eventReceiver",
  ])
  project = var.project_id
  role    = each.value
  member  = "serviceAccount:${google_service_account.enricher.email}"
}

resource "google_project_iam_member" "builder" {
  for_each = toset([
    "roles/cloudbuild.builds.builder",
    "roles/logging.logWriter",
    "roles/artifactregistry.writer",
    "roles/storage.objectViewer",
  ])
  project = var.project_id
  role    = each.value
  member  = "serviceAccount:${google_service_account.builder.email}"
}

# Projects created before 2021 need this for Pub/Sub-triggered Eventarc (push auth tokens).
resource "google_project_iam_member" "pubsub_token_creator" {
  project = var.project_id
  role    = "roles/iam.serviceAccountTokenCreator"
  member  = local.pubsub_agent
}

# --- Function ------------------------------------------------------------------

resource "google_storage_bucket" "source" {
  project                     = var.project_id
  name                        = "${var.project_id}-${var.name_prefix}-fn-src"
  location                    = var.region
  uniform_bucket_level_access = true
  force_destroy               = true
  labels                      = var.user_labels
}

data "archive_file" "enricher" {
  type        = "zip"
  source_dir  = "${path.module}/function"
  output_path = "${path.root}/.build/enricher.zip"
  excludes    = ["__pycache__"]
}

resource "google_storage_bucket_object" "enricher" {
  name   = "enricher-${data.archive_file.enricher.output_md5}.zip"
  bucket = google_storage_bucket.source.name
  source = data.archive_file.enricher.output_path
}

resource "google_cloudfunctions2_function" "enricher" {
  project  = var.project_id
  location = var.region
  name     = "${var.name_prefix}-alert-enricher"
  labels   = var.user_labels

  build_config {
    runtime         = "python312"
    entry_point     = "enrich"
    service_account = google_service_account.builder.id
    source {
      storage_source {
        bucket = google_storage_bucket.source.name
        object = google_storage_bucket_object.enricher.name
      }
    }
  }

  service_config {
    min_instance_count             = 0
    max_instance_count             = 2
    available_memory               = "256M"
    timeout_seconds                = 60
    ingress_settings               = "ALLOW_INTERNAL_ONLY"
    all_traffic_on_latest_revision = true
    service_account_email          = google_service_account.enricher.email
    environment_variables = {
      PROJECT_ID          = var.project_id
      NAMESPACE           = var.namespace
      SERVICE_NAME        = var.service_name
      ENRICHMENT_LOG_NAME = local.log_name
      LOOKBACK_SECONDS    = tostring(var.lookback_seconds)
      MAX_TRACES          = tostring(var.max_traces)
    }
  }

  event_trigger {
    trigger_region        = var.region
    event_type            = "google.cloud.pubsub.topic.v1.messagePublished"
    pubsub_topic          = google_pubsub_topic.incidents.id
    retry_policy          = "RETRY_POLICY_DO_NOT_RETRY"
    service_account_email = google_service_account.enricher.email
  }

  depends_on = [google_project_iam_member.builder, google_project_iam_member.enricher]
}

# --- Enriched notification -----------------------------------------------------

resource "google_monitoring_alert_policy" "enriched" {
  project      = var.project_id
  display_name = "[Modulo B][CRITICAL][Enriquecida] ${var.service_name}: incidente correlacionado + trace_id"
  combiner     = "OR"
  severity     = "CRITICAL"

  conditions {
    display_name = "Incidente correlacionado enriquecido con trace_id"
    condition_matched_log {
      filter = local.log_filter
      label_extractors = {
        trace_id     = "EXTRACT(jsonPayload.trace_id)"
        trace_source = "EXTRACT(jsonPayload.trace_source)"
        incident_id  = "EXTRACT(jsonPayload.incident_id)"
        error_count  = "EXTRACT(jsonPayload.failed_request_count)"
      }
    }
  }

  alert_strategy {
    notification_rate_limit {
      period = "300s"
    }
    auto_close = "1800s"
  }

  documentation {
    mime_type = "text/markdown"
    subject   = "[Modulo B][Enriquecida] ${var.service_name} trace_id=$${log.extracted_label.trace_id}"
    content   = <<-EOT
      ## AIOps · ${var.service_name}: incidente correlacionado (enriquecido)

      | Campo | Valor |
      |---|---|
      | **trace_id** | `$${log.extracted_label.trace_id}` |
      | Origen del trace | $${log.extracted_label.trace_source} |
      | Requests fallidos encontrados | $${log.extracted_label.error_count} |
      | Incidente origen | $${log.extracted_label.incident_id} |

      **Abrir la traza:** https://console.cloud.google.com/traces/explorer;traceId=$${log.extracted_label.trace_id}?project=${var.project_id}

      **Logs de esa traza:** https://console.cloud.google.com/logs/query;query=trace%3D%22projects%2F${var.project_id}%2Ftraces%2F$${log.extracted_label.trace_id}%22?project=${var.project_id}

      `trace_source = error_logs`: trace del último request con log ERROR de ${var.service_name}.
      `trace_source = slowest_trace`: no hubo logs de error en la ventana; es la traza más lenta del servicio.
    EOT
  }

  notification_channels = var.notification_channel_ids
  user_labels           = merge(var.user_labels, { detector = "enriched", mode = "active" })
}
