#!/usr/bin/env bash
# check-verifier-verdict.sh
#
# Read a completion-verifier JSON payload and exit based on the P1 typed-enum field.
#
# Usage:
#   echo '{"P1": "PASS"}' | bash check-verifier-verdict.sh
#   bash check-verifier-verdict.sh path/to/verifier-output.json
#
# Exit codes:
#   0  P1 == "PASS"
#   1  P1 == "FAIL", "BLOCKED", or "INCONCLUSIVE"
#   2  P1 field absent, JSON malformed, or no input provided
#
# Outputs nothing to stdout on exit 0 or 1.
# Outputs an error message to stderr on exit 2.
#
# Contract: docs/contracts/verifier-verdict.md (relative to plugin root)

set -uo pipefail

# ── Read input ────────────────────────────────────────────────────────────────

if [[ $# -ge 1 ]]; then
    # Positional argument: file path
    input_source="$1"
    if [[ ! -f "$input_source" ]]; then
        echo "check-verifier-verdict: file not found: $input_source" >&2
        exit 2
    fi
    json_input=$(cat "$input_source")
elif [[ ! -t 0 ]]; then
    # stdin is a pipe or redirect
    json_input=$(cat)
else
    echo "check-verifier-verdict: no input provided (pipe JSON or pass a file path)" >&2
    exit 2
fi

# ── Parse P1 field via python3 ────────────────────────────────────────────────

if ! command -v python3 >/dev/null 2>&1; then
    echo "check-verifier-verdict: python3 not found; cannot parse JSON" >&2
    exit 2
fi

p1_value=$(printf '%s' "$json_input" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
except (json.JSONDecodeError, ValueError):
    sys.stderr.write('check-verifier-verdict: malformed JSON input\n')
    sys.exit(2)
val = data.get('P1', '')
if val:
    print(val)
" 2>&1)
py_rc=$?
if [[ $py_rc -ne 0 ]]; then
    # python3 wrote error to stderr via 2>&1 capture; relay it
    printf '%s\n' "$p1_value" >&2
    exit 2
fi

# ── Route on P1 value ─────────────────────────────────────────────────────────

case "$p1_value" in
    PASS)
        exit 0
        ;;
    FAIL|BLOCKED|INCONCLUSIVE)
        exit 1
        ;;
    "")
        # P1 field absent — python3 prints nothing when data.get('P1') is empty
        echo "check-verifier-verdict: P1 field absent in JSON input" >&2
        exit 2
        ;;
    *)
        # Unrecognized P1 value
        echo "check-verifier-verdict: unrecognized P1 value: $p1_value" >&2
        exit 2
        ;;
esac
