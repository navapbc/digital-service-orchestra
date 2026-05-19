#!/usr/bin/env bash
# check-second-source-report.sh
# Validates a second-source verification JSON report.
#
# Usage: bash <plugin-root>/scripts/check-second-source-report.sh <json-file>
#
# Input JSON formats:
#   Single story object:
#     {"story_id":"...","verifier_used":true,"renderer_used":true,"gate_enforced":true}
#   Array of story objects:
#     [{"story_id":"...","verifier_used":true,...}, ...]
#   Wrapped object with stories array:
#     {"stories":[{"story_id":"...","verifier_used":true,...}],"summary_verdict":"PASS"}
#
# Exit codes:
#   0 — all mechanism flags are true for all stories
#   1 — any mechanism flag is false; JSON error written to stderr
#
# Required: python3

set -uo pipefail

if [[ $# -lt 1 ]]; then
    printf '{"error":"missing_argument","message":"Usage: check-second-source-report.sh <json-file>"}\n' >&2
    exit 1
fi

JSON_FILE="$1"

if [[ ! -f "$JSON_FILE" ]]; then
    printf '{"error":"file_not_found","file":"%s"}\n' "$JSON_FILE" >&2
    exit 1
fi

python3 - "$JSON_FILE" <<'PYEOF'
import json
import sys

json_file = sys.argv[1]

with open(json_file, "r") as fh:
    try:
        data = json.load(fh)
    except json.JSONDecodeError as exc:
        print(json.dumps({"error": "invalid_json", "detail": str(exc)}), file=sys.stderr)
        sys.exit(1)

# Normalize to a list of story objects.
if isinstance(data, list):
    stories = data
elif isinstance(data, dict):
    if "stories" in data:
        # Wrapped format: {"stories": [...], "summary_verdict": "..."}
        stories = data["stories"]
    else:
        # Single story object
        stories = [data]
else:
    print(json.dumps({"error": "unexpected_json_type"}), file=sys.stderr)
    sys.exit(1)

REQUIRED_TRUE = ("verifier_used", "renderer_used", "gate_enforced")

for story in stories:
    story_id = story.get("story_id", "<unknown>")
    for field in REQUIRED_TRUE:
        if not story.get(field, False):
            print(
                json.dumps({
                    "error": "mechanism_not_used",
                    "story_id": story_id,
                    "field": field,
                }),
                file=sys.stderr,
            )
            sys.exit(1)

sys.exit(0)
PYEOF
