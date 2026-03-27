#!/usr/bin/env bash
# tests/skills/test-no-chained-ticket-close.sh
# Validates that agent-facing docs do NOT chain ticket comment + ticket
# transition in a way that suggests a single Bash tool call.
#
# Bug: b53d-00b0 — chained commands exceed ~73s timeout, silently dropping
# the transition.
#
# Usage: bash tests/skills/test-no-chained-ticket-close.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

source "$REPO_ROOT/tests/lib/assert.sh"

# =============================================================================
# Test 1: sprint SKILL.md does not chain comment + transition
# =============================================================================
echo ""
echo "--- test_sprint_no_chained_comment_transition ---"
_snapshot_fail

_SPRINT_CHAIN="not_found"
grep -q 'ticket comment.*+.*ticket transition\|ticket comment.*then.*ticket transition' \
    "$REPO_ROOT/plugins/dso/skills/sprint/SKILL.md" 2>/dev/null && _SPRINT_CHAIN="found"
assert_eq "test_sprint_no_chained_comment_transition" "not_found" "$_SPRINT_CHAIN"

assert_pass_if_clean "test_sprint_no_chained_comment_transition"

# =============================================================================
# Test 2: debug-everything SKILL.md does not chain comment + transition
# =============================================================================
echo ""
echo "--- test_debug_everything_no_chained_comment_transition ---"
_snapshot_fail

_DEBUG_CHAIN="not_found"
grep -q 'ticket comment.*then.*ticket transition\|ticket comment.*+.*ticket transition' \
    "$REPO_ROOT/plugins/dso/skills/debug-everything/SKILL.md" 2>/dev/null && _DEBUG_CHAIN="found"
assert_eq "test_debug_everything_no_chained_comment_transition" "not_found" "$_DEBUG_CHAIN"

assert_pass_if_clean "test_debug_everything_no_chained_comment_transition"

# =============================================================================
# Test 3: bug-type close commands use --reason (not separate comment)
# Sprint and debug-everything should use --reason for bug close, not a
# separate ticket comment call.
# =============================================================================
echo ""
echo "--- test_bug_close_uses_reason_flag_in_sprint ---"
_snapshot_fail

# Sprint SKILL.md line ~164 (CHECKPOINT 6/6) should use --reason
_SPRINT_REASON="not_found"
grep -q 'ticket transition.*closed.*--reason\|--reason.*Fixed' \
    "$REPO_ROOT/plugins/dso/skills/sprint/SKILL.md" 2>/dev/null && _SPRINT_REASON="found"
assert_eq "test_bug_close_uses_reason_flag_in_sprint" "found" "$_SPRINT_REASON"

assert_pass_if_clean "test_bug_close_uses_reason_flag_in_sprint"

# =============================================================================
print_summary
