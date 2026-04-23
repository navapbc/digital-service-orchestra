#!/usr/bin/env bash
# tests/skills/test-worktree-tracking-complete-landed.sh
# Structural boundary tests for WORKTREE_TRACKING :complete/:landed instruction files.
#
# Story: d2ef-92cc (WORKTREE_TRACKING :complete/:landed instruction files)
# Task:  4055-f8d4 (RED test phase)
#
# Tests (all RED until feature is implemented):
#   1. test_per_worktree_review_commit_has_complete_section
#      — per-worktree-review-commit.md must contain 'WORKTREE_TRACKING:complete'
#   2. test_per_worktree_review_commit_complete_in_failure_path
#      — ':complete' must appear near failure/conflict/Step 6 context
#   3. test_end_session_has_landed_section
#      — end-session/SKILL.md must contain 'WORKTREE_TRACKING:landed'
#   4. test_end_session_landed_after_merge
#      — ':landed' must appear near merge-to-main/Step 4 context
#   5. test_end_session_landed_has_fail_silent_guard
#      — end-session/SKILL.md must contain the fail-silent guard for the :landed
#        comment ("Skip silently if not set"), ensuring agents skip the comment
#        command when TICKET_ID is unavailable rather than erroring out
#
# Usage: bash tests/skills/test-worktree-tracking-complete-landed.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DSO_PLUGIN_DIR="$PLUGIN_ROOT/plugins/dso"
PER_WORKTREE_MD="$DSO_PLUGIN_DIR/skills/sprint/prompts/per-worktree-review-commit.md"
END_SESSION_SKILL="$DSO_PLUGIN_DIR/skills/end-session/SKILL.md"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

echo "=== test-worktree-tracking-complete-landed.sh ==="

# ---------------------------------------------------------------------------
# test_per_worktree_review_commit_has_complete_section
# per-worktree-review-commit.md must contain 'WORKTREE_TRACKING:complete' so
# the orchestrator emits a machine-readable signal when a worktree is fully
# processed (reviewed, committed, and harvested).
# RED: file does not yet contain this signal.
# ---------------------------------------------------------------------------
_snapshot_fail
if grep -q 'WORKTREE_TRACKING:complete' "$PER_WORKTREE_MD" 2>/dev/null; then
    has_complete="found"
else
    has_complete="missing"
fi
assert_eq "test_per_worktree_review_commit_has_complete_section" "found" "$has_complete"
assert_pass_if_clean "test_per_worktree_review_commit_has_complete_section"

# ---------------------------------------------------------------------------
# test_per_worktree_review_commit_complete_in_failure_path
# ':complete' must appear in the context of failure/conflict handling (Step 6
# or near 'failure'/'conflict' keywords), ensuring the signal covers non-happy
# paths too (e.g. gate failure or harvest conflict paths).
# RED: ':complete' not yet present in the file at all.
# ---------------------------------------------------------------------------
_snapshot_fail
# Extract content around Step 6 / failure / conflict sections
step6_and_failure_content=$(awk '/Step 6|failure|conflict/,/Step 7/' "$PER_WORKTREE_MD" 2>/dev/null || true)
if grep -q ':complete' <<< "$step6_and_failure_content"; then
    complete_in_failure_path="found"
else
    complete_in_failure_path="missing"
fi
assert_eq "test_per_worktree_review_commit_complete_in_failure_path" "found" "$complete_in_failure_path"
assert_pass_if_clean "test_per_worktree_review_commit_complete_in_failure_path"

# ---------------------------------------------------------------------------
# test_end_session_has_landed_section
# end-session/SKILL.md must contain 'WORKTREE_TRACKING:landed' so the skill
# emits a machine-readable signal after a worktree branch is merged to main.
# RED: file does not yet contain this signal.
# ---------------------------------------------------------------------------
_snapshot_fail
if grep -q 'WORKTREE_TRACKING:landed' "$END_SESSION_SKILL" 2>/dev/null; then
    has_landed="found"
else
    has_landed="missing"
fi
assert_eq "test_end_session_has_landed_section" "found" "$has_landed"
assert_pass_if_clean "test_end_session_has_landed_section"

# ---------------------------------------------------------------------------
# test_end_session_landed_after_merge
# ':landed' must appear in the context of the merge-to-main step (Step 4 or
# near 'merge-to-main' references), ensuring the signal is emitted after the
# branch is permanently merged — not before.
# RED: ':landed' not yet present in the file at all.
# ---------------------------------------------------------------------------
_snapshot_fail
# Extract content around merge-to-main / Step 4 sections
merge_context=$(awk '/merge-to-main|Step 4|merge to main/,/Step 5/' "$END_SESSION_SKILL" 2>/dev/null || true)
if grep -q ':landed' <<< "$merge_context"; then
    landed_after_merge="found"
else
    landed_after_merge="missing"
fi
assert_eq "test_end_session_landed_after_merge" "found" "$landed_after_merge"
assert_pass_if_clean "test_end_session_landed_after_merge"

# ---------------------------------------------------------------------------
# test_end_session_landed_has_fail_silent_guard
# end-session/SKILL.md must contain the fail-silent guard pattern adjacent to
# the ':landed' comment instruction, signalling that agents must skip the
# comment when TICKET_ID is unavailable rather than failing with an error.
# The structural boundary tested: the guard phrase "Skip silently if not set"
# must appear in the same file as the :landed instruction.
# ---------------------------------------------------------------------------
_snapshot_fail
if grep -q 'Skip silently if not set' "$END_SESSION_SKILL" 2>/dev/null; then
    has_fail_silent_guard="found"
else
    has_fail_silent_guard="missing"
fi
assert_eq "test_end_session_landed_has_fail_silent_guard" "found" "$has_fail_silent_guard"
assert_pass_if_clean "test_end_session_landed_has_fail_silent_guard"

print_summary
