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
  # ticket exists only accepts UUID-format IDs, not human-readable aliases.
  # Use list-epics --has-tag= for idempotency; tab character in output means found.
  local list_out
  list_out=$("$DSO" ticket list-epics --has-tag="$alias" 2>/dev/null || true)
  if printf '%s\n' "$list_out" | grep -q "	"; then
    echo "bootstrap: $alias already exists — skipping"
    return 0
  fi
  # Create as epic type: calibration-report.sh health-ticket lookup uses --type=epic.
  "$DSO" ticket create epic "$title" --tags="$alias" --description="$desc"
  echo "bootstrap: $alias created"
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
