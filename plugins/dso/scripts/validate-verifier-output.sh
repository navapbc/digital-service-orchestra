#!/usr/bin/env bash
# validate-verifier-output.sh
# Validates verifier ruling output JSON against the fingerprint schema.
# Usage: validate-verifier-output.sh <rulings-json-file>

set -euo pipefail

_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "${_SCRIPT_DIR}/.." && pwd)}"

if [[ $# -ne 1 ]]; then
    echo "Usage: validate-verifier-output.sh <rulings-json-file>" >&2
    exit 1
fi

input_file="$1"
if [[ ! -f "$input_file" ]]; then
    echo "ERROR: file not found: $input_file" >&2
    exit 1
fi

python3 - "$input_file" <<'PYEOF'
import sys, json, re

input_file = sys.argv[1]
with open(input_file) as f:
    try:
        data = json.load(f)
    except json.JSONDecodeError as e:
        print(f"ERROR: invalid JSON: {e}", file=sys.stderr)
        sys.exit(1)

VALID_RULINGS = {"confirm", "downgrade-to-minor", "drop"}
# Fingerprint pattern: path:N-M where N and M are non-negative integers
FINGERPRINT_RE = re.compile(r'^.+:\d+-\d+$')

errors = []
rulings = data.get("rulings", [])

for i, ruling in enumerate(rulings):
    prefix = f"rulings[{i}]"

    # Validate ruling value
    ruling_val = ruling.get("ruling")
    if ruling_val not in VALID_RULINGS:
        errors.append(f"{prefix}.ruling: must be one of {sorted(VALID_RULINGS)}, got '{ruling_val}'")

    # Validate fingerprint format
    fp = ruling.get("fingerprint", "")
    if not fp:
        errors.append(f"{prefix}.fingerprint: missing required field")
    elif not FINGERPRINT_RE.match(fp):
        errors.append(
            f"{prefix}.fingerprint: Invalid fingerprint format: {fp!r} — "
            f"expected <path>:<line-start>-<line-end>"
        )
    else:
        # Parse line numbers
        colon_idx = fp.rfind(":")
        range_part = fp[colon_idx + 1:]
        try:
            start_str, end_str = range_part.split("-", 1)
            start = int(start_str)
            end = int(end_str)
            # 0-0 is the missing-line-anchor sentinel — always valid
            if not (start == 0 and end == 0):
                if start > end:
                    errors.append(
                        f"{prefix}.fingerprint: line-start ({start}) > line-end ({end}); "
                        f"use 0-0 sentinel for missing line anchors"
                    )
        except (ValueError, TypeError):
            errors.append(f"{prefix}.fingerprint: non-integer line numbers in '{fp}'")

    # Validate rationale
    if "rationale" not in ruling:
        errors.append(f"{prefix}.rationale: missing required field")
    elif not isinstance(ruling["rationale"], str) or len(ruling["rationale"].strip()) < 5:
        errors.append(f"{prefix}.rationale: must be a non-empty string")

if errors:
    for e in errors:
        print(f"ERROR: {e}", file=sys.stderr)
    sys.exit(1)

print(f"validate-verifier-output: {len(rulings)} ruling(s) valid")
sys.exit(0)
PYEOF
