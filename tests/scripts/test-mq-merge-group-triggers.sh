#!/usr/bin/env bash
# tests/scripts/test-mq-merge-group-triggers.sh
#
# MQ-1 (ADR-0019): assert the merge_group trigger contract for the GitHub Merge
# Queue migration. The CI "which checks run on which event" contract is the
# observable behavior under test (there is no runtime to execute):
#   1. Every required-check workflow runs on `merge_group` so the queue's
#      combined candidate is gated by the same required checks.
#   2. The `merge-pipeline-checks` umbrella (which gates solely on base_ref)
#      has an explicit `merge_group` arm — without it the job never reports on
#      the queue branch and the queue silently rejects every entry.
#   3. The two backstop workflows derive their head SHA from the merge_group
#      event shape (`github.event.pull_request.*` is NULL on merge_group).
#   4. The LLM-review jobs stay pull_request-guarded — they must NEVER fire on
#      merge_group, so the large combined diff is never LLM-reviewed (the
#      primary goal: LLM reviews only the small sub-PR diffs).
#
# These are inert until Merge Queue is provisioned (no merge_group events fire
# without it), so MQ-1 is safe to land ahead of the rest of the migration.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
WF="$REPO_ROOT/.github/workflows"

source "$REPO_ROOT/tests/lib/assert.sh"

echo "=== test-mq-merge-group-triggers.sh ==="

# 1. Required-check workflows trigger on merge_group.
for f in ci.yml ticket-platform-matrix.yml ruleset-invariants.yml review-coverage-invariant.yml dangling-references.yml; do
    _snapshot_fail
    _has=$(grep -cE '^[[:space:]]*merge_group:' "$WF/$f" 2>/dev/null || true)
    assert_ne "merge_group trigger present in $f" "0" "$_has"
    assert_pass_if_clean "merge_group_trigger_${f%.yml}"
done

# 2. merge-pipeline-checks silent-rejection invariant — checked in LOCKSTEP.
#    The job's merge_group if-arm is useless without ci.yml's workflow-level
#    merge_group trigger (the job is never evaluated on the queue branch), and
#    the workflow-level trigger without the arm leaves merge-pipeline-checks
#    gating solely on base_ref so it never reports on the queue = silent
#    rejection of every entry. Assert BOTH in one check so neither can be
#    removed in isolation (the exact trap ADR-0019 migration step 2 warns of).
_snapshot_fail
_wf_trigger=$(grep -cE '^[[:space:]]*merge_group:' "$WF/ci.yml" 2>/dev/null || true)
_mpc_arm=$(grep -cE "event_name == 'merge_group'" "$WF/ci.yml" 2>/dev/null || true)
assert_ne "ci.yml declares the workflow-level merge_group trigger (lockstep)" "0" "$_wf_trigger"
assert_ne "merge-pipeline-checks has its merge_group if-arm (lockstep)" "0" "$_mpc_arm"
assert_pass_if_clean "merge_pipeline_checks_silent_rejection_lockstep"

# 3. Backstop workflows derive head SHA from the merge_group event shape.
for f in review-coverage-invariant.yml dangling-references.yml; do
    _snapshot_fail
    _ea=$(grep -cE 'github\.event\.merge_group\.head_sha' "$WF/$f" 2>/dev/null || true)
    assert_ne "$f derives head SHA from the merge_group event shape" "0" "$_ea"
    assert_pass_if_clean "event_aware_sha_${f%.yml}"
done

# 4. The LLM-review jobs stay pull_request-guarded (never fire on merge_group).
_snapshot_fail
_subpr=$(grep -cE "event_name == 'pull_request' && github\.base_ref != 'main'" "$WF/ci.yml" 2>/dev/null || true)
_llm=$(grep -cE "event_name == 'pull_request' && github\.base_ref == 'main'" "$WF/ci.yml" 2>/dev/null || true)
assert_ne "review-sub-pr job stays pull_request-only (off merge_group)" "0" "$_subpr"
assert_ne "llm-review job stays pull_request-only (off merge_group)" "0" "$_llm"
assert_pass_if_clean "llm_review_jobs_stay_pull_request_only"

# 5. cancel-in-progress must NOT cancel merge_group runs — a cancellation evicts
#    the queue entry. The required workflows guard it on the event being non-merge_group.
#
# Test level: this is a STRUCTURAL assertion (the guard expression is declared in
# the workflow YAML), which is the correct and only feasible unit-test level for a
# GitHub Actions concurrency expression — its RUNTIME evaluation belongs to GitHub
# Actions, not to a shell unit test. Behavioral validation of the merge_group
# lifecycle (event fires on the combined candidate, required checks report,
# green→fast-forward / red→blocked) was performed empirically against a live
# merge_queue ruleset during the de-risk spike and is recorded in
# docs/adr/0019-github-merge-queue-for-staged-to-main.md. The structural assertion
# here pins the declaration against accidental removal; the spike covers behavior.
for f in ci.yml ticket-platform-matrix.yml; do
    _snapshot_fail
    # Anchor at line start (optional indent, no leading '#') so a commented-out or
    # documentation-block occurrence of the pattern is NOT counted as the guard.
    _cip=$(grep -cE "^[[:space:]]*cancel-in-progress:[[:space:]]*\\\$\{\{[[:space:]]*github\.event_name != 'merge_group'" "$WF/$f" 2>/dev/null || true)
    assert_ne "$f declares the cancel-in-progress merge_group guard (uncommented)" "0" "$_cip"
    assert_pass_if_clean "cancel_in_progress_guards_merge_group_${f%.yml}"
done

print_summary
