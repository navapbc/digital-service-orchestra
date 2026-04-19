#!/usr/bin/env bash
# tests/skills/test-worktree-tracking-start-writes.sh
# Structural boundary tests for the WORKTREE_TRACKING :start feature (story 06da-ab37).
#
# Validates structural contracts for the :start write step:
#   test_contract_spec_exists — contract doc exists at expected path (RED — file doesn't exist yet)
#   test_contract_spec_start_section — contract doc contains a ":start" section heading
#   test_contract_spec_complete_and_landed_sections — contract doc contains ":complete" AND ":landed" headings
#   test_sprint_skill_worktree_tracking_start_present — sprint/SKILL.md has WORKTREE_TRACKING:start after ticket transition in Phase 1
#   test_fixbug_skill_worktree_tracking_start_present — fix-bug SKILL.md has WORKTREE_TRACKING:start in Step 0.5
#   test_task_execution_worktree_tracking_start_before_checkpoint1 — WORKTREE_TRACKING:start appears before CHECKPOINT 1/6 in task-execution.md
#
# All tests are RED — they fail before the GREEN task implements the :start feature.
#
# Usage: bash tests/skills/test-worktree-tracking-start-writes.sh
# Returns: exit 0 if all assertions pass, exit 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

CONTRACT_DOC="$REPO_ROOT/plugins/dso/docs/contracts/worktree-tracking-comment.md"
SPRINT_SKILL="$REPO_ROOT/plugins/dso/skills/sprint/SKILL.md"
FIXBUG_SKILL="$REPO_ROOT/plugins/dso/skills/fix-bug/SKILL.md"
TASK_EXECUTION="$REPO_ROOT/plugins/dso/skills/sprint/prompts/task-execution.md"

source "$REPO_ROOT/tests/lib/assert.sh"

echo "=== test-worktree-tracking-start-writes.sh ==="

# ---------------------------------------------------------------------------
# test_contract_spec_exists
# Structural boundary: the contract doc must exist before any instruction file
# can reference the :start comment format. RED — file doesn't exist yet.
# ---------------------------------------------------------------------------
echo "--- test_contract_spec_exists ---"
_snapshot_fail
if [[ -f "$CONTRACT_DOC" ]]; then
    assert_eq "test_contract_spec_exists: contract doc exists" "present" "present"
else
    assert_eq "test_contract_spec_exists: contract doc exists" "present" "missing"
fi
assert_pass_if_clean "test_contract_spec_exists"

# ---------------------------------------------------------------------------
# test_contract_spec_start_section
# Structural boundary: the contract doc must contain a ":start" section heading
# so agents can locate the format definition. RED — file doesn't exist yet.
# ---------------------------------------------------------------------------
echo "--- test_contract_spec_start_section ---"
_snapshot_fail
if grep -q ":start" "$CONTRACT_DOC" 2>/dev/null; then
    assert_eq "test_contract_spec_start_section: :start section present" "present" "present"
else
    assert_eq "test_contract_spec_start_section: :start section present" "present" "missing"
fi
assert_pass_if_clean "test_contract_spec_start_section"

# ---------------------------------------------------------------------------
# test_contract_spec_complete_and_landed_sections
# Structural boundary: the contract doc must contain both ":complete" AND
# ":landed" section headings — the full lifecycle is defined together.
# RED — file doesn't exist yet.
# ---------------------------------------------------------------------------
echo "--- test_contract_spec_complete_and_landed_sections ---"
_snapshot_fail
_has_complete=0
_has_landed=0
if grep -q ":complete" "$CONTRACT_DOC" 2>/dev/null; then _has_complete=1; fi
if grep -q ":landed" "$CONTRACT_DOC" 2>/dev/null; then _has_landed=1; fi

if [[ "$_has_complete" -eq 1 && "$_has_landed" -eq 1 ]]; then
    assert_eq "test_contract_spec_complete_and_landed_sections: :complete and :landed present" "present" "present"
else
    assert_eq "test_contract_spec_complete_and_landed_sections: :complete and :landed present" "present" "missing"
fi
assert_pass_if_clean "test_contract_spec_complete_and_landed_sections"

# ---------------------------------------------------------------------------
# test_sprint_skill_worktree_tracking_start_present
# Structural boundary: sprint/SKILL.md Phase 1 must include
# "WORKTREE_TRACKING:start" after the "ticket transition.*in_progress" step.
# RED — the instruction is not in SKILL.md yet.
# ---------------------------------------------------------------------------
echo "--- test_sprint_skill_worktree_tracking_start_present ---"
_snapshot_fail
_transition_line=$(grep -n "ticket transition.*in_progress" "$SPRINT_SKILL" 2>/dev/null | while IFS=: read -r _num _rest; do [[ "$_rest" =~ ^[[:space:]]*# ]] || echo "$_num"; done | head -1)
_tracking_line=$(grep -n "WORKTREE_TRACKING:start" "$SPRINT_SKILL" 2>/dev/null | head -1 | cut -d: -f1)

_result="missing"
if [[ -n "$_transition_line" && -n "$_tracking_line" ]]; then
    if [[ "$_tracking_line" -gt "$_transition_line" ]]; then
        _result="found"
    fi
fi
assert_eq "test_sprint_skill_worktree_tracking_start_present: WORKTREE_TRACKING:start after ticket transition in Phase 1" "found" "$_result"
assert_pass_if_clean "test_sprint_skill_worktree_tracking_start_present"

# ---------------------------------------------------------------------------
# test_fixbug_skill_worktree_tracking_start_present
# Structural boundary: fix-bug/SKILL.md Step 0.5 section must include
# "WORKTREE_TRACKING:start". RED — not in SKILL.md yet.
# ---------------------------------------------------------------------------
echo "--- test_fixbug_skill_worktree_tracking_start_present ---"
_snapshot_fail
_step05_line=$(grep -n "Step 0.5" "$FIXBUG_SKILL" 2>/dev/null | head -1 | cut -d: -f1)
_tracking_fb_line=$(grep -n "WORKTREE_TRACKING:start" "$FIXBUG_SKILL" 2>/dev/null | head -1 | cut -d: -f1)

_result_fb="missing"
if [[ -n "$_step05_line" && -n "$_tracking_fb_line" ]]; then
    if [[ "$_tracking_fb_line" -gt "$_step05_line" ]]; then
        _result_fb="found"
    fi
fi
assert_eq "test_fixbug_skill_worktree_tracking_start_present: WORKTREE_TRACKING:start in Step 0.5 section" "found" "$_result_fb"
assert_pass_if_clean "test_fixbug_skill_worktree_tracking_start_present"

# ---------------------------------------------------------------------------
# test_task_execution_worktree_tracking_start_before_checkpoint1
# Structural boundary: task-execution.md must have "WORKTREE_TRACKING:start"
# appearing before "CHECKPOINT 1/6". RED — not in task-execution.md yet.
# ---------------------------------------------------------------------------
echo "--- test_task_execution_worktree_tracking_start_before_checkpoint1 ---"
_snapshot_fail
_checkpoint_line=$(grep -n "CHECKPOINT 1/6" "$TASK_EXECUTION" 2>/dev/null | head -1 | cut -d: -f1)
_tracking_te_line=$(grep -n "WORKTREE_TRACKING:start" "$TASK_EXECUTION" 2>/dev/null | head -1 | cut -d: -f1)

_result_te="missing"
if [[ -n "$_checkpoint_line" && -n "$_tracking_te_line" ]]; then
    if [[ "$_tracking_te_line" -lt "$_checkpoint_line" ]]; then
        _result_te="found"
    fi
fi
assert_eq "test_task_execution_worktree_tracking_start_before_checkpoint1: WORKTREE_TRACKING:start before CHECKPOINT 1/6" "found" "$_result_te"
assert_pass_if_clean "test_task_execution_worktree_tracking_start_before_checkpoint1"

# --- run summary ---
print_summary
