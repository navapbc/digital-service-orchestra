#!/usr/bin/env bash
# tests/integration/test-run-integration-dedup.sh
# Verifies run-integration-tests.sh does not double-count test-ref-library.sh.
# RED before fix (count=2), GREEN after fix (count=1).
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUN_SCRIPT="$SCRIPT_DIR/run-integration-tests.sh"

output=$(bash "$RUN_SCRIPT" 2>&1)
count=$(echo "$output" | grep -c "^Running: test-ref-library\.sh" || true)

if [[ "$count" -eq 1 ]]; then
    echo "PASSED: test-ref-library.sh appears exactly once (count=$count)"
    exit 0
else
    echo "FAILED: test-ref-library.sh appeared $count time(s), expected exactly 1"
    echo "--- run-integration-tests.sh output ---"
    echo "$output"
    exit 1
fi
