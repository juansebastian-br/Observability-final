# Módulo B — Fase 3: carga, caos y evidencia de reducción de ruido

## Experimento

`chaos_loadgen.py` corre como Job en el clúster (`run-chaos.sh`), fuera del mesh, y golpea
`http://data-service:8002/data/health` (consulta Cloud SQL + RDS). El caos es **real y sin cambios de código**:
una `NetworkPolicy` bloquea el egress de `data-service` hacia la IP de RDS (Dataplane V2 la aplica al instante).
Las métricas OTel de `data-service` registran los 5xx y la latencia tal como los vive el servicio.

| Fase (default) | Min | Qué inyecta | Qué debería pasar |
|---|---|---|---|
| `baseline` | 35 | 2 rps normales | construye baseline (30m) + σ |
| `noise_load_spike` | 5 | +48 clientes concurrentes | p99 > SLO **sin errores** → solo alertas de latencia |
| `recovery_1` | 10 | normal | cierre de incidentes |
| `noise_micro_outages` | 6 | RDS bloqueado 8 s cada 90 s | ~2% de 5xx + picos de latencia → estáticas disparan, correlacionada no (piso 5%) |
| `recovery_2` | 10 | normal | |
| `incident_rds_outage` | 8 | RDS bloqueado continuo | ~100% 503 + p99 > 5 s → **correlacionada dispara + email enriquecido con trace_id** |
| `recovery_final` | 10 | normal | cierre de incidentes |

Calibración (17-oct-2026): baseline p99 ≈ 0.25 s; con RDS bloqueado las conexiones nuevas fallan en ~5–15 s
(`connect_timeout=5`) con 503; 48 clientes saturan el pool (~29 rps) y llevan el p99 sobre 1.5 s sin errores.

```bash
export KUBECONFIG=...            # clúster otel-lab
scripts/modulo-b/run-chaos.sh    # ~84 min
kubectl -n observability-lab logs -f job/modulo-b-chaos | grep -E 'phase_|chaos_|run_summary'
scripts/modulo-b/run-chaos.sh --stop      # aborta (borra la NetworkPolicy)
scripts/modulo-b/run-chaos.sh --cleanup   # borra Job, ConfigMap, RBAC
```

Fases propias: `run-chaos.sh phases.json` con una lista JSON como `DEFAULT_PHASES`.

## Evidencia

```bash
python3 scripts/modulo-b/noise_report.py --csv /tmp/incidentes.csv   # Markdown para el reporte
```

Cruza la línea de tiempo del Job (logs `jsonPayload.event`) con el **ledger de incidentes**
(log `aiops-incident-ledger`, escrito por la Cloud Function para cada open/close de *todas* las políticas,
incluidas las shadow).

## Cómo extraer la evidencia en GCP

Las políticas estáticas y de una sola señal corren en **modo shadow**: evalúan los mismos datos que la
correlacionada y abren incidentes, pero no notifican. Cada incidente que abren es un *page* que habría recibido
el on-call con un sistema de umbrales estáticos. Así la comparación es sobre el mismo tráfico y la misma ventana.

**1. Ledger de incidentes (fuente principal).** Cloud Monitoring no expone una API pública para listar
incidentes; por eso todas las políticas notifican también al canal Pub/Sub y la función registra cada evento.

Logs Explorer:
```
logName="projects/crafty-dynamics-239114/logs/aiops-incident-ledger"
jsonPayload.incident_state="open"
```
CLI (conteo por detector durante la corrida):
```bash
gcloud logging read 'logName="projects/crafty-dynamics-239114/logs/aiops-incident-ledger"
  AND jsonPayload.incident_state="open" AND timestamp>="<inicio corrida>"' \
  --project crafty-dynamics-239114 --format='value(jsonPayload.detector)' | sort | uniq -c
```
Log Analytics (si el bucket `_Default` tiene Log Analytics habilitado):
```sql
SELECT JSON_VALUE(json_payload.detector) AS detector,
       COUNTIF(JSON_VALUE(json_payload.incident_state) = 'open') AS incidentes
FROM `crafty-dynamics-239114.global._Default._AllLogs`
WHERE log_id = 'aiops-incident-ledger' AND timestamp >= TIMESTAMP('<inicio corrida>')
GROUP BY detector ORDER BY incidentes DESC
```

**2. Notificación enriquecida con `trace_id`.**
```
logName="projects/crafty-dynamics-239114/logs/aiops-alert-enrichment"
```
`jsonPayload.trace_id` / `trace_url` → abrir en Cloud Trace: la traza muestra `GET /data/health` → span
`data.db.healthcheck` hacia RDS con la excepción y `db.system.name`, `server.address`. El email
"[Enriquecida]" trae el mismo `trace_id` en el asunto.

**3. Señales y umbrales (gráficas).** Dashboard `[Modulo B] AIOps data-service` (`terraform output dashboard_url`):
error rate vs umbral dinámico (con la línea del umbral estático 1%), p99 vs SLO, condición correlacionada
activa (0/1) y volumen. Captura la ventana de la corrida. Las consultas exactas: `terraform output -json mql_queries`
(MQL ya no se puede crear desde la consola en charts nuevos, pero el dashboard creado vía API sí las muestra).

**4. Incidentes en la consola.** Monitoring → Alerting → Incidents, filtrando por política `[Modulo B]`:
muestra apertura/cierre de cada incidente (útil como captura complementaria al ledger).

**5. Lado cliente (ground truth).** Logs del Job:
```
resource.type="k8s_container" resource.labels.container_name="loadgen" jsonPayload.event="stats"
```
`error_ratio`, `p99_s` y `rds_blocked` cada 10 s, por fase.

**Métricas para el reporte** (las calcula `noise_report.py`):
- *Reducción de alertas* = 1 − pages(correlacionada) / pages(estáticas).
- *Falsos positivos* = incidentes abiertos fuera de la fase `incident_*` (+5 min de gracia).
- *Precisión* = verdaderos / total por detector.
- *MTTD* = apertura del incidente − inicio de la falla (costo en tiempo de detección de la correlación).
