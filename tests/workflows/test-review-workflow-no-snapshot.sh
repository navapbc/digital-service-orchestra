#!/usr/bin/env bash
# test_review_workflow_no_snapshot_reference
# Asserts that REVIEW-WORKFLOW.md contains no references to snapshot file machinery
# (untracked-snapshot, SNAPSHOT_FILE, --snapshot flag) that was removed as part of
# the compute-diff-hash.sh refactor.

set -euo pipefail

REPO_ROOT=$(git rev-parse --show-toplevel)
WORKFLOW_FILE="$REPO_ROOT/lockpick-workflow/docs/workflows/REVIEW-WORKFLOW.md"

pass=0
fail=0

run_test() {
    local name="$1"
    local result="$2"
    if [ "$result" = "0" ]; then
        echo "PASS: $name"
        pass=$((pass + 1))
    else
        echo "FAIL: $name"
        fail=$((fail + 1))
    fi
}

# Test: no 'untracked-snapshot' reference
if ! grep -q 'untracked-snapshot' "$WORKFLOW_FILE"; then
    run_test "no untracked-snapshot reference" 0
else
    run_test "no untracked-snapshot reference" 1
fi

# Test: no 'SNAPSHOT_FILE' reference
if ! grep -q 'SNAPSHOT_FILE' "$WORKFLOW_FILE"; then
    run_test "no SNAPSHOT_FILE reference" 0
else
    run_test "no SNAPSHOT_FILE reference" 1
fi

# Test: no '--snapshot' flag reference
if ! grep -q -- '--snapshot' "$WORKFLOW_FILE"; then
    run_test "no --snapshot flag reference" 0
else
    run_test "no --snapshot flag reference" 1
fi

# Test: file exists and is non-empty
if [ -s "$WORKFLOW_FILE" ]; then
    run_test "REVIEW-WORKFLOW.md is non-empty" 0
else
    run_test "REVIEW-WORKFLOW.md is non-empty" 1
fi

# Test: DIFF_HASH computation is still present
if grep -q 'DIFF_HASH' "$WORKFLOW_FILE"; then
    run_test "DIFF_HASH computation preserved" 0
else
    run_test "DIFF_HASH computation preserved" 1
fi

echo ""
echo "Results: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
