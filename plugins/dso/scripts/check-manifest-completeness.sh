#!/usr/bin/env bash
# check-manifest-completeness.sh
#
# Read a completion-verifier JSON payload and validate all required audit-trail fields.
#
# Usage:
#   echo '{"criteria_results": {}, ...}' | bash check-manifest-completeness.sh
#   bash check-manifest-completeness.sh path/to/verifier-output.json
#
# Exit codes:
#   0  all required fields present
#   1  one or more required fields missing (error message to stderr)
#   2  no input, malformed JSON, unreadable file, or python3 unavailable
#
# Required fields:
#   criteria_results, consumer_smoke_tests, ticket_id,
#   overall_verdict, remediation_tasks_created

set -uo pipefail

# ── Read input ────────────────────────────────────────────────────────────────

if [[ $# -ge 1 ]]; then
    # Positional argument: file path
    input_source="$1"
    if [[ ! -f "$input_source" ]]; then
        echo "check-manifest-completeness: file not found: $input_source" >&2
        exit 2
    fi
    json_input=$(cat "$input_source")
elif [[ ! -t 0 ]]; then
    # stdin is a pipe or redirect
    json_input=$(cat)
else
    echo "check-manifest-completeness: no input provided (pipe JSON or pass a file path)" >&2
    exit 2
fi

# ── Validate required fields via python3 ──────────────────────────────────────

if ! command -v python3 >/dev/null 2>&1; then
    echo "check-manifest-completeness: python3 not found; cannot parse JSON" >&2
    exit 2
fi

result=$(printf '%s' "$json_input" | python3 -c "
import sys, json

REQUIRED_FIELDS = [
    'criteria_results',
    'consumer_smoke_tests',
    'ticket_id',
    'overall_verdict',
    'remediation_tasks_created',
]

try:
    data = json.load(sys.stdin)
except (json.JSONDecodeError, ValueError):
    sys.stderr.write('check-manifest-completeness: malformed JSON input\n')
    sys.exit(2)

missing = [f for f in REQUIRED_FIELDS if f not in data]
if missing:
    for field in missing:
        sys.stderr.write('check-manifest-completeness: missing required field: ' + field + '\n')
    sys.exit(1)

sys.exit(0)
" 2>&1)
py_rc=$?

if [[ $py_rc -eq 2 ]]; then
    printf '%s\n' "$result" >&2
    exit 2
elif [[ $py_rc -eq 1 ]]; then
    printf '%s\n' "$result" >&2
    exit 1
fi

exit 0
