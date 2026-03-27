#!/usr/bin/env bash
# tests/skills/test-bug-close-reason-guidance.sh
# Validates that agent-facing documentation includes --reason flag guidance
# when closing bug tickets.
#
# Bug: 42c6-7dc0 — Agents attempt to close bug tickets without --reason flag.
#
# Usage: bash tests/skills/test-bug-close-reason-guidance.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

source "$REPO_ROOT/tests/lib/assert.sh"

CLAUDE_MD="$REPO_ROOT/CLAUDE.md"
FIX_BUG_SKILL="$REPO_ROOT/plugins/dso/skills/fix-bug/SKILL.md"
END_SESSION_SKILL="$REPO_ROOT/plugins/dso/skills/end-session/SKILL.md"

# =============================================================================
# Test 1: CLAUDE.md mentions --reason for bug ticket closure
# The primary agent instruction file must mention that bug tickets require
# --reason when closing.
# =============================================================================
echo ""
echo "--- test_claude_md_mentions_reason_for_bug_close ---"
_snapshot_fail

_CMD_HAS_REASON="not_found"
grep -q '\-\-reason.*Fixed\|Fixed.*\-\-reason\|bug.*--reason\|--reason.*bug' "$CLAUDE_MD" 2>/dev/null && _CMD_HAS_REASON="found"
assert_eq "test_claude_md_mentions_reason_for_bug_close" "found" "$_CMD_HAS_REASON"

assert_pass_if_clean "test_claude_md_mentions_reason_for_bug_close"

# =============================================================================
# Test 2: fix-bug SKILL.md Step 8 includes --reason in close command
# The fix-bug skill's commit/close step must use --reason="Fixed: ..."
# =============================================================================
echo ""
echo "--- test_fix_bug_step8_includes_reason ---"
_snapshot_fail

_FB_HAS_REASON="not_found"
grep -q 'transition.*closed.*--reason\|--reason.*Fixed' "$FIX_BUG_SKILL" 2>/dev/null && _FB_HAS_REASON="found"
assert_eq "test_fix_bug_step8_includes_reason" "found" "$_FB_HAS_REASON"

assert_pass_if_clean "test_fix_bug_step8_includes_reason"

# =============================================================================
# Test 3: end-session SKILL.md mentions --reason for bug closure
# The end-session skill closes issues in Step 2 and must mention --reason
# for bug tickets.
# =============================================================================
echo ""
echo "--- test_end_session_mentions_reason_for_bugs ---"
_snapshot_fail

_ES_HAS_REASON="not_found"
grep -q '\-\-reason.*Fixed\|Fixed.*\-\-reason\|bug.*--reason\|--reason.*bug' "$END_SESSION_SKILL" 2>/dev/null && _ES_HAS_REASON="found"
assert_eq "test_end_session_mentions_reason_for_bugs" "found" "$_ES_HAS_REASON"

assert_pass_if_clean "test_end_session_mentions_reason_for_bugs"

# =============================================================================
# Test 4: CLAUDE.md Task Completion Workflow includes --reason
# The Task Completion section (step 4) must show --reason for bug tickets.
# =============================================================================
echo ""
echo "--- test_claude_md_completion_workflow_includes_reason ---"
_snapshot_fail

# The task completion workflow section should mention --reason near the
# ticket transition close command
_CW_HAS_REASON="not_found"
# Look for --reason within the Task Completion Workflow section (lines ~155-165)
sed -n '155,170p' "$CLAUDE_MD" | grep -q '\-\-reason' 2>/dev/null && _CW_HAS_REASON="found"
assert_eq "test_claude_md_completion_workflow_includes_reason" "found" "$_CW_HAS_REASON"

assert_pass_if_clean "test_claude_md_completion_workflow_includes_reason"

# =============================================================================
print_summary
