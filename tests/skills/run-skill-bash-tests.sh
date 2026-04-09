#!/usr/bin/env bash
# tests/skills/run-skill-bash-tests.sh
# Aggregator: discovers and runs all bash skill test files in tests/skills/.
# Uses suite-engine for parallel execution, per-test timeouts, fail-fast,
# and progress reporting.
#
# Usage: bash tests/skills/run-skill-bash-tests.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail
#
# Environment (passed through to suite-engine):
#   TEST_TIMEOUT=60/90           Per-test timeout in seconds (60 local, 90 CI)
#   MAX_PARALLEL=8               Max concurrent tests (default: 8)
#   MAX_CONSECUTIVE_FAILS=5      Abort after N consecutive failures (default: 5)

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$SCRIPT_DIR/../lib"

# Ensure CLAUDE_PLUGIN_ROOT points to the plugin subdir for all tests.
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null)"
export CLAUDE_PLUGIN_ROOT="$REPO_ROOT/plugins/dso"

# Enable RED-zone tolerance — suite-engine reads SUITE_TEST_INDEX to tolerate
# failures in functions at/after the RED marker defined in .test-index.
if [[ -z "${SUITE_TEST_INDEX:-}" ]] && [[ -f "$REPO_ROOT/.test-index" ]]; then
    export SUITE_TEST_INDEX="$REPO_ROOT/.test-index"
fi

# Per-test timeout — CI runners have less CPU than local dev.
if [[ "${CI:-}" == "true" ]]; then
    : "${TEST_TIMEOUT:=90}"
else
    : "${TEST_TIMEOUT:=60}"
fi

# Source the suite engine
source "$LIB_DIR/suite-engine.sh"

echo "=== Skill Bash Tests ==="
echo ""

# Collect test-*.sh files from tests/skills/ (excludes run-*.sh and run-python-tests.sh)
test_files=()
for f in "$SCRIPT_DIR"/test-*.sh; do
    [ -f "$f" ] || continue
    test_files+=("$f")
done

if [ ${#test_files[@]} -eq 0 ]; then
    echo "No skill bash test files found."
    exit 0
fi

# Run via suite engine (parallel, with timeouts and fail-fast)
run_test_suite "Skill Bash Tests" "${test_files[@]}"
suite_exit=$?

echo ""
echo "=== Skill Bash Tests Summary ==="
printf "Skill Bash Tests: PASSED: %d  FAILED: %d\n" "$SUITE_TOTAL_PASS" "$SUITE_TOTAL_FAIL"

exit $suite_exit
