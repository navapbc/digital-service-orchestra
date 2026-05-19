#!/usr/bin/env bash
# bypass-log-check.sh (in ${CLAUDE_PLUGIN_ROOT}/scripts/)
# Validate that every gate_override entry in an artifact bundle has a complete
# bypass_log with both rationale and caller_context fields.
#
# Usage:
#   bypass-log-check.sh --artifact-file=<path>
#
# The artifact JSON is expected to have the shape:
#   {
#     "gate_overrides": [
#       {
#         "gate_name": "<name>",
#         "bypass_log": {
#           "rationale": "<text>",
#           "caller_context": "<text>"
#         }
#       }
#     ]
#   }
#
# Exit codes:
#   0 — all overrides have a valid bypass_log (or no overrides present)
#   1 — one or more overrides are missing bypass_log or required fields

set -uo pipefail

# ── Argument parsing ─────────────────────────────────────────────────────────
ARTIFACT_FILE=""
for arg in "$@"; do
    case "$arg" in
        --artifact-file=*)
            ARTIFACT_FILE="${arg#--artifact-file=}"
            ;;
        *)
            printf '{"error":"unknown_argument","arg":"%s"}\n' "$arg" >&2
            exit 1
            ;;
    esac
done

if [[ -z "$ARTIFACT_FILE" ]]; then
    printf '{"error":"missing_argument","message":"--artifact-file=<path> is required"}\n' >&2
    exit 1
fi

if [[ ! -f "$ARTIFACT_FILE" ]]; then
    printf '{"error":"file_not_found","path":"%s"}\n' "$ARTIFACT_FILE" >&2
    exit 1
fi

# ── Validate bypass logs via python3 ─────────────────────────────────────────
python3 - "$ARTIFACT_FILE" <<'PYEOF'
import json
import sys

artifact_path = sys.argv[1]

try:
    with open(artifact_path, "r") as fh:
        data = json.load(fh)
except json.JSONDecodeError as exc:
    print(json.dumps({"error": "invalid_json", "detail": str(exc)}), file=sys.stderr)
    sys.exit(1)

overrides = data.get("gate_overrides", [])

# No overrides present — nothing to validate
if not overrides:
    sys.exit(0)

failed = False
for entry in overrides:
    gate_name = entry.get("gate_name", "<unknown>")
    bypass_log = entry.get("bypass_log")

    if bypass_log is None:
        print(
            json.dumps({"error": "missing_bypass_log", "gate_name": gate_name}),
            file=sys.stderr,
        )
        failed = True
        continue

    rationale = bypass_log.get("rationale", "")
    caller_context = bypass_log.get("caller_context", "")

    if not rationale:
        print(
            json.dumps(
                {
                    "error": "missing_bypass_log_field",
                    "field": "rationale",
                    "gate_name": gate_name,
                }
            ),
            file=sys.stderr,
        )
        failed = True

    if not caller_context:
        print(
            json.dumps(
                {
                    "error": "missing_bypass_log_field",
                    "field": "caller_context",
                    "gate_name": gate_name,
                }
            ),
            file=sys.stderr,
        )
        failed = True

sys.exit(1 if failed else 0)
PYEOF
