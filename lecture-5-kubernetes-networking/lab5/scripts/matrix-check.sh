#!/usr/bin/env bash
# Walks the access matrix live: for a representative pod of each role, tries
# to reach each destination and prints expected vs actual. See README Part 5.
# Runs the actual probe from inside each pod's own network namespace (via
# nsenter on the node), so Calico enforces policy against that pod's real
# identity — not against whatever happens to issue the curl/bash command.
set -euo pipefail
NS="${NS:-shop5}"

get_pid() {
  local pod="$1" node="$2"
  local cid
  cid=$(kubectl -n "$NS" get pod "$pod" -o jsonpath='{.status.containerStatuses[0].containerID}' | sed 's#containerd://##')
  MSYS_NO_PATHCONV=1 docker exec "$node" crictl inspect "$cid" 2>/dev/null | grep '"pid"' | sed -n '2p' | grep -o '[0-9]*'
}

# TCP-only reachability check (for postgres, which speaks its own protocol,
# not HTTP) using bash's /dev/tcp, run inside the pod's netns via nsenter.
test_tcp() {
  local from_pid="$1" from_node="$2" host="$3" port="$4" desc="$5" expected="$6"
  local actual
  if MSYS_NO_PATHCONV=1 docker exec "$from_node" nsenter -t "$from_pid" -n timeout 3 bash -c "echo > /dev/tcp/$host/$port" 2>/dev/null; then
    actual="ALLOWED (tcp connect ok)"
  else
    actual="DENIED (tcp connect failed/timed out)"
  fi
  printf "%-30s expected=%-10s actual=%s\n" "$desc" "$expected" "$actual"
}

test_http() {
  local from_pid="$1" from_node="$2" target="$3" desc="$4" expected="$5"
  local code
  code=$(MSYS_NO_PATHCONV=1 docker exec "$from_node" nsenter -t "$from_pid" -n curl -s --max-time 3 -o /dev/null -w "%{http_code}" "$target" 2>/dev/null) || code="000"
  local actual
  case "$code" in
    *000*|"") actual="DENIED" ;;
    *) actual="ALLOWED ($code)" ;;
  esac
  printf "%-30s expected=%-10s actual=%s\n" "$desc" "$expected" "$actual"
}

API_POD=$(kubectl -n "$NS" get pods -l app.kubernetes.io/name=api -o jsonpath='{.items[0].metadata.name}')
API_NODE=$(kubectl -n "$NS" get pod "$API_POD" -o jsonpath='{.spec.nodeName}')
API_PID=$(get_pid "$API_POD" "$API_NODE")

WORKER_POD=$(kubectl -n "$NS" get pods -l app.kubernetes.io/name=worker -o jsonpath='{.items[0].metadata.name}')
WORKER_NODE=$(kubectl -n "$NS" get pod "$WORKER_POD" -o jsonpath='{.spec.nodeName}')
WORKER_PID=$(get_pid "$WORKER_POD" "$WORKER_NODE")

POSTGRES_IP=$(kubectl -n "$NS" get pod shop-postgres-1 -o jsonpath='{.status.podIP}')

STRAY_PID=""
if kubectl -n "$NS" get pod stray-debug >/dev/null 2>&1; then
  STRAY_NODE=$(kubectl -n "$NS" get pod stray-debug -o jsonpath='{.spec.nodeName}')
  STRAY_PID=$(get_pid "stray-debug" "$STRAY_NODE")
fi

echo "=== Access matrix: expected vs actual ==="
for node in $(kubectl get nodes -o jsonpath='{.items[*].metadata.name}'); do
  code=$(MSYS_NO_PATHCONV=1 docker exec "$node" curl -s --max-time 3 -o /dev/null -w "%{http_code}" http://localhost:30080/health 2>/dev/null) || code="000"
  case "$code" in
    *000*|"") actual="DENIED" ;;
    *) actual="ALLOWED ($code)" ;;
  esac
  printf "%-30s expected=%-10s actual=%s\n" "external client -> api via NodePort ($node)" "ALLOWED" "$actual"
done
test_tcp "$API_PID" "$API_NODE" "$POSTGRES_IP" 5432 "api -> postgres" "ALLOWED"
test_tcp "$WORKER_PID" "$WORKER_NODE" "$POSTGRES_IP" 5432 "worker -> postgres" "ALLOWED"
test_http "$API_PID" "$API_NODE" "http://shop-worker.${NS}.svc.cluster.local:8080/health" "api -> worker (not in matrix)" "DENIED"
if [ -n "$STRAY_PID" ]; then
  test_tcp "$STRAY_PID" "$STRAY_NODE" "$POSTGRES_IP" 5432 "stray pod -> postgres" "DENIED"
  # NOT the matrix's "client -> api" cell: that's an external client via
  # NodePort, which has no egress policy of its own (see the NodePort check
  # below). A stray pod *inside* the namespace is still subject to its own
  # default-deny egress, so even though api's ingress is open, the stray pod
  # itself can't send the request out in the first place.
  test_http "$STRAY_PID" "$STRAY_NODE" "http://shop-api.${NS}.svc.cluster.local/health" "stray pod -> api (in-cluster, NOT the external client)" "DENIED"
else
  echo "(stray-debug pod not found — create it first: kubectl -n $NS run stray-debug --image=curlimages/curl --restart=Never -- sleep 3600)"
fi
