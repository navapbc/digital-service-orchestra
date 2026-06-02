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

# 2. merge-pipeline-checks has an explicit merge_group if-arm.
_snapshot_fail
_mpc=$(grep -cE "event_name == 'merge_group'" "$WF/ci.yml" 2>/dev/null || true)
assert_ne "merge-pipeline-checks (ci.yml) has a merge_group if-arm" "0" "$_mpc"
assert_pass_if_clean "merge_pipeline_checks_merge_group_arm"

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

print_summary
