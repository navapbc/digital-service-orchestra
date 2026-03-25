#!/usr/bin/env bash
# scripts/check-acceptance-criteria.sh
# Verify a ticket contains a structured ACCEPTANCE CRITERIA section before sub-agent dispatch.
#
# Usage: check-acceptance-criteria.sh <id>
# Exit codes: 0 = block found, 1 = block missing
# Output: AC_CHECK: pass (<N> criteria lines) | AC_CHECK: fail - no ACCEPTANCE CRITERIA section

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TICKET_CMD="${TICKET_CMD:-$SCRIPT_DIR/ticket}"

ID="${1:?Usage: check-acceptance-criteria.sh <id>}"

# ticket show exits non-zero when a ticket is not found.
# Capture output and check exit code to detect failure.
output=$("$TICKET_CMD" show "$ID" 2>/dev/null) || {
    echo "AC_CHECK: fail - could not load $ID"
    exit 1
}
if [ -z "$output" ]; then
    echo "AC_CHECK: fail - could not load $ID"
    exit 1
fi

# Count checklist items in the ## Acceptance Criteria section using awk.
# Matches the "## Acceptance Criteria" heading from tk markdown body.
# Terminates on the next ## heading.
# Blank lines within the block are allowed (does NOT terminate on blank lines).
ac_count=$(echo "$output" | awk '
  tolower($0) ~ /^## acceptance criteria/ { found=1; next }
  found && /^## / { exit }
  found && /^- \[/ { count++ }
  END { print count+0 }
')

# Defensive default: ensure ac_count is numeric
ac_count="${ac_count:-0}"

if [ "$ac_count" -ge 1 ]; then
    echo "AC_CHECK: pass ($ac_count criteria lines)"
    exit 0
else
    echo "AC_CHECK: fail - no ACCEPTANCE CRITERIA section in $ID (use: .claude/scripts/dso ticket create with an '## Acceptance Criteria' section with checklist items)"
    exit 1
fi
