# Módulo B — AIOps y detección automática de anomalías (`data-service`)

Terraform que crea, sobre la telemetría OpenTelemetry del Módulo A (sin modificarlo):

1. **Detección de anomalías** del `data-service` con umbrales dinámicos estadísticos (baseline móvil + k·σ).
2. **Política correlacionada (MQL)**: `error_rate > baseline + 2σ` **AND** `latency_p99 > SLO_threshold`.
3. **Enriquecimiento con `trace_id`** del request fallido en el payload/documentación de la notificación.
4. **Políticas shadow** (estáticas y de una sola señal) para medir la reducción de ruido en la Fase 3.

## Arquitectura

```text
data-service (OTel SDK) ──OTLP──> Collector ──googlecloud──> Cloud Monitoring  workload.googleapis.com/http.server.request.duration
                                           └──────────────> Cloud Logging     (logs con trace) / Cloud Trace

Cloud Monitoring
 ├─ [Shadow][Estática] error_rate > 1%            ─┐
 ├─ [Shadow][Estática] p99 > 1.5 s                 │ solo registran incidentes (comparación de ruido)
 ├─ [Shadow][Anomalía] error_rate > baseline+2σ    │
 ├─ [Shadow][Anomalía] p99 > baseline_p99+2σ      ─┘
 └─ [CRITICAL] correlación (MQL) ──> canales humanos (var.notification_channels)
                                 └─> Pub/Sub ──> Cloud Function "alert-enricher"
                                                   ├─ logs ERROR de data-service en la ventana → trace_id
                                                   └─ fallback: traza más lenta (Cloud Trace)
                                                 ──> log "aiops-alert-enrichment" (jsonPayload.trace_id)
                                                 ──> [CRITICAL][Enriquecida] alerta de logs ──> canales humanos
                                                     subject/documentación con ${log.extracted_label.trace_id}
```

¿Por qué un enriquecedor? Una política de métricas no puede llevar el `trace_id` sin convertirlo en etiqueta
de la métrica (cardinalidad ilimitada). El enriquecedor solo se ejecuta cuando la política correlacionada abre
un incidente, así que no agrega ruido.

## Regla de detección

Todas las señales salen del histograma estándar OTel `http.server.request.duration` (semconv estable, segundos),
filtrado por `service_name = data-service`, namespace `observability-lab`, excluyendo `/health` (probes).

| Señal | Definición MQL |
|---|---|
| `r` | error ratio por minuto: `count(status 5xx) / count(all)` con `align delta(1m)` |
| `error_rate` | `sum(errors)/sum(total)` en ventana deslizante de `evaluation_window` (5m) |
| `baseline`, `σ` | `mean(r)`, `stddev(r)` en `baseline_window` (30m) **desplazado `baseline_offset` (15m)**: ventana `[t−45m, t−15m]`. Una caída de hasta 15 min no entra en su propio baseline (si entrara, σ crecería con la anomalía y el incidente se cerraría y reabriría a mitad de la caída). Solo minutos con ≥ `baseline_min_requests` (10) requests: ratios como 1/2 o 2/3 con tráfico bajo inflan σ |
| umbral dinámico | `max(baseline + k·σ, error_rate_floor)` — el piso (5%) evita disparar con 1 error cuando σ≈0 |
| `latency_p99` | `percentile_from(aggregate(distribución), 99)` en 5m |
| condición | `error_rate > umbral && latency_p99 > 1.5 's' && requests >= 10`, sostenida `condition_duration` (60s) |

La consulta completa renderizada está en `terraform output -json mql_queries`.

> **Nota sobre MQL:** Google deprecó MQL (oct-2024) y desde jul-2025 no se pueden crear políticas MQL desde la
> consola, pero **sí vía API/Terraform** y las existentes siguen funcionando. La alternativa recomendada es PromQL
> (`condition_prometheus_query_language`); equivalente aproximado, no desplegado:
>
> ```promql
> (
>   sum(rate({"workload.googleapis.com/http.server.request.duration_count", monitored_resource="k8s_container",
>             namespace_name="observability-lab", service_name="data-service", http_route!="/health",
>             http_response_status_code=~"5.."}[5m]))
>   / sum(rate({"workload.googleapis.com/http.server.request.duration_count", monitored_resource="k8s_container",
>               namespace_name="observability-lab", service_name="data-service", http_route!="/health"}[5m]))
> ) > on() (avg_over_time(error_ratio[30m:1m] offset 5m) + 2 * stddev_over_time(error_ratio[30m:1m] offset 5m))
> and on()
> histogram_quantile(0.99, sum by (le) (rate({"workload.googleapis.com/http.server.request.duration_bucket", ...}[5m]))) > 1.5
> ```
> (`error_ratio` sería una recording rule o la subconsulta del ratio repetida.)

Cloud Monitoring no ofrece un detector ML turnkey para métricas arbitrarias; Google documenta los umbrales
dinámicos (media móvil / z-score) como el mecanismo de anomaly detection en alerting.

## Uso

```bash
cd terraform/modulo-b
cp terraform.tfvars.example terraform.tfvars   # define project_id y notification_channels
export GOOGLE_OAUTH_ACCESS_TOKEN=$(gcloud auth print-access-token)   # o: gcloud auth application-default login
terraform init
terraform plan -out=b.tfplan
terraform apply b.tfplan
terraform output
```

### Canales de notificación (propiedad configurable)

`notification_channels` en `terraform.tfvars` (no versionado). Cualquier tipo soportado por Cloud Monitoring:

```hcl
notification_channels = {
  oncall_email = { type = "email", labels = { email_address = "sre@example.com" } }
  webhook      = { type = "webhook_tokenauth", labels = { url = "https://example.com/hook" } }
}
existing_notification_channel_ids = []   # o reutilizar canales existentes
```

Cambiar el destinatario = editar la propiedad y `terraform apply`; los módulos no cambian.

### Parámetros principales

| Variable | Default | Uso |
|---|---|---|
| `latency_slo_seconds` | `1.5` | SLO_threshold de p99 |
| `sigma_multiplier` | `2` | k de baseline + k·σ |
| `baseline_window` / `baseline_offset` / `evaluation_window` | `30m` / `15m` / `5m` | ventana y desplazamiento del baseline; ventana de la señal actual |
| `baseline_min_requests` | `10` | minutos con menos requests no entran al baseline |
| `error_rate_floor` | `0.05` | piso del umbral dinámico |
| `min_requests` | `10` | volumen mínimo para evaluar |
| `static_error_rate_threshold` | `0.01` | umbral de la política estática de comparación |
| `notify_single_signal_anomalies` | `false` | `true` para que los detectores de una señal también notifiquen |
| `enable_trace_enrichment` | `true` | despliega Pub/Sub + función + alerta enriquecida |

## Recursos y costes

5 políticas MQL + 1 de logs, 1 dashboard, 1 topic Pub/Sub, 1 Cloud Function gen2 (escala a 0), 1 bucket,
2 service accounts e IAM aditivo (`google_project_iam_member`). Las APIs se habilitan con
`disable_on_destroy = false`: `terraform destroy` no apaga APIs que usa el Módulo A. Coste esperado en el lab:
centavos/mes (alerting por series temporales + invocaciones de la función).
