#!/usr/bin/env bash
# route-escalation.sh — collect gate signals and run gate-escalation-router.py.
#
# Reads gate output JSON from environment variables (each conforming to
# docs/contracts/gate-signal-schema.md) and pipes the consolidated array to the
# router. Emits the router's full routing JSON to stdout. The caller extracts
# `route` (auto-fix | dialog | escalate) and `signal_count` from the JSON.
#
# Inputs (env vars; each may be empty / unset / unparseable — they are filtered):
#   FEATURE_REQUEST_GATE_OUTPUT      — feature-request check signal
#   REVERSAL_GATE_OUTPUT      — reversal-check signal
#   BLAST_RADIUS_GATE_OUTPUT      — blast-radius modifier signal
#   ASSERTION_REGRESSION_GATE_OUTPUT      — assertion-regression signal
#   DEPENDENCY_GATE_OUTPUT      — dependency-check signal
#   SCOPE_DRIFT_OUTPUT  — scope-drift-reviewer signal (optional)
#
# Flags:
#   --complex           — force escalate (passes through to router)
#
# Exit: always 0. Router fail-open: malformed/empty JSON in any field is silently
# dropped from the array (does not crash routing).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROUTER="$SCRIPT_DIR/gate-escalation-router.py"

COMPLEX_FLAG=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --complex) COMPLEX_FLAG="--complex"; shift ;;
        *) echo "ERROR: unknown argument: $1" >&2; exit 1 ;;
    esac
done

GATE_SIGNALS_JSON=$(printf '%s\n' \
    "${FEATURE_REQUEST_GATE_OUTPUT:-}" \
    "${REVERSAL_GATE_OUTPUT:-}" \
    "${BLAST_RADIUS_GATE_OUTPUT:-}" \
    "${ASSERTION_REGRESSION_GATE_OUTPUT:-}" \
    "${DEPENDENCY_GATE_OUTPUT:-}" \
    "${SCOPE_DRIFT_OUTPUT:-}" \
  | python3 -c "
import json, sys
signals = []
for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    try:
        signals.append(json.loads(line))
    except json.JSONDecodeError:
        pass
print(json.dumps(signals))
")

if [[ -n "$COMPLEX_FLAG" ]]; then
    echo "$GATE_SIGNALS_JSON" | python3 "$ROUTER" "$COMPLEX_FLAG" 2>/dev/null || echo '{"route":"auto-fix","signal_count":0,"dialog_context":null}'
else
    echo "$GATE_SIGNALS_JSON" | python3 "$ROUTER" 2>/dev/null || echo '{"route":"auto-fix","signal_count":0,"dialog_context":null}'
fi
