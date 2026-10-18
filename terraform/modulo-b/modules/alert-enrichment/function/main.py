"""AIOps alert enricher and incident ledger.

Triggered by the Cloud Monitoring Pub/Sub channel attached to every Módulo B policy.
- Ledger: every open/close is written to the `aiops-incident-ledger` log (noise measurement).
- Enrichment: for incidents opened by the correlated policy it finds the trace_id of the failed
  request(s) and writes a structured log entry that a log-based alert turns into the enriched
  notification.

Trace lookup order:
1. ERROR logs of the service in the incident window (OTel logs carry the active trace context).
2. Fallback: slowest trace of the service in Cloud Trace for the same window.
"""
import base64
import json
import os
import time
from datetime import datetime, timezone

import functions_framework
import google.auth
from google.auth.transport.requests import AuthorizedSession
from google.cloud import logging as cloud_logging

PROJECT_ID = os.environ["PROJECT_ID"]
NAMESPACE = os.getenv("NAMESPACE", "observability-lab")
SERVICE_NAME = os.getenv("SERVICE_NAME", "data-service")
LOG_NAME = os.getenv("ENRICHMENT_LOG_NAME", "aiops-alert-enrichment")
LEDGER_LOG_NAME = os.getenv("LEDGER_LOG_NAME", "aiops-incident-ledger")
LOOKBACK_SECONDS = int(os.getenv("LOOKBACK_SECONDS", "600"))
MAX_TRACES = int(os.getenv("MAX_TRACES", "3"))

logging_client = cloud_logging.Client(project=PROJECT_ID)
credentials, _ = google.auth.default(scopes=["https://www.googleapis.com/auth/cloud-platform"])
session = AuthorizedSession(credentials)


def rfc3339(epoch):
    return datetime.fromtimestamp(epoch, timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def traces_from_error_logs(start, end):
    log_filter = (
        f'resource.type="k8s_container" '
        f'resource.labels.namespace_name="{NAMESPACE}" '
        f'resource.labels.container_name="{SERVICE_NAME}" '
        f'severity>=ERROR trace:* '
        f'timestamp>="{rfc3339(start)}" timestamp<="{rfc3339(end)}"'
    )
    trace_ids, errors = [], 0
    for entry in logging_client.list_entries(
        filter_=log_filter, order_by=cloud_logging.DESCENDING, page_size=100, max_results=100
    ):
        errors += 1
        trace_id = (entry.trace or "").rsplit("/", 1)[-1]
        if trace_id and trace_id not in trace_ids and len(trace_ids) < MAX_TRACES:
            trace_ids.append(trace_id)
    return trace_ids, errors


def slowest_traces(start, end):
    response = session.get(
        f"https://cloudtrace.googleapis.com/v1/projects/{PROJECT_ID}/traces",
        params={
            "startTime": rfc3339(start),
            "endTime": rfc3339(end),
            "filter": f"service.name:{SERVICE_NAME}",
            "orderBy": "duration desc",
            "pageSize": MAX_TRACES,
            "view": "MINIMAL",
        },
        timeout=15,
    )
    response.raise_for_status()
    return [t["traceId"] for t in response.json().get("traces", [])]


def detector_of(incident):
    """Detector/mode from the policy user labels set by Terraform (detector=correlated|static-error|...)."""
    labels = incident.get("policy_user_labels") or {}
    if "detector" in labels:
        return labels["detector"], labels.get("mode", "unknown")
    name = (incident.get("policy_name") or "").lower()
    for marker, detector in (("enriquecida", "enriched"), ("correlación", "correlated"),
                             ("estática", "static"), ("anomalía", "anomaly")):
        if marker in name:
            return detector, "unknown"
    return "unknown", "unknown"


def record_in_ledger(incident, state, detector, mode):
    """Incident ledger: one entry per open/close of every Módulo B policy (active and shadow)."""
    logging_client.logger(LEDGER_LOG_NAME).log_struct(
        {
            "message": f"[AIOps ledger] {detector} {state}: {incident.get('policy_name')}",
            "incident_id": incident.get("incident_id"),
            "incident_state": state,
            "detector": detector,
            "mode": mode,
            "policy_name": incident.get("policy_name"),
            "condition_name": incident.get("condition_name"),
            "started_at": incident.get("started_at"),
            "ended_at": incident.get("ended_at"),
            "observed_value": incident.get("observed_value"),
            "service": SERVICE_NAME,
        },
        severity="INFO",
        labels={"module": "modulo-b", "detector": detector, "mode": mode},
    )


@functions_framework.cloud_event
def enrich(cloud_event):
    message = json.loads(base64.b64decode(cloud_event.data["message"]["data"]))
    incident = message.get("incident", {})
    state = incident.get("state", "unknown")
    detector, mode = detector_of(incident)
    record_in_ledger(incident, state, detector, mode)

    # Only the correlated policy is enriched. The enriched policy also publishes here: enriching it
    # would loop (enrichment log -> enriched alert -> enrichment log ...).
    if state != "open" or detector != "correlated":
        return

    end = int(time.time())
    start = int(incident.get("started_at") or end) - LOOKBACK_SECONDS

    trace_ids, failed = traces_from_error_logs(start, end)
    source = "error_logs"
    if not trace_ids:
        try:
            trace_ids, source = slowest_traces(start, end), "slowest_trace"
        except Exception as exc:  # enrichment must never swallow the incident
            print(json.dumps({"message": "cloud trace lookup failed", "error": str(exc)}))
    if not trace_ids:
        source = "none"

    trace_id = trace_ids[0] if trace_ids else "not-found"
    payload = {
        "message": f"[AIOps] {SERVICE_NAME} incidente correlacionado - trace_id={trace_id}",
        "incident_state": state,
        "incident_id": incident.get("incident_id"),
        "incident_url": incident.get("url"),
        "policy_name": incident.get("policy_name"),
        "condition_name": incident.get("condition_name"),
        "service": SERVICE_NAME,
        "trace_id": trace_id,
        "trace_ids": trace_ids,
        "trace_source": source,
        "failed_request_count": failed,
        "window_start": rfc3339(start),
        "window_end": rfc3339(end),
        "trace_url": (f"https://console.cloud.google.com/traces/explorer;traceId={trace_id}"
                      f"?project={PROJECT_ID}") if trace_ids else None,
    }
    logging_client.logger(LOG_NAME).log_struct(
        payload,
        severity="ERROR",
        trace=f"projects/{PROJECT_ID}/traces/{trace_id}" if trace_ids else None,
        labels={"module": "modulo-b", "service": SERVICE_NAME},
    )
    print(json.dumps({"message": "incident enriched", "incident_id": payload["incident_id"],
                      "trace_id": trace_id, "trace_source": source}))
