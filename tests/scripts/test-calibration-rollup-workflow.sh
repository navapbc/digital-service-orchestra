#!/usr/bin/env bash
# tests/scripts/test-calibration-rollup-workflow.sh
# Validates that .github/workflows/calibration-rollup.yml is well-formed and
# satisfies the structural constraints defined by the calibration-rollup task.
#
# Tests:
#   1. test_workflow_file_exists
#      The calibration-rollup.yml file must exist at the expected path.
#   2. test_workflow_has_on_key
#      The workflow must contain the top-level `on:` trigger key.
#   3. test_workflow_has_push_trigger
#      The workflow must declare a `push:` trigger (fires on merge to main).
#   4. test_workflow_has_schedule_trigger
#      The workflow must declare a `schedule:` trigger for cron runs.
#   5. test_workflow_has_calibration_rollup_job
#      The workflow must define a job named `calibration-rollup:`.
#   6. test_workflow_uses_dso_shim
#      The workflow must invoke `.claude/scripts/dso` (the DSO shim).
#   7. test_workflow_no_literal_plugins_dso
#      The workflow must NOT contain the literal string `plugins/dso/`.
#
# Usage: bash tests/scripts/test-calibration-rollup-workflow.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
WORKFLOW_FILE="$REPO_ROOT/.github/workflows/calibration-rollup.yml"

# shellcheck source=../lib/assert.sh
source "$REPO_ROOT/tests/lib/assert.sh"

# =============================================================================
# Test 1: test_workflow_file_exists
# Given: the calibration-rollup.yml workflow has been created
# When:  checking for the file at .github/workflows/calibration-rollup.yml
# Then:  the file exists
# =============================================================================
echo ""
echo "--- test_workflow_file_exists ---"

_FILE_EXISTS="false"
if [[ -f "$WORKFLOW_FILE" ]]; then
    _FILE_EXISTS="true"
fi
assert_eq "test_workflow_file_exists" "true" "$_FILE_EXISTS"

# Remaining tests require the file to exist; skip them gracefully if missing.
if [[ "$_FILE_EXISTS" != "true" ]]; then
    echo "SKIP: workflow file not found — skipping content tests"
    print_summary
    exit 0
fi

# =============================================================================
# Test 2: test_workflow_has_on_key
# Given: calibration-rollup.yml exists
# When:  searching for the `on:` trigger block
# Then:  the file contains `on:` (top-level trigger key)
# =============================================================================
echo ""
echo "--- test_workflow_has_on_key ---"

_HAS_ON="false"
if grep -qF 'on:' "$WORKFLOW_FILE"; then
    _HAS_ON="true"
fi
assert_eq "test_workflow_has_on_key" "true" "$_HAS_ON"

# =============================================================================
# Test 3: test_workflow_has_push_trigger
# Given: calibration-rollup.yml exists
# When:  searching for the `push:` trigger
# Then:  the file contains `push:` so that merges to main fire the workflow
# =============================================================================
echo ""
echo "--- test_workflow_has_push_trigger ---"

_HAS_PUSH="false"
if grep -qF 'push:' "$WORKFLOW_FILE"; then
    _HAS_PUSH="true"
fi
assert_eq "test_workflow_has_push_trigger" "true" "$_HAS_PUSH"

# =============================================================================
# Test 4: test_workflow_has_schedule_trigger
# Given: calibration-rollup.yml exists
# When:  searching for the `schedule:` trigger
# Then:  the file contains `schedule:` for cron-based monthly/quarterly runs
# =============================================================================
echo ""
echo "--- test_workflow_has_schedule_trigger ---"

_HAS_SCHEDULE="false"
if grep -qF 'schedule:' "$WORKFLOW_FILE"; then
    _HAS_SCHEDULE="true"
fi
assert_eq "test_workflow_has_schedule_trigger" "true" "$_HAS_SCHEDULE"

# =============================================================================
# Test 5: test_workflow_has_calibration_rollup_job
# Given: calibration-rollup.yml exists
# When:  searching for the job identifier
# Then:  the file contains `calibration-rollup:` as the job key
# =============================================================================
echo ""
echo "--- test_workflow_has_calibration_rollup_job ---"

_HAS_JOB="false"
if grep -qF 'calibration-rollup:' "$WORKFLOW_FILE"; then
    _HAS_JOB="true"
fi
assert_eq "test_workflow_has_calibration_rollup_job" "true" "$_HAS_JOB"

# =============================================================================
# Test 6: test_workflow_uses_dso_shim
# Given: calibration-rollup.yml exists
# When:  searching for the DSO shim invocation
# Then:  the file uses `.claude/scripts/dso` (not the plugin path directly)
# =============================================================================
echo ""
echo "--- test_workflow_uses_dso_shim ---"

_HAS_SHIM="false"
if grep -qF '.claude/scripts/dso' "$WORKFLOW_FILE"; then
    _HAS_SHIM="true"
fi
assert_eq "test_workflow_uses_dso_shim" "true" "$_HAS_SHIM"

# =============================================================================
# Test 7: test_workflow_no_literal_plugins_dso
# Given: calibration-rollup.yml exists
# When:  searching for literal `plugins/dso/` references
# Then:  the file does NOT contain `plugins/dso/` (namespace policy compliance)
# =============================================================================
echo ""
echo "--- test_workflow_no_literal_plugins_dso ---"

_HAS_PLUGIN_REF="false"
if grep -qF 'plugins/dso/' "$WORKFLOW_FILE"; then
    _HAS_PLUGIN_REF="true"
fi
assert_eq "test_workflow_no_literal_plugins_dso" "false" "$_HAS_PLUGIN_REF"

# =============================================================================
# Test 8: test_workflow_has_concurrency_block
# Given: calibration-rollup.yml exists
# When:  searching for the `concurrency:` key
# Then:  the file contains `concurrency:` to serialize concurrent runs
# =============================================================================
echo ""
echo "--- test_workflow_has_concurrency_block ---"

_HAS_CONCURRENCY="false"
if grep -qF 'concurrency:' "$WORKFLOW_FILE"; then
    _HAS_CONCURRENCY="true"
fi
assert_eq "test_workflow_has_concurrency_block" "true" "$_HAS_CONCURRENCY"

# =============================================================================
# Test 9: test_workflow_concurrency_no_cancel
# Given: calibration-rollup.yml exists
# When:  searching for `cancel-in-progress: false`
# Then:  the file contains `cancel-in-progress: false` so queued jobs are not
#        dropped (prevents silent loss of append or rollup runs)
# =============================================================================
echo ""
echo "--- test_workflow_concurrency_no_cancel ---"

_HAS_NO_CANCEL="false"
if grep -qF 'cancel-in-progress: false' "$WORKFLOW_FILE"; then
    _HAS_NO_CANCEL="true"
fi
assert_eq "test_workflow_concurrency_no_cancel" "true" "$_HAS_NO_CANCEL"

# =============================================================================
print_summary
