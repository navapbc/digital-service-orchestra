#!/usr/bin/env bash
# tests/skills/test-end-session-rationalized-failures.sh
# Structural validation tests for the rationalized-failures accountability step
# in plugins/dso/skills/end-session/SKILL.md.
#
# TDD RED: All 12 tests FAIL because the step does not exist in SKILL.md yet.
# After the GREEN task (dso-h2gj) adds the step, all tests will pass.
#
# Tests:
#   1. test_skill_has_rationalized_failures_step   — heading "Rationalized Failures" exists between steps 2.75 and 2.8
#   2. test_step_references_conversation_scan       — step mentions scanning conversation context
#   3. test_step_has_accountability_question_before_after — step references "before or after changes" question
#   4. test_step_has_accountability_question_bug_exists   — step references bug ticket existence check
#   5. test_accountability_questions_interrogative  — accountability questions contain "?" (interrogative form)
#   6. test_step_references_git_stash_baseline      — step references git stash baseline check pattern
#   7. test_step_references_tk_list_bug             — step references tk list --type=bug for deduplication
#   8. test_step_references_tk_create               — step references tk create for bug ticket creation
#   9. test_step_has_summary_display                — Step 6 references rationalized failures display
#  10. test_step6_references_stored_failures        — Step 6 references RATIONALIZED_FAILURES_FROM_2_77
#  11. test_step_ordering_before_learnings          — rationalized-failures step line < Step 2.8 line
#  12. test_step_has_empty_guard                    — guard condition for when no failures are found
#
# Usage: bash tests/skills/test-end-session-rationalized-failures.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DSO_PLUGIN_DIR="$PLUGIN_ROOT/plugins/dso"
SKILL_MD="$DSO_PLUGIN_DIR/skills/end-session/SKILL.md"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

echo "=== test-end-session-rationalized-failures.sh ==="

# ---------------------------------------------------------------------------
# test_skill_has_rationalized_failures_step
# SKILL.md must have a heading matching "Rationalized Failures" and it must
# appear between steps 2.75 and 2.8 (i.e., as step 2.77 or similar).
# ---------------------------------------------------------------------------
_snapshot_fail
if grep -q "Rationalized Failures" "$SKILL_MD" 2>/dev/null; then
    has_heading="found"
else
    has_heading="missing"
fi
assert_eq "test_skill_has_rationalized_failures_step" "found" "$has_heading"
assert_pass_if_clean "test_skill_has_rationalized_failures_step"

# ---------------------------------------------------------------------------
# test_step_references_conversation_scan
# The rationalized-failures step must instruct scanning the conversation
# context for pre-existing failures mentioned before changes were made.
# ---------------------------------------------------------------------------
_snapshot_fail
step_content=$(awk '/Rationalized Failures/,/^### 2\.8\./' "$SKILL_MD" 2>/dev/null || true)
if echo "$step_content" | grep -qiE "scan|conversation|context"; then
    has_scan="found"
else
    has_scan="missing"
fi
assert_eq "test_step_references_conversation_scan" "found" "$has_scan"
assert_pass_if_clean "test_step_references_conversation_scan"

# ---------------------------------------------------------------------------
# test_step_has_accountability_question_before_after
# The step must include an accountability question about whether the failure
# existed "before or after" the changes made in this session.
# ---------------------------------------------------------------------------
_snapshot_fail
step_content=$(awk '/Rationalized Failures/,/^### 2\.8\./' "$SKILL_MD" 2>/dev/null || true)
if echo "$step_content" | grep -qiE "before.*after|after.*before|before or after"; then
    has_before_after="found"
else
    has_before_after="missing"
fi
assert_eq "test_step_has_accountability_question_before_after" "found" "$has_before_after"
assert_pass_if_clean "test_step_has_accountability_question_before_after"

# ---------------------------------------------------------------------------
# test_step_has_accountability_question_bug_exists
# The step must include a check for whether a bug ticket already exists for
# the failure, to avoid duplicate ticket creation.
# ---------------------------------------------------------------------------
_snapshot_fail
step_content=$(awk '/Rationalized Failures/,/^### 2\.8\./' "$SKILL_MD" 2>/dev/null || true)
if echo "$step_content" | grep -qiE "bug.*exist|exist.*bug|ticket.*exist|exist.*ticket|already.*ticket|ticket.*already"; then
    has_bug_exists="found"
else
    has_bug_exists="missing"
fi
assert_eq "test_step_has_accountability_question_bug_exists" "found" "$has_bug_exists"
assert_pass_if_clean "test_step_has_accountability_question_bug_exists"

# ---------------------------------------------------------------------------
# test_accountability_questions_interrogative
# Accountability questions in the step must use interrogative form (contain "?").
# ---------------------------------------------------------------------------
_snapshot_fail
step_content=$(awk '/Rationalized Failures/,/^### 2\.8\./' "$SKILL_MD" 2>/dev/null || true)
if echo "$step_content" | grep -q "?"; then
    has_question_mark="found"
else
    has_question_mark="missing"
fi
assert_eq "test_accountability_questions_interrogative" "found" "$has_question_mark"
assert_pass_if_clean "test_accountability_questions_interrogative"

# ---------------------------------------------------------------------------
# test_step_references_git_stash_baseline
# The step must reference a git stash baseline check pattern to identify
# failures that existed before the session's changes were applied.
# ---------------------------------------------------------------------------
_snapshot_fail
step_content=$(awk '/Rationalized Failures/,/^### 2\.8\./' "$SKILL_MD" 2>/dev/null || true)
if echo "$step_content" | grep -qiE "git stash|stash.*baseline|baseline.*stash|stash pop|stash.*check"; then
    has_stash="found"
else
    has_stash="missing"
fi
assert_eq "test_step_references_git_stash_baseline" "found" "$has_stash"
assert_pass_if_clean "test_step_references_git_stash_baseline"

# ---------------------------------------------------------------------------
# test_step_references_tk_list_bug
# The step must reference "tk list --type=bug" (or equivalent) for
# deduplication against existing open bug tickets.
# ---------------------------------------------------------------------------
_snapshot_fail
step_content=$(awk '/Rationalized Failures/,/^### 2\.8\./' "$SKILL_MD" 2>/dev/null || true)
if echo "$step_content" | grep -qE "tk list.*--type.*bug|tk list.*bug|--type=bug"; then
    has_tk_list_bug="found"
else
    has_tk_list_bug="missing"
fi
assert_eq "test_step_references_tk_list_bug" "found" "$has_tk_list_bug"
assert_pass_if_clean "test_step_references_tk_list_bug"

# ---------------------------------------------------------------------------
# test_step_references_tk_create
# The step must reference "tk create" for creating bug tickets for
# pre-existing failures that lack tickets.
# ---------------------------------------------------------------------------
_snapshot_fail
step_content=$(awk '/Rationalized Failures/,/^### 2\.8\./' "$SKILL_MD" 2>/dev/null || true)
if echo "$step_content" | grep -qE "tk create"; then
    has_tk_create="found"
else
    has_tk_create="missing"
fi
assert_eq "test_step_references_tk_create" "found" "$has_tk_create"
assert_pass_if_clean "test_step_references_tk_create"

# ---------------------------------------------------------------------------
# test_step_has_summary_display
# Step 6 (Report: Task Summary) must reference rationalized failures display,
# indicating that failures found in step 2.77 are shown in the final summary.
# ---------------------------------------------------------------------------
_snapshot_fail
step6_content=$(awk '/^### 6\./,/^### 7\./' "$SKILL_MD" 2>/dev/null || true)
if echo "$step6_content" | grep -qiE "rationalized.failure|RATIONALIZED_FAILURES"; then
    has_summary_display="found"
else
    has_summary_display="missing"
fi
assert_eq "test_step_has_summary_display" "found" "$has_summary_display"
assert_pass_if_clean "test_step_has_summary_display"

# ---------------------------------------------------------------------------
# test_step6_references_stored_failures
# Step 6 must reference the stored variable RATIONALIZED_FAILURES_FROM_2_77
# (the named accumulator written in step 2.77 for display at session end).
# ---------------------------------------------------------------------------
_snapshot_fail
step6_content=$(awk '/^### 6\./,/^### 7\./' "$SKILL_MD" 2>/dev/null || true)
if echo "$step6_content" | grep -q "RATIONALIZED_FAILURES_FROM_2_77"; then
    has_var_ref="found"
else
    has_var_ref="missing"
fi
assert_eq "test_step6_references_stored_failures" "found" "$has_var_ref"
assert_pass_if_clean "test_step6_references_stored_failures"

# ---------------------------------------------------------------------------
# test_step_ordering_before_learnings
# The rationalized-failures step must appear BEFORE step 2.8 (Extract
# Technical Learnings). Verified by comparing line numbers in SKILL.md.
# ---------------------------------------------------------------------------
_snapshot_fail
rationalized_line=$(grep -n "Rationalized Failures" "$SKILL_MD" 2>/dev/null | head -1 | cut -d: -f1 || true)
learnings_line=$(grep -n "^### 2\.8\." "$SKILL_MD" 2>/dev/null | head -1 | cut -d: -f1 || true)
if [[ -n "$rationalized_line" && -n "$learnings_line" && "$rationalized_line" -lt "$learnings_line" ]]; then
    ordering_ok="yes"
else
    ordering_ok="no"
fi
assert_eq "test_step_ordering_before_learnings" "yes" "$ordering_ok"
assert_pass_if_clean "test_step_ordering_before_learnings"

# ---------------------------------------------------------------------------
# test_step_has_empty_guard
# The step must include a guard condition for when no pre-existing failures
# are found (i.e., a "skip" or "if none" or "if empty" path).
# ---------------------------------------------------------------------------
_snapshot_fail
step_content=$(awk '/Rationalized Failures/,/^### 2\.8\./' "$SKILL_MD" 2>/dev/null || true)
if echo "$step_content" | grep -qiE "if none|if no|skip.*if|none found|nothing found|empty|no failures"; then
    has_empty_guard="found"
else
    has_empty_guard="missing"
fi
assert_eq "test_step_has_empty_guard" "found" "$has_empty_guard"
assert_pass_if_clean "test_step_has_empty_guard"

print_summary
