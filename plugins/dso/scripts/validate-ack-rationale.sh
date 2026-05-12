#!/usr/bin/env bash
# validate-ack-rationale.sh
# Validates that an acknowledgement rationale is substantive and references
# precondition content via a 3-word sliding window match.
#
# Usage: validate-ack-rationale.sh <rationale_text> <precondition_text>
# Exit codes:
#   0 = valid
#   1 = invalid (message to stderr)
#   2 = non-Latin precondition → manual review required
set -uo pipefail

rationale_text="${1:-}"
precondition_text="${2:-}"

# Step 1: Trim and check empty
trimmed="${rationale_text#"${rationale_text%%[![:space:]]*}"}"
trimmed="${trimmed%"${trimmed##*[![:space:]]}"}"
if [[ -z "$trimmed" ]]; then
    echo "rationale must not be empty" >&2
    exit 1
fi

# Step 2: Length check
if (( ${#trimmed} < 10 )); then
    echo "rationale must be at least 10 characters (got ${#trimmed})" >&2
    exit 1
fi

# Step 3: Non-Latin detection
if ! python3 -c "import sys; exit(0 if all(ord(c)<=127 for c in sys.argv[1]) else 1)" "$precondition_text" 2>/dev/null; then
    echo "MANUAL_REVIEW_REQUIRED: precondition text contains non-Latin characters; ack must be reviewed by a human before acceptance" >&2
    exit 2
fi

# Step 4: 3-word-window fuzzy match
python3 - "$trimmed" "$precondition_text" <<'PYEOF'
import sys

def normalize(s):
    return ''.join(c for c in s.lower() if c.isalnum())

try:
    rationale = sys.argv[1]
    precondition = sys.argv[2]

    norm_rationale = normalize(rationale)
    words = precondition.split()

    if len(words) < 3:
        sys.exit(0)  # Cannot form 3-word window, skip check

    for i in range(len(words) - 2):
        window = normalize(' '.join(words[i:i+3]))
        if window and window in norm_rationale:
            sys.exit(0)

    print("rationale does not reference precondition content (no 3-word window match found)", file=sys.stderr)
    sys.exit(1)
except Exception as e:
    print(f"ERROR: validate-ack-rationale validation error: {e}", file=sys.stderr)
    sys.exit(1)
PYEOF
exit $?
