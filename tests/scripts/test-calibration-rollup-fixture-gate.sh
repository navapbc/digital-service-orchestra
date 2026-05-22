#!/usr/bin/env bash
# tests/scripts/test-calibration-rollup-fixture-gate.sh
# Validates that .github/workflows/calibration-rollup.yml contains the
# fixture correctness check step required by task 2d3c-86e8-f890-48c7.
#
# Tests:
#   1. test_workflow_file_exists
#      The calibration-rollup.yml file must exist at the expected path.
#   2. test_workflow_has_fixture_step_name
#      The workflow must contain the step name "Fixture correctness check".
#   3. test_workflow_invokes_e2e_test
#      The workflow must invoke test-calibration-attribution-e2e.sh.
#
# Usage: bash tests/scripts/test-calibration-rollup-fixture-gate.sh

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
# Test 2: test_workflow_has_fixture_step_name
# Given: calibration-rollup.yml exists
# When:  searching for the fixture correctness check step name
# Then:  the file contains "Fixture correctness check" so that the pre-check
#        step is present and identifiable in CI logs
# =============================================================================
echo ""
echo "--- test_workflow_has_fixture_step_name ---"

_HAS_STEP_NAME="false"
if grep -qF 'Fixture correctness check' "$WORKFLOW_FILE"; then
    _HAS_STEP_NAME="true"
fi
assert_eq "test_workflow_has_fixture_step_name" "true" "$_HAS_STEP_NAME"

# =============================================================================
# Test 3: test_workflow_invokes_e2e_test
# Given: calibration-rollup.yml exists
# When:  searching for the E2E test script invocation
# Then:  the file contains "test-calibration-attribution-e2e.sh" so that the
#        fixture E2E test is wired into CI and will fail the job on failure
# =============================================================================
echo ""
echo "--- test_workflow_invokes_e2e_test ---"

_HAS_E2E_INVOCATION="false"
if grep -qF 'test-calibration-attribution-e2e.sh' "$WORKFLOW_FILE"; then
    _HAS_E2E_INVOCATION="true"
fi
assert_eq "test_workflow_invokes_e2e_test" "true" "$_HAS_E2E_INVOCATION"

# =============================================================================
print_summary
