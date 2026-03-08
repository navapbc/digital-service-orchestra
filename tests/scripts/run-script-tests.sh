#!/usr/bin/env bash
# lockpick-workflow/tests/scripts/run-script-tests.sh
# Aggregator: discovers and runs all script test files in this directory.
# Tracks cumulative pass/fail counts; exits non-zero if any test fails.
#
# Usage: bash lockpick-workflow/tests/scripts/run-script-tests.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

TOTAL_PASS=0
TOTAL_FAIL=0

echo "=== Script Tests ==="
echo ""

for f in "$SCRIPT_DIR"/test-*.sh; do
    [ -f "$f" ] || continue
    test_name=$(basename "$f")
    echo "--- $test_name ---"
    file_exit=0
    output=$(bash "$f" 2>&1) || file_exit=$?
    echo "$output"

    # Parse PASS/FAIL counts from output.
    # Two formats: "Results: N passed, N failed" and "PASSED: N  FAILED: N" (assert.sh)
    results_line=$(echo "$output" | grep -E "^Results:" | tail -1 || true)
    summary_line=$(echo "$output" | grep -E "^PASSED: [0-9]" | tail -1 || true)
    if [ -n "$results_line" ]; then
        file_pass=$(echo "$results_line" | grep -oE "[0-9]+ passed" | grep -oE "[0-9]+" || echo 0)
        file_fail=$(echo "$results_line" | grep -oE "[0-9]+ failed" | grep -oE "[0-9]+" || echo 0)
        TOTAL_PASS=$(( TOTAL_PASS + file_pass ))
        TOTAL_FAIL=$(( TOTAL_FAIL + file_fail ))
    elif [ -n "$summary_line" ]; then
        file_pass=$(echo "$summary_line" | grep -oE "PASSED: [0-9]+" | grep -oE "[0-9]+" || echo 0)
        file_fail=$(echo "$summary_line" | grep -oE "FAILED: [0-9]+" | grep -oE "[0-9]+" || echo 0)
        TOTAL_PASS=$(( TOTAL_PASS + file_pass ))
        TOTAL_FAIL=$(( TOTAL_FAIL + file_fail ))
    elif [ "$file_exit" -ne 0 ]; then
        # If no parseable summary and non-zero exit, count the file as 1 failure
        (( TOTAL_FAIL++ ))
    fi

    echo ""
done

echo "=== Script Tests Summary ==="
printf "Script Tests: PASSED: %d  FAILED: %d\n" "$TOTAL_PASS" "$TOTAL_FAIL"

if [ "$TOTAL_FAIL" -gt 0 ]; then
    exit 1
fi
exit 0
