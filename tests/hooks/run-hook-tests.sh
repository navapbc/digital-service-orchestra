#!/usr/bin/env bash
# tests/hooks/run-hook-tests.sh
# Aggregator: discovers and runs all hook test files in this directory.
# Uses suite-engine for parallel execution, per-test timeouts, fail-fast,
# and progress reporting.
#
# Usage: bash tests/hooks/run-hook-tests.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail
#
# Environment (passed through to suite-engine):
#   TEST_TIMEOUT=120             Per-test timeout in seconds (default: 120)
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

# Ensure CLAUDE_PLUGIN_ROOT points to the plugin subdir for all tests.
# Plugin files live under plugins/dso/ after the dso-anlb restructure.
# Force-set so dispatchers find hooks/lib/ at the right path.
_RUN_HOOK_REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null)"
export CLAUDE_PLUGIN_ROOT="$_RUN_HOOK_REPO_ROOT/plugins/dso"

# Enable RED-zone tolerance — suite-engine reads SUITE_TEST_INDEX to tolerate
# failures in functions at/after the RED marker defined in .test-index.
# Only set if not already provided by the caller.
if [[ -z "${SUITE_TEST_INDEX:-}" ]] && [[ -f "$_RUN_HOOK_REPO_ROOT/.test-index" ]]; then
    export SUITE_TEST_INDEX="$_RUN_HOOK_REPO_ROOT/.test-index"
fi

# Increase per-test timeout — behavioral-equivalence-allowlist and similar
# tests take ~13s standalone; under CPU contention in the parallel suite they
# can exceed the suite-engine default of 30s (same fix as run-script-tests.sh
# applied for dso-dcau isolation timeouts).
: "${TEST_TIMEOUT:=120}"
export TEST_TIMEOUT

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
