"""Módulo B - noise-reduction evidence from Cloud Logging (run locally, needs gcloud).

Joins two log streams:
  * loadgen Job events (phase_start/phase_end/stats)   -> experiment timeline and ground truth
  * aiops-incident-ledger (written by the enricher)     -> every incident opened/closed per detector
and prints a Markdown report: incidents per detector, true vs false positives, MTTD, pages that
would be sent, and the noise reduction of the correlated policy vs static thresholds.

Ground truth: only phases whose name starts with "incident_" deserve a page. An incident is a true
positive if it opens between that phase start and its end + GRACE_MINUTES.

Usage: python3 scripts/modulo-b/noise_report.py [--project P] [--csv out.csv]
"""
import argparse
import csv
import json
import subprocess
from collections import defaultdict
from datetime import datetime, timedelta, timezone

GRACE_MINUTES = 5
STATIC = ("static-error", "static-latency")
ANOMALY = ("anomaly-error", "anomaly-latency")


def gcloud_logs(project, log_filter, freshness="2d"):
    out = subprocess.run(
        ["gcloud", "logging", "read", log_filter, "--project", project, "--format=json",
         f"--freshness={freshness}", "--order=asc", "--limit=20000"],
        check=True, capture_output=True, text=True).stdout
    return json.loads(out or "[]")


def ts(value):
    if isinstance(value, (int, float)):
        return datetime.fromtimestamp(value, timezone.utc)
    return datetime.fromisoformat(value.replace("Z", "+00:00"))


def load_run(project):
    base = ('resource.type="k8s_container" resource.labels.namespace_name="observability-lab" '
            'resource.labels.container_name="loadgen" ')
    events = [e["jsonPayload"] for e in gcloud_logs(project, base + 'jsonPayload.event:*')
              if "event" in e.get("jsonPayload", {})]
    starts = [i for i, e in enumerate(events) if e["event"] == "run_start"]
    if not starts:
        raise SystemExit("No loadgen run_start found in the last 2 days.")
    events = events[starts[-1]:]  # latest run only

    phases, stats = [], defaultdict(list)
    for e in events:
        if e["event"] == "phase_start":
            phases.append({"name": e["phase"], "start": ts(e["ts"]), "end": None})
        elif e["event"] == "phase_end" and phases:
            phases[-1]["end"] = ts(e["ts"])
        elif e["event"] == "stats":
            stats[e["phase"]].append(e)
    run_end = phases[-1]["end"] or datetime.now(timezone.utc)
    return ts(events[0]["ts"]), run_end, phases, stats


def load_ledger(project, run_start, run_end):
    log_filter = (f'logName="projects/{project}/logs/aiops-incident-ledger" '
                  f'timestamp>="{run_start.isoformat()}" '
                  f'timestamp<="{(run_end + timedelta(minutes=40)).isoformat()}"')
    rows = {}
    for e in gcloud_logs(project, log_filter):
        p = e.get("jsonPayload", {})
        # Skip the client library's diagnostic entry and synthetic test incidents.
        if "incident_state" not in p or str(p.get("incident_id", "")).startswith("test-"):
            continue
        row = rows.setdefault(p["incident_id"], {"incident_id": p["incident_id"], "detector": p["detector"],
                                                 "mode": p["mode"], "policy": p.get("policy_name"),
                                                 "opened": None, "closed": None})
        if p["incident_state"] == "open":
            row["opened"] = ts(p.get("started_at") or e["timestamp"])
        elif p["incident_state"] == "closed":
            row["closed"] = ts(p.get("ended_at") or e["timestamp"])
    return [r for r in rows.values() if r["opened"] and r["opened"] >= run_start]


def classify(incidents, phases):
    real = [p for p in phases if p["name"].startswith("incident_")]
    for inc in incidents:
        inc["phase"] = next((p["name"] for p in phases
                             if p["start"] <= inc["opened"] <= (p["end"] or inc["opened"])), "after_run")
        hit = next((p for p in real if p["start"] <= inc["opened"]
                    <= (p["end"] or p["start"]) + timedelta(minutes=GRACE_MINUTES)), None)
        inc["true_positive"] = hit is not None
        inc["mttd_s"] = int((inc["opened"] - hit["start"]).total_seconds()) if hit else None
    return real


def fmt(dt):
    return dt.strftime("%H:%M:%S") if dt else "—"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--project", default="crafty-dynamics-239114")
    ap.add_argument("--csv")
    args = ap.parse_args()

    run_start, run_end, phases, stats = load_run(args.project)
    incidents = load_ledger(args.project, run_start, run_end)
    real = classify(incidents, phases)

    print(f"# Módulo B — evidencia de reducción de ruido\n\nProyecto `{args.project}` · corrida "
          f"{run_start:%Y-%m-%d %H:%M}–{run_end:%H:%M} UTC · incidentes reales esperados: {len(real)}\n")

    print("## Línea de tiempo del experimento (lado cliente)\n")
    print("| Fase | Inicio | Fin | Requests | 5xx | p99 máx (s) | ¿Merece page? |\n|---|---|---|---|---|---|---|")
    for p in phases:
        s = stats.get(p["name"], [])
        p99 = max((x["p99_s"] or 0 for x in s), default=0)
        print(f"| {p['name']} | {fmt(p['start'])} | {fmt(p['end'])} | {sum(x['total'] for x in s)} | "
              f"{sum(x['err5xx'] for x in s)} | {p99:.2f} | {'**sí**' if p['name'].startswith('incident_') else 'no'} |")

    by_det = defaultdict(list)
    for inc in incidents:
        by_det[inc["detector"]].append(inc)

    print("\n## Incidentes por detector\n")
    print("| Detector | Modo | Incidentes | Verdaderos + | Falsos + (ruido) | Precisión | MTTD (s) |\n|---|---|---|---|---|---|---|")
    for det in ("static-error", "static-latency", "anomaly-error", "anomaly-latency", "correlated", "enriched"):
        rows = by_det.get(det, [])
        tp = [r for r in rows if r["true_positive"]]
        mttd = min((r["mttd_s"] for r in tp), default=None)
        prec = f"{len(tp) / len(rows):.0%}" if rows else "—"
        mode = rows[0]["mode"] if rows else "—"
        print(f"| {det} | {mode} | {len(rows)} | {len(tp)} | {len(rows) - len(tp)} | {prec} | {mttd if mttd is not None else '—'} |")

    static_pages = sum(len(by_det.get(d, [])) for d in STATIC)
    static_fp = sum(1 for d in STATIC for r in by_det.get(d, []) if not r["true_positive"])
    corr = by_det.get("correlated", [])
    corr_fp = sum(1 for r in corr if not r["true_positive"])
    reduction = (1 - len(corr) / static_pages) if static_pages else None

    print("\n## Resumen\n")
    print(f"- Pages con umbrales estáticos (error + latencia): **{static_pages}** ({static_fp} falsos positivos)")
    print(f"- Pages con la política correlacionada: **{len(corr)}** ({corr_fp} falsos positivos)")
    if reduction is not None:
        print(f"- **Reducción de alertas: {reduction:.0%}**; ruido (falsos positivos) {static_fp} → {corr_fp}")
    detected = any(r["true_positive"] for r in corr)
    print(f"- Incidente real detectado por la correlacionada: **{'sí' if detected else 'NO'}**")

    enrich = gcloud_logs(args.project, f'logName="projects/{args.project}/logs/aiops-alert-enrichment" '
                                       f'timestamp>="{run_start.isoformat()}"')
    for e in enrich:
        p = e["jsonPayload"]
        print(f"- Enriquecimiento: incidente `{p.get('incident_id')}` → **trace_id `{p.get('trace_id')}`** "
              f"(origen `{p.get('trace_source')}`, {p.get('failed_request_count')} requests fallidos) {p.get('trace_url')}")

    print("\n## Detalle de incidentes\n")
    print("| Detector | Abierto | Cerrado | Fase | ¿Real? |\n|---|---|---|---|---|")
    for inc in sorted(incidents, key=lambda r: r["opened"]):
        print(f"| {inc['detector']} | {fmt(inc['opened'])} | {fmt(inc['closed'])} | {inc['phase']} | "
              f"{'TP' if inc['true_positive'] else 'FP'} |")

    if args.csv:
        with open(args.csv, "w", newline="") as f:
            w = csv.DictWriter(f, fieldnames=["incident_id", "detector", "mode", "policy", "opened", "closed",
                                              "phase", "true_positive", "mttd_s"])
            w.writeheader()
            for inc in incidents:
                w.writerow({**inc, "opened": inc["opened"].isoformat(),
                            "closed": inc["closed"].isoformat() if inc["closed"] else ""})


if __name__ == "__main__":
    main()
