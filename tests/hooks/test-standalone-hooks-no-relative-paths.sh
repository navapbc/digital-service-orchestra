#!/usr/bin/env bash
# lockpick-workflow/tests/hooks/test-standalone-hooks-no-relative-paths.sh
# Regression guard: ensures standalone hook scripts use CLAUDE_PLUGIN_ROOT
# instead of ../ relative path references.
#
# Each file is allowed at most 1 ../ reference — the CLAUDE_PLUGIN_ROOT
# fallback line itself (e.g., cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd).
#
# Usage: bash lockpick-workflow/tests/hooks/test-standalone-hooks-no-relative-paths.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOKS_DIR="$SCRIPT_DIR/../../hooks"

source "$SCRIPT_DIR/../lib/assert.sh"

echo "=== Test: standalone hooks use CLAUDE_PLUGIN_ROOT (no excess ../ refs) ==="

# The 4 standalone hook files that must not use ../ (except the fallback line)
STANDALONE_HOOKS=(
    "auto-format.sh"
    "compute-diff-hash.sh"
    "pre-compact-checkpoint.sh"
    "write-reviewer-findings.sh"
)

TOTAL_EXCESS=0

for hook in "${STANDALONE_HOOKS[@]}"; do
    hook_file="$HOOKS_DIR/$hook"

    if [[ ! -f "$hook_file" ]]; then
        assert_eq "$hook exists" "exists" "missing"
        continue
    fi

    # Count all ../ references in the file
    count=$(grep -c '\.\.\/' "$hook_file" 2>/dev/null || echo 0)
    count=$(echo "$count" | tr -d '[:space:]')

    # At most 1 is allowed (the CLAUDE_PLUGIN_ROOT fallback line)
    if [[ "$count" -le 1 ]]; then
        assert_eq "$hook has at most 1 ../ ref" "true" "true"
    else
        TOTAL_EXCESS=$((TOTAL_EXCESS + count - 1))
        assert_eq "$hook has at most 1 ../ ref (found $count)" "true" "false"
    fi
done

# Also verify each file has the CLAUDE_PLUGIN_ROOT guard pattern
for hook in "${STANDALONE_HOOKS[@]}"; do
    hook_file="$HOOKS_DIR/$hook"
    [[ ! -f "$hook_file" ]] && continue

    guard_count=$(grep -c 'CLAUDE_PLUGIN_ROOT' "$hook_file" 2>/dev/null | head -1 || echo 0)
    if [[ "$guard_count" -ge 1 ]]; then
        assert_eq "$hook has CLAUDE_PLUGIN_ROOT guard" "true" "true"
    else
        assert_eq "$hook has CLAUDE_PLUGIN_ROOT guard" "true" "false"
    fi
done

print_summary
