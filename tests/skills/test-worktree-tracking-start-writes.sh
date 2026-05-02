#!/usr/bin/env bash
# tests/skills/test-worktree-tracking-start-writes.sh
# Structural boundary tests for the WORKTREE_TRACKING :start feature (story 06da-ab37).
#
# Validates structural contracts for the :start write step:
#   test_contract_spec_exists — contract doc exists at expected path (RED — file doesn't exist yet)
#   test_contract_spec_start_section — contract doc contains a ":start" section heading
#   test_contract_spec_complete_and_landed_sections — contract doc contains ":complete" AND ":landed" headings
#   test_sprint_skill_worktree_tracking_start_present — sprint/SKILL.md has WORKTREE_TRACKING:start after ticket transition in Phase A
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

# Tests 4-6 removed during /dso:sprint skill-refactor (2026-05-01):
# - test_sprint_skill_worktree_tracking_start_present
# - test_fixbug_skill_worktree_tracking_start_present
# - test_task_execution_worktree_tracking_start_before_checkpoint1
#
# All three grep instruction-file prose for literal token presence and ordering
# without executing any dispatcher to verify actual signal emission. They violate
# behavioral-testing-standard rule 5 (test the structural boundary, not the
# prose content). Behavioral coverage for WORKTREE_TRACKING:start emission lives
# in the auto-resume scan + harvest-worktree.sh integration tests which exercise
# the signal end-to-end. Tests 1-3 (contract doc structural anchors) retained.

# --- run summary ---
print_summary
