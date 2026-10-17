locals {
  logs_filter = join("\n", [
    "resource.type=\"k8s_container\"",
    "resource.labels.namespace_name=\"${var.namespace}\"",
    "resource.labels.container_name=\"${var.service_name}\"",
    "severity>=ERROR",
  ])
  logs_url   = "https://console.cloud.google.com/logs/query;query=${urlencode(local.logs_filter)};duration=PT1H?project=${var.project_id}"
  traces_url = "https://console.cloud.google.com/traces/explorer?project=${var.project_id}"

  rule_text = "error_rate(${var.evaluation_window}) > max(baseline_${var.baseline_window} + ${local.k}σ, ${local.floor * 100}%) AND latency_p99(${var.evaluation_window}) > ${local.slo}s AND requests >= ${var.min_requests}"

  # Single-signal detectors: shadow (no channels) unless explicitly enabled.
  single_signal_channels = var.notify_single_signal_anomalies ? var.notification_channel_ids : []

  policies = {
    correlated = {
      display_name = "[Modulo B][CRITICAL] ${var.service_name}: error rate anómalo + p99 > SLO (correlación)"
      condition    = "error_rate > baseline+${local.k}σ AND latency_p99 > ${local.slo}s"
      severity     = "CRITICAL"
      mode         = "active"
      query        = local.q_correlated
      channels     = concat(var.notification_channel_ids, var.enrichment_channel_ids)
      doc          = <<-EOT
        ## AIOps · ${var.service_name}: degradación correlacionada

        **Regla:** `${local.rule_text}`

        Ambas señales (errores fuera de su comportamiento normal **y** latencia por encima del SLO) se cumplen a la vez
        durante ${var.condition_duration}. Un pico aislado de una sola señal no abre este incidente.

        **trace_id del request fallido:** llega en la notificación *[Enriquecida]* que el enriquecedor envía segundos
        después (busca en los logs ERROR de `${var.service_name}` y, si no hay, la traza más lenta de la ventana).

        **Primeros pasos**
        1. Logs de error del servicio (con trace): ${local.logs_url}
        2. Trazas (Cloud Trace Explorer, filtrar `service.name:${var.service_name}`): ${local.traces_url}
        3. Revisar spans `data.db.healthcheck` / `SELECT postgres`: ¿Cloud SQL o RDS lento/inaccesible?
        4. `kubectl -n ${var.namespace} logs deploy/${var.service_name} -c ${var.service_name} --tail=100`

        Proyecto: $${project} · Política: $${policy.display_name}
      EOT
    }

    anomaly-error = {
      display_name = "[Modulo B][Shadow][Anomalía] ${var.service_name}: error rate > baseline+${local.k}σ"
      condition    = "error_rate > baseline+${local.k}σ"
      severity     = "WARNING"
      mode         = var.notify_single_signal_anomalies ? "active" : "shadow"
      query        = local.q_anomaly_error
      channels     = local.single_signal_channels
      doc          = "Detector de anomalía (una sola señal) del error rate de ${var.service_name}: `error_rate(${var.evaluation_window}) > max(baseline_${var.baseline_window} + ${local.k}σ, ${local.floor * 100}%)`. Modo shadow: registra incidentes para comparar ruido, no notifica."
    }

    anomaly-latency = {
      display_name = "[Modulo B][Shadow][Anomalía] ${var.service_name}: p99 > baseline+${local.k}σ"
      condition    = "latency_p99 > baseline_p99+${local.k}σ"
      severity     = "WARNING"
      mode         = var.notify_single_signal_anomalies ? "active" : "shadow"
      query        = local.q_anomaly_latency
      channels     = local.single_signal_channels
      doc          = "Detector de anomalía (una sola señal) de la latencia p99 de ${var.service_name} contra su propio baseline de ${var.baseline_window} (+${local.k}σ, piso ${var.latency_anomaly_floor_seconds}s). Modo shadow."
    }

    static-error = {
      display_name = "[Modulo B][Shadow][Estática] ${var.service_name}: error rate > ${var.static_error_rate_threshold * 100}%"
      condition    = "error_rate > ${var.static_error_rate_threshold * 100}% (umbral fijo)"
      severity     = "WARNING"
      mode         = "shadow"
      query        = local.q_static_error
      channels     = []
      doc          = "Línea base de comparación: alerta tradicional de umbral estático. No notifica; existe para medir cuántos incidentes generaría frente a la política correlacionada."
    }

    static-latency = {
      display_name = "[Modulo B][Shadow][Estática] ${var.service_name}: p99 > ${local.slo}s"
      condition    = "latency_p99 > ${local.slo}s (umbral fijo)"
      severity     = "WARNING"
      mode         = "shadow"
      query        = local.q_static_latency
      channels     = []
      doc          = "Línea base de comparación: alerta tradicional de latencia p99 sobre el SLO. No notifica."
    }
  }
}

resource "google_monitoring_alert_policy" "this" {
  for_each = local.policies

  project      = var.project_id
  display_name = each.value.display_name
  combiner     = "OR"
  severity     = each.value.severity
  enabled      = true

  conditions {
    display_name = each.value.condition
    condition_monitoring_query_language {
      query                   = each.value.query
      duration                = var.condition_duration
      evaluation_missing_data = "EVALUATION_MISSING_DATA_INACTIVE"
      trigger {
        count = 1
      }
    }
  }

  alert_strategy {
    auto_close = "1800s"
  }

  documentation {
    mime_type = "text/markdown"
    subject   = each.value.display_name
    content   = each.value.doc
  }

  notification_channels = each.value.channels

  # Labels let Phase 3 count incidents per detector (static vs anomaly vs correlated).
  user_labels = merge(var.user_labels, {
    detector = each.key
    mode     = each.value.mode
  })
}

# --- Dashboard: signals and thresholds side by side ------------------------------

locals {
  correlated_active = <<-EOT
    ${local.correlated_signals}
    | value [correlated_active: if(error_rate > error_threshold && latency_p99 > ${local.slo} 's' && requests >= ${var.min_requests}, 1, 0)]
  EOT

  dashboard_tiles = [
    {
      title = "Error rate (${var.evaluation_window}) vs umbral dinámico max(baseline+${local.k}σ, ${local.floor * 100}%)"
      sets = [
        { name = "error_rate", query = "${local.error_signals}| value [error_rate]" },
        { name = "umbral dinámico", query = "${local.error_signals}| value [error_threshold]" },
      ]
      thresholds = [{ value = var.static_error_rate_threshold, label = "umbral estático" }]
    },
    {
      title      = "Latencia p99 (${var.evaluation_window}) vs SLO ${local.slo}s"
      sets       = [{ name = "p99", query = local.latency_p99 }]
      thresholds = [{ value = local.slo, label = "SLO" }]
    },
    {
      title      = "Condición correlacionada activa (1 = sí)"
      sets       = [{ name = "correlated", query = local.correlated_active }]
      thresholds = []
    },
    {
      title      = "Requests en la ventana (${var.evaluation_window})"
      sets       = [{ name = "requests", query = "${local.error_signals}| value [requests]" }]
      thresholds = [{ value = var.min_requests, label = "mínimo estadístico" }]
    },
  ]
}

resource "google_monitoring_dashboard" "this" {
  project = var.project_id
  dashboard_json = jsonencode({
    displayName = "[Modulo B] AIOps ${var.service_name}"
    mosaicLayout = {
      columns = 12
      tiles = [for i, t in local.dashboard_tiles : {
        xPos   = (i % 2) * 6
        yPos   = floor(i / 2) * 4
        width  = 6
        height = 4
        widget = {
          title = t.title
          xyChart = {
            dataSets = [for s in t.sets : {
              legendTemplate  = s.name
              plotType        = "LINE"
              targetAxis      = "Y1"
              timeSeriesQuery = { timeSeriesQueryLanguage = s.query }
            }]
            thresholds = [for th in t.thresholds : {
              value      = th.value
              label      = th.label
              targetAxis = "Y1"
            }]
            yAxis = { scale = "LINEAR" }
          }
        }
      }]
    }
  })
}
