#!/usr/bin/env bash
# lockpick-workflow/tests/scripts/run-script-tests.sh
# Aggregator: discovers and runs all script test files in this directory
# and the plugin/ directory. Uses suite-engine for parallel execution,
# per-test timeouts, fail-fast, and progress reporting.
#
# Usage: bash lockpick-workflow/tests/scripts/run-script-tests.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail
#
# Environment (passed through to suite-engine):
#   TEST_TIMEOUT=30              Per-test timeout in seconds (default: 30)
#   MAX_PARALLEL=8               Max concurrent tests (default: 8)
#   MAX_CONSECUTIVE_FAILS=5      Abort after N consecutive failures (default: 5)

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_DIR="$(cd "$SCRIPT_DIR/../plugin" && pwd)"
LIB_DIR="$SCRIPT_DIR/../lib"

# Bump timeout for heavyweight tests (e.g., test-sync-roundtrip.sh: 941 lines)
: "${TEST_TIMEOUT:=60}"

# Source the suite engine
source "$LIB_DIR/suite-engine.sh"

echo "=== Script Tests ==="
echo ""

# Collect test files from scripts/ and plugin/
test_files=()
for f in "$SCRIPT_DIR"/test-*.sh "$PLUGIN_DIR"/test-*.sh; do
    [ -f "$f" ] || continue
    test_files+=("$f")
done

if [ ${#test_files[@]} -eq 0 ]; then
    echo "No script test files found."
    exit 0
fi

# Run via suite engine (parallel, with timeouts and fail-fast)
run_test_suite "Script Tests" "${test_files[@]}"
suite_exit=$?

echo ""
echo "=== Script Tests Summary ==="
printf "Script Tests: PASSED: %d  FAILED: %d\n" "$SUITE_TOTAL_PASS" "$SUITE_TOTAL_FAIL"

exit $suite_exit
