#!/usr/bin/env bash
# lockpick-workflow/tests/scripts/test-no-unguarded-plugin-refs.sh
# Regression guard: ensures debug-everything/SKILL.md does not contain
# hard-coded subagent_type references to removed external plugin agents.
#
# These 6 plugin agent types were removed and should be dispatched via
# discover-agents.sh routing categories instead:
#   unit-testing, debugging-toolkit, code-simplifier,
#   backend-api-security, commit-commands, claude-md-management
#
# Usage: bash lockpick-workflow/tests/scripts/test-no-unguarded-plugin-refs.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

source "$(dirname "${BASH_SOURCE[0]}")/../lib/run_test.sh"

echo "=== test-no-unguarded-plugin-refs (debug-everything) ==="

SKILL_FILE="$REPO_ROOT/lockpick-workflow/skills/debug-everything/SKILL.md"

# List of removed plugin agent types that should NOT appear as hard-coded
# subagent_type values in the dispatch table or elsewhere in SKILL.md
REMOVED_PLUGINS=(
    "unit-testing"
    "debugging-toolkit"
    "code-simplifier"
    "backend-api-security"
    "commit-commands"
    "claude-md-management"
)

# ── Test 1: SKILL.md exists ──────────────────────────────────────────────────
echo "Test 1: debug-everything/SKILL.md exists"
if [[ -f "$SKILL_FILE" ]]; then
    echo "  PASS: SKILL.md exists"
    (( PASS++ ))
else
    echo "  FAIL: SKILL.md not found at $SKILL_FILE" >&2
    (( FAIL++ ))
    echo ""
    echo "Results: $PASS passed, $FAIL failed"
    exit 1
fi

# ── Test 2-7: No hard-coded subagent_type refs for each removed plugin ───────
for plugin in "${REMOVED_PLUGINS[@]}"; do
    echo "Test: No hard-coded subagent_type=\"$plugin:\" in SKILL.md"
    matches=$(grep -c "subagent_type=\"${plugin}:" "$SKILL_FILE" 2>/dev/null || true)
    if [[ "$matches" -eq 0 ]]; then
        echo "  PASS: No subagent_type=\"$plugin:\" references found"
        (( PASS++ ))
    else
        echo "  FAIL: Found $matches hard-coded subagent_type=\"$plugin:\" reference(s)" >&2
        grep -n "subagent_type=\"${plugin}:" "$SKILL_FILE" >&2
        (( FAIL++ ))
    fi
done

# ── Test 8: error-debugging:error-detective is preserved ─────────────────────
echo "Test: error-debugging:error-detective references preserved"
if grep -q 'error-debugging:error-detective' "$SKILL_FILE"; then
    echo "  PASS: error-debugging:error-detective references present"
    (( PASS++ ))
else
    echo "  FAIL: error-debugging:error-detective references missing" >&2
    (( FAIL++ ))
fi

# ── Test 9: Dispatch table references routing system ─────────────────────────
echo "Test: Dispatch table references routing categories or discover-agents.sh"
if grep -qE 'discover-agents\.sh|routing category|agent-routing\.conf' "$SKILL_FILE"; then
    echo "  PASS: Routing system references found"
    (( PASS++ ))
else
    echo "  FAIL: No routing system references (discover-agents.sh, routing category, or agent-routing.conf) found" >&2
    (( FAIL++ ))
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
