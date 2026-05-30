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
#   TEST_TIMEOUT=60/120          Per-test timeout in seconds (60 local, 120 CI)
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

# Per-test timeout — most tests finish in <5s. The slot-refill scheduler
# (suite-engine.sh) reduces CPU contention vs the old batch-wait approach,
# so the 120s budget is no longer needed. CI runners have less CPU than
# local dev, so use a higher ceiling there.
if [[ "${CI:-}" == "true" ]]; then
    : "${TEST_TIMEOUT:=120}"
else
    : "${TEST_TIMEOUT:=60}"
fi

# Source the suite engine
source "$LIB_DIR/suite-engine.sh"

echo "=== Script Tests ==="
echo ""

# Collect test files from scripts/, plugin/, and scratch/
# scratch/ tests cover the ticket-scratch CLI surface and the 5-site migration.
# Glob is `test[-_]*.sh` (both hyphen and underscore): underscore-named files
# (e.g. test_write_cycle_ledger_v110.sh) were previously matched by neither
# this runner nor the mktemp-tmpdir lint, so they ran nowhere (external review
# Finding 6 part 4). NOTE: tests/unit/scripts/ remains an orphaned directory
# wired to no runner — see ticket fb67-ead2-6819-4c12; do not assume coverage
# of files there.
SCRATCH_DIR="$(cd "$SCRIPT_DIR/../scratch" 2>/dev/null && pwd || echo "")"
test_files=()
for f in "$SCRIPT_DIR"/test[-_]*.sh "$PLUGIN_DIR"/test[-_]*.sh ${SCRATCH_DIR:+"$SCRATCH_DIR"/test[-_]*.sh}; do
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
