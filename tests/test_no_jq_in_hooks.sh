#!/usr/bin/env bash
# tests/test_no_jq_in_hooks.sh
# Regression guard: ensures no hook file in hooks/ contains
# actual jq invocations. Comments referencing jq migration history and the
# check_tool function definition itself are excluded.
#
# Usage: bash tests/test_no_jq_in_hooks.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOKS_DIR="$SCRIPT_DIR/../hooks"

source "$SCRIPT_DIR/lib/assert.sh"

# ---------------------------------------------------------------------------
# Scan all hook files (recursively) for jq invocations, excluding:
#   1. Comment lines (lines starting with optional whitespace then #)
#   2. The check_tool function definition pattern (e.g., check_tool jq in a
#      function that tests for tool availability — the definition itself is OK)
#
# What counts as a jq invocation:
#   - Piping to jq:          ... | jq ...
#   - Direct jq command:     jq -r '...'  /  jq '.key'
#   - Command substitution:  $(jq ...)
#   - check_tool jq:         requiring jq as a dependency
#   - command -v jq:         checking for jq availability to use it
# ---------------------------------------------------------------------------

echo "=== Test: zero jq invocations in hooks/ ==="

# Find all shell files in hooks directory
VIOLATIONS=""
VIOLATION_COUNT=0

while IFS= read -r hook_file; do
    # Strip comment lines, then search for jq usage patterns
    # grep -n for line numbers; grep -v to exclude comments
    matches=$(grep -n '.' "$hook_file" \
        | grep -vE '^[0-9]+:\s*#' \
        | grep -E '\bjq\b' \
        || true)

    if [ -n "$matches" ]; then
        VIOLATIONS="${VIOLATIONS}${hook_file}:
${matches}
"
        VIOLATION_COUNT=$((VIOLATION_COUNT + $(echo "$matches" | wc -l | tr -d ' ')))
    fi
done < <(find "$HOOKS_DIR" -type f -name '*.sh' | sort)

if [ "$VIOLATION_COUNT" -eq 0 ]; then
    assert_eq "no jq invocations in hook files" "0" "0"
else
    echo ""
    echo "VIOLATIONS FOUND ($VIOLATION_COUNT jq invocations in non-comment lines):"
    echo "$VIOLATIONS"
    assert_eq "no jq invocations in hook files" "0" "$VIOLATION_COUNT"
fi

print_summary
