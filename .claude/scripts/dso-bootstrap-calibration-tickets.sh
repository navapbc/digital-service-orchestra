#!/usr/bin/env bash
# Idempotently bootstraps the three calibration tracking tickets.
# Safe to run multiple times. Required before enabling calibration-rollup.yml.
# Usage: .claude/scripts/dso-bootstrap-calibration-tickets.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# DSO env var override allows test stubs; falls back to co-located dso script.
DSO="${DSO:-$SCRIPT_DIR/dso}"

bootstrap_ticket() {
  local alias="$1" title="$2" desc="$3"
  local exists_rc=0
  # Capture exit code without triggering set -e (|| prevents set -e on non-zero)
  "$DSO" ticket exists "$alias" 2>/dev/null || exists_rc=$?
  case $exists_rc in
    0)
      echo "bootstrap: $alias already exists — skipping"
      ;;
    1)
      "$DSO" ticket create story "$title" --alias="$alias" --description="$desc"
      echo "bootstrap: $alias created"
      ;;
    *)
      echo "bootstrap: exists check for $alias failed (rc=$exists_rc)" >&2
      exit "$exists_rc"
      ;;
  esac
}

bootstrap_ticket "calibration-program-health" \
  "Calibration program health — rollup tracking ticket" \
  "Tracking ticket for calibration-report.sh monthly and quarterly health rollups. Accumulates rollup comment records. Created by dso-bootstrap-calibration-tickets.sh."

bootstrap_ticket "mutation-history" \
  "Mutation test history — calibration tracking ticket" \
  "Tracking ticket for calibration-report.sh mutation-append accumulation. Each CI run appends a mutation score record. Created by dso-bootstrap-calibration-tickets.sh."

bootstrap_ticket "suite-churn-history" \
  "Suite churn history — calibration tracking ticket" \
  "Tracking ticket for calibration-report.sh churn-append accumulation. Each CI run appends a suite churn record. Created by dso-bootstrap-calibration-tickets.sh."
