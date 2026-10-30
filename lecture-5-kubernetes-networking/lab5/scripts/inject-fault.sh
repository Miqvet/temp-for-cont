#!/usr/bin/env bash
# Picks one of 4 candidate network faults at random (or a named one via $1)
# and applies it to the shop chart's NetworkPolicy templates via --set,
# simulating a real misconfiguration slipping into values.yaml. See README
# Part 6 — diagnosis is deliberately a separate step (scripts/diagnose.sh),
# not something this script reveals.
set -euo pipefail
cd "$(dirname "$0")/.."

FAULTS=(wrong-worker-label wrong-postgres-port disable-dns wrong-api-port)
FAULT="${1:-${FAULTS[$((RANDOM % ${#FAULTS[@]}))]}}"

echo "injecting fault: $FAULT"
helm upgrade shop charts/shop --namespace shop5 --reuse-values \
  --set networkPolicy.fault.inject="$FAULT" --wait --timeout 2m
