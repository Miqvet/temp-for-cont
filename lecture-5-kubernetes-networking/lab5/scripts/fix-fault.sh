#!/usr/bin/env bash
# Reverts whatever fault scripts/inject-fault.sh applied, back to the clean matrix.
set -euo pipefail
cd "$(dirname "$0")/.."
helm upgrade shop charts/shop --namespace shop5 --reuse-values \
  --set networkPolicy.fault.inject=none --wait --timeout 2m
