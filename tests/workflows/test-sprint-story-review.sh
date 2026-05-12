#!/usr/bin/env bash
# tests/workflows/test-sprint-story-review.sh
# RED-phase behavioral tests for .github/workflows/sprint-story-review.yml
#
# Story 957a-a331-b9ed-435c: CI runner fires llm-review on every push to
# story/* branches scoped to the per-story delta, with concurrency-group
# preventing rate-limit storms.
#
# All 7 tests FAIL RED because sprint-story-review.yml does not exist yet.
#
# Usage: bash tests/workflows/test-sprint-story-review.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
WORKFLOW_FILE="$REPO_ROOT/.github/workflows/sprint-story-review.yml"

source "$REPO_ROOT/tests/lib/assert.sh"

echo "=== test-sprint-story-review.sh ==="

# ── test_workflow_file_exists ─────────────────────────────────────────────────
# The workflow YAML file must exist under .github/workflows/.
_snapshot_fail
file_exists=0
[[ -f "$WORKFLOW_FILE" ]] && file_exists=1
assert_eq "test_workflow_file_exists: .github/workflows/sprint-story-review.yml exists" "1" "$file_exists"
assert_pass_if_clean "test_workflow_file_exists"

# ── test_trigger_has_story_pattern ───────────────────────────────────────────
# The workflow must trigger on pushes to story/** branches.
_snapshot_fail
if [[ ! -f "$WORKFLOW_FILE" ]]; then
    assert_eq "test_trigger_has_story_pattern: workflow file present (prereq)" "1" "0"
else
    found=0
    grep -qE "story/\*\*" "$WORKFLOW_FILE" 2>/dev/null && found=1 || true
    assert_eq "test_trigger_has_story_pattern: on.push.branches contains story/**" "1" "$found"
fi
assert_pass_if_clean "test_trigger_has_story_pattern"

# ── test_concurrency_group_has_sprint_session_id ─────────────────────────────
# The concurrency group key must reference vars.SPRINT_SESSION_ID so that
# concurrent pushes to different story branches within the same sprint session
# are serialized under a shared group, preventing rate-limit storms.
_snapshot_fail
if [[ ! -f "$WORKFLOW_FILE" ]]; then
    assert_eq "test_concurrency_group_has_sprint_session_id: workflow file present (prereq)" "1" "0"
else
    found=0
    grep -q "vars.SPRINT_SESSION_ID" "$WORKFLOW_FILE" 2>/dev/null && grep -q "group:" "$WORKFLOW_FILE" 2>/dev/null && found=1 || true
    assert_eq "test_concurrency_group_has_sprint_session_id: concurrency.group contains vars.SPRINT_SESSION_ID" "1" "$found"
fi
assert_pass_if_clean "test_concurrency_group_has_sprint_session_id"

# ── test_cancel_in_progress_true ─────────────────────────────────────────────
# cancel-in-progress: true ensures superseded review runs are cancelled, keeping
# only the latest push to each story branch active.
_snapshot_fail
if [[ ! -f "$WORKFLOW_FILE" ]]; then
    assert_eq "test_cancel_in_progress_true: workflow file present (prereq)" "1" "0"
else
    found=0
    grep -qE "cancel-in-progress:\s+true" "$WORKFLOW_FILE" 2>/dev/null && found=1 || true
    assert_eq "test_cancel_in_progress_true: concurrency.cancel-in-progress is true" "1" "$found"
fi
assert_pass_if_clean "test_cancel_in_progress_true"

# ── test_job_fetches_session_branch ──────────────────────────────────────────
# The job must fetch the sprint session branch (referenced via vars.SPRINT_SESSION_ID)
# so the merge-base computation has the right upstream ref available.
_snapshot_fail
if [[ ! -f "$WORKFLOW_FILE" ]]; then
    assert_eq "test_job_fetches_session_branch: workflow file present (prereq)" "1" "0"
else
    found=0
    grep -q "vars.SPRINT_SESSION_ID" "$WORKFLOW_FILE" 2>/dev/null && found=1 || true
    assert_eq "test_job_fetches_session_branch: YAML references vars.SPRINT_SESSION_ID in fetch/checkout step" "1" "$found"
fi
assert_pass_if_clean "test_job_fetches_session_branch"

# ── test_job_calls_ci_llm_review_runner ──────────────────────────────────────
# The job must invoke ci-llm-review-runner.sh to run the LLM review pipeline.
_snapshot_fail
if [[ ! -f "$WORKFLOW_FILE" ]]; then
    assert_eq "test_job_calls_ci_llm_review_runner: workflow file present (prereq)" "1" "0"
else
    found=0
    grep -q "ci-llm-review-runner.sh" "$WORKFLOW_FILE" 2>/dev/null && found=1 || true
    assert_eq "test_job_calls_ci_llm_review_runner: YAML contains ci-llm-review-runner.sh" "1" "$found"
fi
assert_pass_if_clean "test_job_calls_ci_llm_review_runner"

# ── test_job_computes_merge_base ─────────────────────────────────────────────
# The job must compute the merge-base between the story branch and the session
# branch so that the review is scoped only to the per-story delta.
_snapshot_fail
if [[ ! -f "$WORKFLOW_FILE" ]]; then
    assert_eq "test_job_computes_merge_base: workflow file present (prereq)" "1" "0"
else
    found=0
    grep -q "merge-base" "$WORKFLOW_FILE" 2>/dev/null && found=1 || true
    assert_eq "test_job_computes_merge_base: YAML contains merge-base (git subcommand for per-story delta)" "1" "$found"
fi
assert_pass_if_clean "test_job_computes_merge_base"

print_summary
