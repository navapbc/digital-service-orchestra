#!/usr/bin/env bash
# tests/workflows/test-sprint-story-review-defenses.sh
# RED-phase behavioral tests for GitHubPRDefenseStore wiring in sprint-story-review workflow.
#
# Story 957a-a331-b9ed-435c DD3 gap: second push reads prior attestations from
# GitHubPRDefenseStore and passes them to the runner via DSO_CI_REVIEW_PRIOR_DEFENSES_PATH.
#
# Task 28a0-aea2-5323-47b3: Write RED tests for PRIOR_DEFENSES_PATH env var wiring.
#
# Test 1 (PASS): runner exits 0 when DSO_CI_REVIEW_PRIOR_DEFENSES_PATH is set with DRY_RUN=1
# Test 2 (FAIL RED): workflow YAML must reference DSO_CI_REVIEW_PRIOR_DEFENSES_PATH
#
# Usage: bash tests/workflows/test-sprint-story-review-defenses.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
WORKFLOW_FILE="$REPO_ROOT/.github/workflows/sprint-story-review.yml"
RUNNER="$REPO_ROOT/plugins/dso/scripts/ci-llm-review-runner.sh"

source "$REPO_ROOT/tests/lib/assert.sh"

echo "=== test-sprint-story-review-defenses.sh ==="

# ── test_runner_accepts_prior_defenses_path_env ──────────────────────────────
# When DSO_CI_REVIEW_DRY_RUN=1 and DSO_CI_REVIEW_PRIOR_DEFENSES_PATH points to
# a valid JSON fixture, the runner must exit 0.
# Rationale: runner should not fail on presence of the new env var; dry-run mode
# returns empty findings immediately and validates no unknown-flag rejection.
_snapshot_fail
_tmpdir=$(mktemp -d /tmp/test-defenses.XXXXXX)
_diff_path="$_tmpdir/test.diff"
_fixture_path="$_tmpdir/prior-defenses.json"

# Minimal unified diff fixture (avoid printf with leading -- to prevent flag confusion)
{
    echo '--- a/test.sh'
    echo '+++ b/test.sh'
    echo '@@ -1 +1 @@'
    echo '-old line'
    echo '+new line'
} > "$_diff_path"

# Prior defenses fixture (what GitHubPRDefenseStore would provide)
printf '[{"severity": "important", "description": "test prior defense", "file_path": "test.sh"}]\n' > "$_fixture_path"

_runner_exit=0
DSO_CI_REVIEW_DRY_RUN=1 \
    DSO_CI_REVIEW_PRIOR_DEFENSES_PATH="$_fixture_path" \
    DSO_CI_REVIEW_DIFF_PATH="$_diff_path" \
    bash "$RUNNER" > /dev/null 2>&1 || _runner_exit=$?

assert_eq \
    "test_runner_accepts_prior_defenses_path_env: runner exits 0 when PRIOR_DEFENSES_PATH set with DRY_RUN=1" \
    "0" "$_runner_exit"

rm -rf "$_tmpdir"
assert_pass_if_clean "test_runner_accepts_prior_defenses_path_env"

# ── test_workflow_references_prior_defenses_path ─────────────────────────────
# The sprint-story-review.yml workflow must pass DSO_CI_REVIEW_PRIOR_DEFENSES_PATH
# as an environment variable to the ci-llm-review-runner.sh step.
# This test is RED because the workflow currently does NOT reference the var.
_snapshot_fail
if [[ ! -f "$WORKFLOW_FILE" ]]; then
    assert_eq "test_workflow_references_prior_defenses_path: workflow file present (prereq)" "1" "0"
else
    found=0
    grep -q 'DSO_CI_REVIEW_PRIOR_DEFENSES_PATH' "$WORKFLOW_FILE" 2>/dev/null && found=1 || true
    assert_eq \
        "test_workflow_references_prior_defenses_path: sprint-story-review.yml references DSO_CI_REVIEW_PRIOR_DEFENSES_PATH" \
        "1" "$found"
fi
assert_pass_if_clean "test_workflow_references_prior_defenses_path"

print_summary
