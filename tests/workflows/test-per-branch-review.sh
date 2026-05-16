#!/usr/bin/env bash
# tests/workflows/test-per-branch-review.sh
# RED-phase behavioral tests for .github/workflows/per-branch-review.yml
#
# Story 957a-a331-b9ed-435c: CI runner fires llm-review on every push to
# story/* branches scoped to the per-story delta, with concurrency-group
# preventing rate-limit storms.
#
# All 7 tests FAIL RED because per-branch-review.yml does not exist yet.
#
# Usage: bash tests/workflows/test-per-branch-review.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
WORKFLOW_FILE="$REPO_ROOT/.github/workflows/per-branch-review.yml"

source "$REPO_ROOT/tests/lib/assert.sh"

echo "=== test-per-branch-review.sh ==="

# ── test_workflow_file_exists ─────────────────────────────────────────────────
# The workflow YAML file must exist under .github/workflows/.
_snapshot_fail
file_exists=0
[[ -f "$WORKFLOW_FILE" ]] && file_exists=1
assert_eq "test_workflow_file_exists: .github/workflows/per-branch-review.yml exists" "1" "$file_exists"
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

# ── test_job_installs_litellm ─────────────────────────────────────────────────
# The job must install litellm before running ci-llm-review-runner.sh.
# Without litellm, the runner fails with ModuleNotFoundError (ada8-4478).
_snapshot_fail
if [[ ! -f "$WORKFLOW_FILE" ]]; then
    assert_eq "test_job_installs_litellm: workflow file present (prereq)" "1" "0"
else
    litellm_line=0
    review_line=0
    litellm_line=$(grep -n "litellm" "$WORKFLOW_FILE" 2>/dev/null | head -1 | cut -d: -f1) || true
    review_line=$(grep -n "Run LLM review" "$WORKFLOW_FILE" 2>/dev/null | head -1 | cut -d: -f1) || true
    ordering_ok=0
    if [[ -n "$litellm_line" && -n "$review_line" && "$litellm_line" -lt "$review_line" ]]; then
        ordering_ok=1
    fi
    assert_eq "test_job_installs_litellm: YAML installs litellm before Run LLM review" "1" "$ordering_ok"
fi
assert_pass_if_clean "test_job_installs_litellm"

# ── test_mirror_tracker_defenses_job_exists ──────────────────────────────────
# A mirror-tracker-defenses job must exist in per-branch-review.yml so that
# defense records are fetched and posted to the PR before the review job runs.
# Bug 6345-62be: review executed before defenses were mirrored, so the reviewer
# could not account for existing defenses from prior cycles.
_snapshot_fail
if [[ ! -f "$WORKFLOW_FILE" ]]; then
    assert_eq "test_mirror_tracker_defenses_job_exists: workflow file present (prereq)" "1" "0"
else
    found=0
    grep -qE "^\s+mirror-tracker-defenses:" "$WORKFLOW_FILE" 2>/dev/null && found=1 || true
    assert_eq "test_mirror_tracker_defenses_job_exists: per-branch-review.yml has mirror-tracker-defenses job" "1" "$found"
fi
assert_pass_if_clean "test_mirror_tracker_defenses_job_exists"

# ── test_review_needs_mirror_tracker_defenses ─────────────────────────────────
# The review job's needs list must include mirror-tracker-defenses, ensuring
# defense mirroring completes before LLM review begins.
# Bug 6345-62be: without this dependency the review job runs concurrently with
# (or before) defense mirroring.
_snapshot_fail
if [[ ! -f "$WORKFLOW_FILE" ]]; then
    assert_eq "test_review_needs_mirror_tracker_defenses: workflow file present (prereq)" "1" "0"
else
    # Extract the needs list from the review job and check for mirror-tracker-defenses
    found=0
    # Use awk to extract the needs block under the review job
    awk '/^  review:/{found_review=1} found_review && /needs:/{found_needs=1} found_review && found_needs && /mirror-tracker-defenses/{print; exit}' \
        "$WORKFLOW_FILE" 2>/dev/null | grep -q "mirror-tracker-defenses" && found=1 || true
    assert_eq "test_review_needs_mirror_tracker_defenses: review job needs includes mirror-tracker-defenses" "1" "$found"
fi
assert_pass_if_clean "test_review_needs_mirror_tracker_defenses"

# ── test_resolve_diff_base_step_present ──────────────────────────────────────
# Bug 3914-0848-faad-4f6a: diff base must come from the PR's actual base,
# not solely from SPRINT_SESSION_ID. The workflow must have a "Resolve diff
# base" step that looks up the open PR via gh.
_snapshot_fail
if [[ ! -f "$WORKFLOW_FILE" ]]; then
    assert_eq "test_resolve_diff_base_step_present: workflow file present (prereq)" "1" "0"
else
    found=0
    grep -qE "name:\s+Resolve diff base" "$WORKFLOW_FILE" 2>/dev/null && found=1 || true
    assert_eq "test_resolve_diff_base_step_present: workflow has 'Resolve diff base' step" "1" "$found"
fi
assert_pass_if_clean "test_resolve_diff_base_step_present"

# ── test_resolve_diff_base_uses_pr_lookup ────────────────────────────────────
# The resolve step must call gh to look up an open PR's baseRefName.
_snapshot_fail
if [[ ! -f "$WORKFLOW_FILE" ]]; then
    assert_eq "test_resolve_diff_base_uses_pr_lookup: workflow file present (prereq)" "1" "0"
else
    found=0
    grep -qE "gh pr list.*baseRefName|gh pr view.*baseRefName" "$WORKFLOW_FILE" 2>/dev/null && found=1 || true
    assert_eq "test_resolve_diff_base_uses_pr_lookup: workflow looks up PR baseRefName via gh" "1" "$found"
fi
assert_pass_if_clean "test_resolve_diff_base_uses_pr_lookup"

# ── test_resolve_diff_base_has_fallback_chain ────────────────────────────────
# The resolve step must reference both SPRINT_SESSION_ID (legacy fallback)
# and "main" (final safety net), so the chain is PR base → variable → main.
_snapshot_fail
if [[ ! -f "$WORKFLOW_FILE" ]]; then
    assert_eq "test_resolve_diff_base_has_fallback_chain: workflow file present (prereq)" "1" "0"
else
    found_session=0; found_main=0
    awk '/Resolve diff base/{flag=1; next} flag && /^\s*-\s+name:/{exit} flag' "$WORKFLOW_FILE" 2>/dev/null > /tmp/_resolve_step.txt
    grep -q "SPRINT_SESSION_ID" /tmp/_resolve_step.txt 2>/dev/null && found_session=1
    grep -qw "main" /tmp/_resolve_step.txt 2>/dev/null && found_main=1
    rm -f /tmp/_resolve_step.txt
    assert_eq "test_resolve_diff_base_has_fallback_chain: resolve step references SPRINT_SESSION_ID fallback" "1" "$found_session"
    assert_eq "test_resolve_diff_base_has_fallback_chain: resolve step references main as final fallback" "1" "$found_main"
fi
assert_pass_if_clean "test_resolve_diff_base_has_fallback_chain"

# ── test_suspicious_diff_warning_present ─────────────────────────────────────
# A scoped per-story review producing a multi-thousand-line diff is a smell.
# The compute step must emit a GitHub Actions warning when the diff exceeds
# a threshold so operators are alerted to BASE_REF mis-resolution.
_snapshot_fail
if [[ ! -f "$WORKFLOW_FILE" ]]; then
    assert_eq "test_suspicious_diff_warning_present: workflow file present (prereq)" "1" "0"
else
    found=0
    grep -qE "::warning::|DIFF_LINES" "$WORKFLOW_FILE" 2>/dev/null && found=1 || true
    assert_eq "test_suspicious_diff_warning_present: workflow emits a warning on suspiciously large diff" "1" "$found"
fi
assert_pass_if_clean "test_suspicious_diff_warning_present"

print_summary
