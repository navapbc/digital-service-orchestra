#!/usr/bin/env bash
# lockpick-workflow/tests/hooks/run-hook-tests.sh
# Aggregator: discovers and runs all hook test files in this directory.
# Tracks cumulative pass/fail counts; exits non-zero if any test fails.
#
# Usage: bash lockpick-workflow/tests/hooks/run-hook-tests.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -uo pipefail

# Disable commit signing for all test scripts — test repos create temporary
# git repos with local user config, but global commit.gpgsign=true causes
# "fatal: failed to write commit object" when the signing server is unavailable.
export GIT_CONFIG_COUNT=1
export GIT_CONFIG_KEY_0=commit.gpgsign
export GIT_CONFIG_VALUE_0=false

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

TOTAL_PASS=0
TOTAL_FAIL=0

echo "=== Hook Tests ==="
echo ""

for f in "$SCRIPT_DIR"/test-*.sh; do
    [ -f "$f" ] || continue
    test_name=$(basename "$f")
    echo "--- $test_name ---"
    file_exit=0
    output=$(bash "$f" </dev/null 2>&1) || file_exit=$?
    echo "$output"

    # Parse PASS/FAIL counts from output.
    # Handles multiple summary line formats used by hook test files:
    #   "Results: N passed, N failed"           (test-post-tool-use-hooks.sh, test-record-review-crossval.sh)
    #   "Results: N/N passed"                   (test-validation-gate.sh — no explicit failed count)
    #   "PASSED: N  FAILED: N"                  (assert.sh pattern)
    # Strip ANSI color codes before parsing (test-post-tool-use-hooks.sh uses colors).
    clean_output=$(echo "$output" | sed 's/\x1b\[[0-9;]*m//g')

    # Try "Results: N passed, N failed" format first
    results_line=$(echo "$clean_output" | grep -E "Results:.*[0-9]+ passed" | tail -1 || true)
    if [ -n "$results_line" ]; then
        file_pass=$(echo "$results_line" | grep -oE "[0-9]+ passed" | grep -oE "[0-9]+" || echo 0)
        file_fail=$(echo "$results_line" | grep -oE "[0-9]+ failed" | grep -oE "[0-9]+" || echo 0)
        TOTAL_PASS=$(( TOTAL_PASS + file_pass ))
        TOTAL_FAIL=$(( TOTAL_FAIL + file_fail ))
    else
        # Try "PASSED: N  FAILED: N" format (assert.sh)
        summary_line=$(echo "$clean_output" | grep -E "^PASSED: [0-9]+  FAILED: [0-9]+" | tail -1 || true)
        if [ -n "$summary_line" ]; then
            file_pass=$(echo "$summary_line" | grep -oE "PASSED: [0-9]+" | grep -oE "[0-9]+" || echo 0)
            file_fail=$(echo "$summary_line" | grep -oE "FAILED: [0-9]+" | grep -oE "[0-9]+" || echo 0)
            TOTAL_PASS=$(( TOTAL_PASS + file_pass ))
            TOTAL_FAIL=$(( TOTAL_FAIL + file_fail ))
        elif [ "$file_exit" -ne 0 ]; then
            # No recognized summary line and non-zero exit: count the file as 1 failure
            (( TOTAL_FAIL++ ))
        fi
    fi

    echo ""
done

echo "=== Hook Tests Summary ==="
printf "Hook Tests: PASSED: %d  FAILED: %d\n" "$TOTAL_PASS" "$TOTAL_FAIL"

if [ "$TOTAL_FAIL" -gt 0 ]; then
    exit 1
fi
exit 0
