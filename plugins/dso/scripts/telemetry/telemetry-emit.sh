#!/usr/bin/env bash
# telemetry-emit.sh (${CLAUDE_PLUGIN_ROOT}/scripts/telemetry/) — DSO telemetry shim
set -euo pipefail
# Forwards all arguments to telemetry_emit.py and passes through the exit code.
#
# Environment overrides (for test isolation):
#   DSO_CONFIG_FILE           — override path to dso-config.conf
#   DSO_TELEMETRY_LEDGER_DIR  — override path to telemetry ledger directory
#   DSO_TELEMETRY_EVENT_ID    — force a specific event_id (idempotency tests)
#   DSO_TELEMETRY_TIMEOUT     — socket timeout in seconds (default 5)
#
# Exit codes mirror telemetry_emit.py:
#   0 — success or fail-open (network/HTTP errors are non-fatal)
#   1 — validation error (empty client_id, unknown event_type)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

exec python3 "$SCRIPT_DIR/telemetry_emit.py" "$@"
