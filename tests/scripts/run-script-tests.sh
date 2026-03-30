#!/usr/bin/env bash
# tests/scripts/run-script-tests.sh
# Aggregator: discovers and runs all script test files in this directory
# and the plugin/ directory. Uses suite-engine for parallel execution,
# per-test timeouts, fail-fast, and progress reporting.
#
# Usage: bash tests/scripts/run-script-tests.sh
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

# Ensure CLAUDE_PLUGIN_ROOT points to the plugin subdir for all tests.
# Plugin files live under plugins/dso/ after the dso-anlb restructure.
# Force-set to plugins/dso/ so dispatchers find hooks/lib/ at the right path.
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null)"
export CLAUDE_PLUGIN_ROOT="$REPO_ROOT/plugins/dso"

# Enable RED-zone tolerance — suite-engine reads SUITE_TEST_INDEX to tolerate
# failures in functions at/after the RED marker defined in .test-index.
# Only set if not already provided by the caller.
if [[ -z "${SUITE_TEST_INDEX:-}" ]] && [[ -f "$REPO_ROOT/.test-index" ]]; then
    export SUITE_TEST_INDEX="$REPO_ROOT/.test-index"
fi

# Bump timeout for heavyweight tests (e.g., test-sync-roundtrip.sh: 941 lines)
# dso-dcau: increased from 60→120 to prevent CPU-contention timeouts under
# full parallel suite execution (145+ concurrent processes). test-isolation-check.sh
# and test-isolation-rule-no-direct-os-environ.sh pass in <10s individually but
# exceeded the 60s budget when the host is under heavy parallel load.
: "${TEST_TIMEOUT:=120}"

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
