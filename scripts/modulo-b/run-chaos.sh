#!/usr/bin/env bash
# Módulo B - launch the load/chaos experiment as a Job in the cluster.
#   ./run-chaos.sh                 full experiment (~84 min, default phases)
#   ./run-chaos.sh phases.json     custom phases (JSON list, see chaos_loadgen.py)
#   ./run-chaos.sh --stop          stop the Job (the script removes the NetworkPolicy on SIGTERM)
#   ./run-chaos.sh --cleanup       delete Job, ConfigMap, RBAC and any leftover NetworkPolicy
# Requires kubectl pointing at the otel-lab cluster (KUBECONFIG).
set -euo pipefail

NS=observability-lab
DIR="$(cd "$(dirname "$0")" && pwd)"

case "${1:-}" in
  --stop)
    kubectl -n "$NS" delete job modulo-b-chaos --wait=true
    kubectl -n "$NS" delete networkpolicy chaos-block-rds --ignore-not-found
    exit 0 ;;
  --cleanup)
    kubectl -n "$NS" delete job modulo-b-chaos --ignore-not-found --wait=true
    kubectl -n "$NS" delete networkpolicy chaos-block-rds --ignore-not-found
    kubectl -n "$NS" delete configmap modulo-b-chaos --ignore-not-found
    kubectl delete -f "$DIR/loadgen-job.yaml" --ignore-not-found
    exit 0 ;;
esac

PHASES_ARGS=()
if [[ -n "${1:-}" ]]; then
  PHASES_ARGS=(--from-file=phases.json="$1")
fi

if kubectl -n "$NS" get job modulo-b-chaos >/dev/null 2>&1; then
  echo "Job modulo-b-chaos already exists; run '$0 --cleanup' first." >&2
  exit 1
fi

kubectl -n "$NS" create configmap modulo-b-chaos \
  --from-file=chaos_loadgen.py="$DIR/chaos_loadgen.py" ${PHASES_ARGS[@]+"${PHASES_ARGS[@]}"} \
  --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -f "$DIR/loadgen-job.yaml"
# The Job controller creates the pod asynchronously; wait for it to exist before waiting for Ready.
for _ in $(seq 1 60); do
  kubectl -n "$NS" get pod -l job-name=modulo-b-chaos -o name 2>/dev/null | grep -q pod/ && break
  sleep 2
done
kubectl -n "$NS" wait --for=condition=Ready pod -l job-name=modulo-b-chaos --timeout=300s

echo "Started. Follow with:"
echo "  kubectl -n $NS logs -f job/modulo-b-chaos | grep -E 'phase_|chaos_|run_summary'"
