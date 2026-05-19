#!/usr/bin/env bash
# render-closure-narrative.sh  # shim-exempt: self-referential header comment in script file
#
# Renders a deterministic closure narrative from typed verifier fields.
#
# Usage:
#   echo '{"P1":"PASS","criteria_results":[...]}' | bash render-closure-narrative.sh
#   bash render-closure-narrative.sh /path/to/verifier.json
#
# Output format: P1={P1} criteria_met={N}/{total} blocked_by={B}
#   P1     — value of the "P1" field from the input JSON
#   N      — count of criteria_results entries with verdict=PASS
#   total  — total count of criteria_results entries
#   B      — count of criteria_results entries with verdict=FAIL or BLOCKED
#
# Exit codes:
#   0  — success; narrative written to stdout
#   1  — error (malformed JSON, missing criteria_results); message written to stderr
#
# Dependencies: bash, python3
# No LLM calls. No random state. Same inputs → identical outputs.

set -euo pipefail

# ── Read input ────────────────────────────────────────────────────────────────
if [[ $# -ge 1 ]]; then
    # First positional argument: treat as file path
    if [[ ! -f "$1" ]]; then
        printf 'render-closure-narrative: file not found: %s\n' "$1" >&2
        exit 1
    fi
    INPUT=$(< "$1")
else
    # Read from stdin
    INPUT=$(cat)
fi

# ── Parse and render via python3 ──────────────────────────────────────────────
python3 - <<'PYEOF' "$INPUT"
import sys
import json

raw = sys.argv[1]

try:
    data = json.loads(raw)
except json.JSONDecodeError as exc:
    print(f"render-closure-narrative: malformed JSON: {exc}", file=sys.stderr)
    sys.exit(1)

if not isinstance(data, dict):
    print("render-closure-narrative: JSON root must be an object", file=sys.stderr)
    sys.exit(1)

p1 = data.get("P1", "")

if "criteria_results" not in data:
    print(
        "render-closure-narrative: missing required field: criteria_results",
        file=sys.stderr,
    )
    sys.exit(1)

criteria = data["criteria_results"]
if not isinstance(criteria, list):
    print("render-closure-narrative: criteria_results must be an array", file=sys.stderr)
    sys.exit(1)

total = len(criteria)
passed = sum(1 for c in criteria if c.get("verdict") == "PASS")
blocked = sum(
    1 for c in criteria if c.get("verdict") in ("FAIL", "BLOCKED")
)

print(f"P1={p1} criteria_met={passed}/{total} blocked_by={blocked}")
PYEOF
