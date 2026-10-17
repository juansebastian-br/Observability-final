"""Módulo B - load + chaos generator for data-service (runs as a Kubernetes Job, stdlib only).

Phases (PHASES env, JSON) drive three knobs:
  rps            open-loop request rate to TARGET_URL (baseline traffic)
  burst_workers  extra closed-loop clients (benign load spike: latency up, no errors)
  block          "on" = RDS egress blocked for the whole phase (real DB outage: 5xx + latency)
                 [on_s, off_s] = intermittent micro-outages (noise: short latency/error blips)

RDS is blocked with a NetworkPolicy that allows all egress except the RDS IPs. Calibrated
behaviour: new connections fail after ~15 s (3 x connect_timeout=5 s) -> HTTP 503; pooled
connections hang until unblocked. The policy is always removed on exit (also on SIGTERM).

Every line on stdout is JSON (Cloud Logging -> jsonPayload): phase_start / phase_end / stats /
run_summary. scripts/modulo-b/noise_report.py rebuilds the timeline from these events.
"""
import json
import os
import signal
import socket
import ssl
import threading
import time
import urllib.error
import urllib.request
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone

TARGET_URL = os.getenv("TARGET_URL", "http://data-service:8002/data/health")
NAMESPACE = os.getenv("NAMESPACE", "observability-lab")
RDS_HOST = os.environ["RDS_HOST"]
POLICY_NAME = os.getenv("POLICY_NAME", "chaos-block-rds")
TARGET_APP = os.getenv("TARGET_APP", "data-service")
CLIENT_TIMEOUT = float(os.getenv("CLIENT_TIMEOUT", "60"))
STATS_EVERY = float(os.getenv("STATS_EVERY", "10"))
DEFAULT_PHASES = [
    {"name": "baseline", "minutes": 35, "rps": 2},
    {"name": "noise_load_spike", "minutes": 5, "rps": 2, "burst_workers": 48},
    {"name": "recovery_1", "minutes": 10, "rps": 2},
    # 8 s blocked / 82 s open -> ~2% 5xx in a 5m window: above the 1% static threshold, below the 5% floor.
    {"name": "noise_micro_outages", "minutes": 6, "rps": 2, "block": [8, 82]},
    {"name": "recovery_2", "minutes": 10, "rps": 2},
    {"name": "incident_rds_outage", "minutes": 8, "rps": 2, "block": "on"},
    {"name": "recovery_final", "minutes": 10, "rps": 2},
]
PHASES = json.loads(os.getenv("PHASES") or "null") or DEFAULT_PHASES

stop = threading.Event()
lock = threading.Lock()
window = {"ok": 0, "err5xx": 0, "other": 0, "timeouts": 0, "lat": []}
current = {"phase": "init", "blocked": False}


def now_iso():
    return datetime.now(timezone.utc).isoformat(timespec="seconds")


def emit(event, **fields):
    print(json.dumps({"event": event, "ts": now_iso(), **fields}, ensure_ascii=False), flush=True)


# --- Kubernetes API (in-cluster service account) --------------------------------

SA = "/var/run/secrets/kubernetes.io/serviceaccount"
K8S = "https://kubernetes.default.svc"
_ctx = ssl.create_default_context(cafile=f"{SA}/ca.crt")


def k8s(method, path, body=None):
    with open(f"{SA}/token") as f:
        token = f.read().strip()
    req = urllib.request.Request(
        K8S + path, method=method, data=json.dumps(body).encode() if body else None,
        headers={"Authorization": f"Bearer {token}", "Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, context=_ctx, timeout=15) as r:
            return r.status
    except urllib.error.HTTPError as e:
        return e.code


NP_PATH = f"/apis/networking.k8s.io/v1/namespaces/{NAMESPACE}/networkpolicies"


def block_rds():
    ips = sorted({a[4][0] for a in socket.getaddrinfo(RDS_HOST, 5432, socket.AF_INET)})
    policy = {
        "apiVersion": "networking.k8s.io/v1", "kind": "NetworkPolicy",
        "metadata": {"name": POLICY_NAME, "labels": {"module": "modulo-b", "purpose": "chaos"}},
        "spec": {
            "podSelector": {"matchLabels": {"app": TARGET_APP}},
            "policyTypes": ["Egress"],
            "egress": [
                {"to": [{"namespaceSelector": {}}]},
                {"ports": [{"port": 53, "protocol": "UDP"}, {"port": 53, "protocol": "TCP"}]},
                {"to": [{"ipBlock": {"cidr": "0.0.0.0/0", "except": [f"{ip}/32" for ip in ips]}}]},
            ],
        },
    }
    status = k8s("POST", NP_PATH, policy)
    current["blocked"] = status in (200, 201, 409)
    emit("chaos_block", rds_ips=ips, http_status=status)


def unblock_rds():
    status = k8s("DELETE", f"{NP_PATH}/{POLICY_NAME}")
    current["blocked"] = False
    emit("chaos_unblock", http_status=status)


# --- Load ---------------------------------------------------------------------

def one_request():
    started = time.perf_counter()
    kind = "other"
    try:
        with urllib.request.urlopen(TARGET_URL, timeout=CLIENT_TIMEOUT) as r:
            kind = "ok" if r.status < 400 else "other"
    except urllib.error.HTTPError as e:
        kind = "err5xx" if e.code >= 500 else "other"
    except (TimeoutError, socket.timeout):
        kind = "timeouts"
    except Exception:
        kind = "other"
    elapsed = time.perf_counter() - started
    with lock:
        window[kind] += 1
        window["lat"].append(elapsed)


def open_loop(pool, rps_ref):
    next_at = time.monotonic()
    while not stop.is_set():
        rps = rps_ref["rps"]
        if rps <= 0:
            time.sleep(0.2)
            next_at = time.monotonic()
            continue
        pool.submit(one_request)
        next_at += 1.0 / rps
        time.sleep(max(0.0, next_at - time.monotonic()))


def burst_worker(until):
    while not stop.is_set() and time.monotonic() < until:
        one_request()


def pct(values, p):
    if not values:
        return None
    values = sorted(values)
    return round(values[min(len(values) - 1, int(len(values) * p))], 3)


def stats_loop():
    while not stop.wait(STATS_EVERY):
        with lock:
            lat, snap = window["lat"], {k: window[k] for k in ("ok", "err5xx", "other", "timeouts")}
            for k in snap:
                window[k] = 0
            window["lat"] = []
        total = sum(snap.values())
        emit("stats", phase=current["phase"], rds_blocked=current["blocked"], total=total, **snap,
             error_ratio=round(snap["err5xx"] / total, 3) if total else None,
             p50_s=pct(lat, 0.50), p95_s=pct(lat, 0.95), p99_s=pct(lat, 0.99))


def run_phase(phase, rps_ref):
    name, seconds = phase["name"], phase["minutes"] * 60
    rps_ref["rps"] = phase.get("rps", 0)
    current["phase"] = name
    emit("phase_start", phase=name, config=phase)
    started = time.monotonic()
    until = started + seconds

    workers = [threading.Thread(target=burst_worker, args=(until,), daemon=True)
               for _ in range(phase.get("burst_workers", 0))]
    for w in workers:
        w.start()

    block = phase.get("block")
    if block == "on":
        block_rds()
        stop.wait(seconds)
        unblock_rds()
    elif isinstance(block, list):
        on_s, off_s = block
        while not stop.is_set() and time.monotonic() < until:
            block_rds()
            stop.wait(min(on_s, max(0, until - time.monotonic())))
            unblock_rds()
            stop.wait(min(off_s, max(0, until - time.monotonic())))
    else:
        stop.wait(seconds)

    for w in workers:
        w.join(timeout=CLIENT_TIMEOUT)
    emit("phase_end", phase=name, duration_s=round(time.monotonic() - started))
    return {"phase": name, "start": None, "end": now_iso()}


def main():
    signal.signal(signal.SIGTERM, lambda *_: stop.set())
    signal.signal(signal.SIGINT, lambda *_: stop.set())
    unblock_rds()  # never start with a stale policy
    emit("run_start", target=TARGET_URL, rds_host=RDS_HOST, phases=PHASES)

    rps_ref = {"rps": 0}
    pool = ThreadPoolExecutor(max_workers=256)
    threading.Thread(target=open_loop, args=(pool, rps_ref), daemon=True).start()
    threading.Thread(target=stats_loop, daemon=True).start()

    timeline = []
    try:
        for phase in PHASES:
            if stop.is_set():
                break
            start = now_iso()
            entry = run_phase(phase, rps_ref)
            entry["start"] = start
            timeline.append(entry)
    finally:
        if current["blocked"] or stop.is_set():
            unblock_rds()
        stop.set()
        pool.shutdown(wait=False, cancel_futures=True)
        emit("run_summary", timeline=timeline, interrupted=len(timeline) < len(PHASES))


if __name__ == "__main__":
    main()
