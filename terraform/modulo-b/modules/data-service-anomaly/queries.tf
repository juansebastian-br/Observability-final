# MQL building blocks. All signals come from the standard OTel HTTP server histogram
# (http.server.request.duration, seconds) exported by the collector as a DISTRIBUTION on k8s_container.
locals {
  k     = var.sigma_multiplier
  floor = var.error_rate_floor
  slo   = var.latency_slo_seconds

  route_filter = join("", [for r in var.excluded_routes : "\n      && metric.http_route != '${r}'"])

  # Per-minute request deltas of the service, probes excluded.
  base = <<-EOT
    fetch k8s_container
    | metric '${var.metric_type}'
    | filter resource.namespace_name == '${var.namespace}'
        && metric.service_name == '${var.service_name}'${local.route_filter}
    | align delta(1m)
    | every 1m
  EOT

  # Per-minute error and total counts (r = per-minute error ratio, the series the baseline is built on).
  error_counts = <<-EOT
    ${local.base}
    | value [is_error: re_full_match(metric.http_response_status_code, '5..'), n: count_from(val())]
    | group_by [], [errors: sum(if(is_error, n, 0)), total: sum(n)]
    | value [r: cast_double(errors) / cast_double(total), errors, total]
  EOT

  # Current error rate (evaluation window) vs dynamic threshold max(baseline + k·σ, floor).
  # Baseline = mean/σ of the per-minute ratio over [t - offset - window, t - offset]:
  # - time_shift(baseline_offset) keeps an ongoing outage (up to the offset) out of its own baseline,
  #   otherwise σ grows with the anomaly and the incident closes mid-outage and re-opens (noise);
  # - minutes with fewer than baseline_min_requests are dropped (ratios of 1/2 or 2/3 blow up σ).
  error_signals = <<-EOT
    ${local.error_counts}
    | {
        group_by sliding(${var.evaluation_window}), [error_rate: sum(errors) / sum(total), requests: sum(total)]
        | every 1m
        ;
        filter total >= ${var.baseline_min_requests}
        | group_by sliding(${var.baseline_window}), [baseline: mean(r), sigma: stddev(r)]
        | time_shift ${var.baseline_offset}
        | every 1m
      }
    | join
    | value [error_rate, requests,
             error_threshold: if(baseline + ${local.k} * sigma > ${local.floor}, baseline + ${local.k} * sigma, ${local.floor})]
  EOT

  latency_p99 = <<-EOT
    ${local.base}
    | group_by [], sliding(${var.evaluation_window}), [d: aggregate(val())]
    | every 1m
    | value [latency_p99: percentile_from(d, 99)]
  EOT

  # p99 vs its own baseline (single-signal latency anomaly).
  latency_signals = <<-EOT
    ${local.latency_p99}
    | {
        value [latency_p99]
        ;
        group_by sliding(${var.baseline_window}), [p_mean: mean(latency_p99), p_sigma: stddev(latency_p99)]
        | time_shift ${var.baseline_offset}
        | every 1m
      }
    | join
    | value [latency_p99, latency_threshold: p_mean + ${local.k} * p_sigma]
  EOT

  correlated_signals = <<-EOT
    {
    ${local.error_signals}
    ;
    ${local.latency_p99}
    }
    | join
  EOT

  # --- Alert conditions --------------------------------------------------------

  q_correlated = <<-EOT
    ${local.correlated_signals}
    | condition error_rate > error_threshold
        && latency_p99 > ${local.slo} 's'
        && requests >= ${var.min_requests}
  EOT

  q_anomaly_error = <<-EOT
    ${local.error_signals}
    | condition error_rate > error_threshold && requests >= ${var.min_requests}
  EOT

  q_anomaly_latency = <<-EOT
    ${local.latency_signals}
    | condition latency_p99 > latency_threshold && latency_p99 > ${var.latency_anomaly_floor_seconds} 's'
  EOT

  q_static_error = <<-EOT
    ${local.error_counts}
    | group_by sliding(${var.evaluation_window}), [error_rate: sum(errors) / sum(total), requests: sum(total)]
    | every 1m
    | condition error_rate > ${var.static_error_rate_threshold} && requests >= ${var.min_requests}
  EOT

  q_static_latency = <<-EOT
    ${local.latency_p99}
    | condition latency_p99 > ${local.slo} 's'
  EOT
}
