#!/usr/bin/env bash
# tests/scripts/test-inbound-bridge-push-retry.sh
# Assert that the inbound-bridge workflow's "Commit CREATE events" step
# uses a fetch-rebase-push retry loop instead of a plain git push.
#
# Bug: d411-c0e7 — push rejected when tickets branch updated concurrently
# (outbound-bridge or merge-to-main running at the same time).
#
# Tests covered:
#   1. test_commit_step_has_retry_loop — retry keyword present
#   2. test_commit_step_has_fetch_before_push — fetch origin tickets in commit step
#   3. test_commit_step_has_rebase — rebase origin/tickets in commit step
#   4. test_commit_step_no_plain_push — push is inside a retry loop, not bare
#
# Usage: bash tests/scripts/test-inbound-bridge-push-retry.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

source "$REPO_ROOT/tests/lib/assert.sh"

echo "=== test-inbound-bridge-push-retry.sh ==="

WORKFLOW="$REPO_ROOT/.github/workflows/inbound-bridge.yml"

# Extract the "Commit CREATE events back to tickets branch" step's run block.
COMMIT_STEP_RUN=$(python3 -c "
import yaml, sys
with open('$WORKFLOW') as f:
    wf = yaml.safe_load(f)
steps = wf['jobs']['bridge']['steps']
for step in steps:
    if 'Commit CREATE' in step.get('name', ''):
        print(step.get('run', ''))
        sys.exit(0)
print('STEP_NOT_FOUND')
sys.exit(1)
" 2>/dev/null) || {
    echo "FAIL: Could not parse workflow YAML"
    exit 1
}

# 1. test_commit_step_has_retry_loop
assert_contains "test_commit_step_has_retry_loop" "retry" "$COMMIT_STEP_RUN"

# 2. test_commit_step_has_fetch_before_push
assert_contains "test_commit_step_has_fetch_before_push" "fetch origin tickets" "$COMMIT_STEP_RUN"

# 3. test_commit_step_has_rebase
assert_contains "test_commit_step_has_rebase" "rebase" "$COMMIT_STEP_RUN"

# 4. test_commit_step_no_plain_push — push should be inside a while/for retry loop
if [[ "$COMMIT_STEP_RUN" =~ while|for.*retry|max_.*retries ]]; then
    echo "PASS: test_commit_step_no_plain_push"
    (( ++PASS ))
else
    echo "FAIL: test_commit_step_no_plain_push — push should be inside a retry loop" >&2
    (( ++FAIL ))
fi

print_summary
