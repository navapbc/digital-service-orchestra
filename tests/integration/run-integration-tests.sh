#!/usr/bin/env bash
# tests/integration/run-integration-tests.sh
# Runs all integration tests; exits 0 if all pass or all skipped
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PASS=0 FAIL=0 SKIP=0

for test_file in "$SCRIPT_DIR"/test-*-integration.sh; do
    [[ -f "$test_file" ]] || continue
    echo "Running: $(basename "$test_file")"
    output=$(bash "$test_file" 2>&1)
    rc=$?
    # A file is a top-level SKIP only when: it has a SKIP: line AND no PASSED: line.
    # Per-function SKIP messages emit alongside PASSED: from print_summary; those
    # are normal pass/fail files and must not be miscounted as skipped.
    if echo "$output" | grep -q "^SKIP:" && ! echo "$output" | grep -q "^PASSED:"; then
        echo "  SKIPPED"
        (( ++SKIP ))
    elif [[ $rc -eq 0 ]]; then
        echo "  PASSED"
        (( ++PASS ))
    else
        echo "  FAILED"
        echo "$output"
        (( ++FAIL ))
    fi
done

echo ""
echo "Integration tests: PASSED=$PASS FAILED=$FAIL SKIPPED=$SKIP"
[[ $FAIL -eq 0 ]]
