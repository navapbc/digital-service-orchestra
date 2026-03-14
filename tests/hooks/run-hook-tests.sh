#!/usr/bin/env bash
# lockpick-workflow/tests/hooks/run-hook-tests.sh
# Aggregator: discovers and runs all hook test files in this directory.
# Uses suite-engine for parallel execution, per-test timeouts, fail-fast,
# and progress reporting.
#
# Usage: bash lockpick-workflow/tests/hooks/run-hook-tests.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail
#
# Environment (passed through to suite-engine):
#   TEST_TIMEOUT=30              Per-test timeout in seconds (default: 30)
#   MAX_PARALLEL=8               Max concurrent tests (default: 8)
#   MAX_CONSECUTIVE_FAILS=5      Abort after N consecutive failures (default: 5)

set -uo pipefail

# Disable commit signing for all test scripts — test repos create temporary
# git repos with local user config, but global commit.gpgsign=true causes
# "fatal: failed to write commit object" when the signing server is unavailable.
export GIT_CONFIG_COUNT=1
export GIT_CONFIG_KEY_0=commit.gpgsign
export GIT_CONFIG_VALUE_0=false

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$SCRIPT_DIR/../lib"

# Source the suite engine
source "$LIB_DIR/suite-engine.sh"

echo "=== Hook Tests ==="
echo ""

# Collect test files
test_files=()
for f in "$SCRIPT_DIR"/test-*.sh; do
    [ -f "$f" ] || continue
    test_files+=("$f")
done

if [ ${#test_files[@]} -eq 0 ]; then
    echo "No hook test files found."
    exit 0
fi

# Run via suite engine (parallel, with timeouts and fail-fast)
run_test_suite "Hook Tests" "${test_files[@]}"
suite_exit=$?

echo ""
echo "=== Hook Tests Summary ==="
printf "Hook Tests: PASSED: %d  FAILED: %d\n" "$SUITE_TOTAL_PASS" "$SUITE_TOTAL_FAIL"

exit $suite_exit
