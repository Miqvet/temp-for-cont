#!/usr/bin/env bash
# Continuous pod chaos: every few seconds, picks a random api/worker pod in
# the shop5 namespace and deletes it. The ReplicaSet recreates it immediately
# with a brand new pod IP. Run this in parallel with the k6 load Job
# (load-job.yaml) to prove the Service keeps traffic flowing throughout —
# see README Part 2.
set -euo pipefail

NAMESPACE="${NAMESPACE:-shop5}"
DURATION="${DURATION:-90}"      # seconds
MIN_INTERVAL="${MIN_INTERVAL:-3}"
MAX_INTERVAL="${MAX_INTERVAL:-6}"

end=$((SECONDS + DURATION))
killed=0

echo "chaos: killing a random api/worker pod every ${MIN_INTERVAL}-${MAX_INTERVAL}s for ${DURATION}s in ns/${NAMESPACE}"

while [ "$SECONDS" -lt "$end" ]; do
  mapfile -t pods < <(kubectl -n "$NAMESPACE" get pods -l 'app.kubernetes.io/name in (api,worker)' -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}')
  count=${#pods[@]}
  if [ "$count" -gt 0 ]; then
    idx=$((RANDOM % count))
    pod="${pods[$idx]}"
    echo "$(date '+%H:%M:%S') killing pod: $pod"
    kubectl -n "$NAMESPACE" delete pod "$pod" --wait=false >/dev/null 2>&1 || true
    killed=$((killed + 1))
  fi
  interval=$((MIN_INTERVAL + RANDOM % (MAX_INTERVAL - MIN_INTERVAL + 1)))
  sleep "$interval"
done

echo "chaos done: killed $killed pods over ${DURATION}s"
