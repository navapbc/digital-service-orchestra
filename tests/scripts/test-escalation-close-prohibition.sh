#!/usr/bin/env bash
# tests/scripts/test-escalation-close-prohibition.sh
# Structural tests: debug-everything and fix-bug SKILL.md must prohibit closing
# bugs with "Escalated to user" reason without explicit user authorization.
#
# Fixes bug d0df-46d7: closing bugs with "Escalated to user:" reason removes
# visibility from ticket list — the correct action when no fix is possible is
# to add a comment and leave the ticket OPEN.
#
# Tests cover:
#   1. debug-everything SKILL.md does NOT allow "Escalated to user" as close reason
#   2. debug-everything SKILL.md contains explicit prohibition against closing unfixable bugs
#   3. fix-bug SKILL.md contains explicit prohibition against closing bugs as "Escalated to user"
#
# Usage: bash tests/scripts/test-escalation-close-prohibition.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DEBUG_SKILL="$PLUGIN_ROOT/plugins/dso/skills/debug-everything/SKILL.md"
FIX_BUG_SKILL="$PLUGIN_ROOT/plugins/dso/skills/fix-bug/SKILL.md"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

echo "=== test-escalation-close-prohibition.sh ==="

# ─────────────────────────────────────────────────────────────────────────────
# test_debug_everything_does_not_allow_escalated_as_close_reason
#
# The Bug close constraint in debug-everything SKILL.md must NOT state that
# "escalates to the user" is a valid reason to close a bug ticket.
# Closing removes visibility from 'ticket list' — this is the opposite of escalation.
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "--- test_debug_everything_does_not_allow_escalated_as_close_reason ---"

has_bad_escalate_close=0
if grep -q "OR explicitly escalates to the user" "$DEBUG_SKILL" 2>/dev/null; then
    has_bad_escalate_close=1
fi

if [[ $has_bad_escalate_close -eq 0 ]]; then
    (( ++PASS ))
    echo "  PASS: debug-everything does not allow 'escalates to user' as close condition"
else
    (( ++FAIL ))
    echo "  FAIL: debug-everything SKILL.md still contains 'OR explicitly escalates to the user' as a bug close condition" >&2
    echo "        This allows closing bugs without code fixes, removing visibility. (bug d0df-46d7)" >&2
fi

# ─────────────────────────────────────────────────────────────────────────────
# test_debug_everything_has_explicit_prohibition_against_escalated_close
#
# The debug-everything SKILL.md must contain an explicit NEVER/prohibition
# stating that bugs must NOT be closed with "Escalated to user" reason.
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "--- test_debug_everything_has_explicit_prohibition_against_escalated_close ---"

has_prohibition=0
if grep -qiE 'NEVER close.*Escalated to user|do not close.*Escalated to user|prohibit.*clos.*Escalated|Escalated to user.*must not close|must not.*close.*Escalated to user' "$DEBUG_SKILL" 2>/dev/null; then
    has_prohibition=1
fi

if [[ $has_prohibition -eq 1 ]]; then
    (( ++PASS ))
    echo "  PASS: debug-everything has explicit prohibition against closing with 'Escalated to user'"
else
    (( ++FAIL ))
    echo "  FAIL: debug-everything SKILL.md is missing explicit prohibition against closing bugs with 'Escalated to user' reason" >&2
    echo "        Must add: NEVER close a bug with reason 'Escalated to user:' — leave ticket OPEN with comment (bug d0df-46d7)" >&2
fi

# ─────────────────────────────────────────────────────────────────────────────
# test_fix_bug_has_explicit_prohibition_against_escalated_close
#
# The fix-bug SKILL.md must contain an explicit prohibition stating that bugs
# must NOT be closed with "Escalated to user" as an autonomous reason.
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "--- test_fix_bug_has_explicit_prohibition_against_escalated_close ---"

has_fix_bug_prohibition=0
if grep -qiE 'NEVER close.*Escalated to user|do not close.*Escalated to user|Escalated to user.*must not close|must not.*close.*Escalated to user|prohibit.*clos.*Escalated' "$FIX_BUG_SKILL" 2>/dev/null; then
    has_fix_bug_prohibition=1
fi

if [[ $has_fix_bug_prohibition -eq 1 ]]; then
    (( ++PASS ))
    echo "  PASS: fix-bug has explicit prohibition against closing with 'Escalated to user'"
else
    (( ++FAIL ))
    echo "  FAIL: fix-bug SKILL.md is missing explicit prohibition against closing bugs with 'Escalated to user' reason" >&2
    echo "        Must add: NEVER autonomously close a bug as 'Escalated to user:' — leave OPEN with comment (bug d0df-46d7)" >&2
fi

# ─────────────────────────────────────────────────────────────────────────────
# Summary
# ─────────────────────────────────────────────────────────────────────────────
print_summary
