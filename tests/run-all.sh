#!/usr/bin/env bash
# lockpick-workflow/tests/run-all.sh
# Top-level regression runner: orchestrates all plugin test suites.
#
# Runs:
#   1. lockpick-workflow/tests/evals/run-evals.sh
#   2. lockpick-workflow/tests/hooks/run-hook-tests.sh
#   3. lockpick-workflow/tests/scripts/run-script-tests.sh
#
# Produces a combined PASS/FAIL summary across all suites.
# Exits 0 only if ALL suites exit 0; exits 1 otherwise.
#
# Note: test-estimate-context-load.sh (pre-existing in lockpick-workflow/tests/)
# uses its own pass/fail helpers, not assert.sh. It is excluded from this
# orchestrator because it is a standalone test that predates the suite structure
# and its output format is incompatible with the suite runner aggregation.
# Run it separately: bash lockpick-workflow/tests/test-estimate-context-load.sh
#
# Usage:
#   bash lockpick-workflow/tests/run-all.sh
#
# Override individual suite runners (used by tests):
#   bash lockpick-workflow/tests/run-all.sh \
#     --hooks-runner /path/to/mock-hooks.sh \
#     --scripts-runner /path/to/mock-scripts.sh \
#     --evals-runner /path/to/mock-evals.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null)"

# --- Default suite runner paths ---
HOOKS_RUNNER="$REPO_ROOT/lockpick-workflow/tests/hooks/run-hook-tests.sh"
SCRIPTS_RUNNER="$REPO_ROOT/lockpick-workflow/tests/scripts/run-script-tests.sh"
EVALS_RUNNER="$REPO_ROOT/lockpick-workflow/tests/evals/run-evals.sh"

# --- Parse optional overrides (for TDD mock injection) ---
while [[ $# -gt 0 ]]; do
    case "$1" in
        --hooks-runner)
            HOOKS_RUNNER="$2"; shift 2 ;;
        --scripts-runner)
            SCRIPTS_RUNNER="$2"; shift 2 ;;
        --evals-runner)
            EVALS_RUNNER="$2"; shift 2 ;;
        *)
            echo "Unknown argument: $1" >&2; exit 1 ;;
    esac
done

# --- Run a suite and capture its exit code ---
# Usage: run_suite <label> <runner_path>
# Prints the suite output, returns the exit code via SUITE_EXIT variable.
SUITE_EXIT=0
run_suite() {
    local label="$1"
    local runner="$2"
    echo ""
    echo "========================================"
    echo "Suite: $label"
    echo "========================================"
    SUITE_EXIT=0
    bash "$runner" || SUITE_EXIT=$?
    return 0
}

# --- Tracking ---
EVALS_EXIT=0
HOOKS_EXIT=0
SCRIPTS_EXIT=0

# --- Run evals suite ---
run_suite "Evals" "$EVALS_RUNNER"
EVALS_EXIT=$SUITE_EXIT

# --- Run hooks suite ---
run_suite "Hook Tests" "$HOOKS_RUNNER"
HOOKS_EXIT=$SUITE_EXIT

# --- Run scripts suite ---
run_suite "Script Tests" "$SCRIPTS_RUNNER"
SCRIPTS_EXIT=$SUITE_EXIT

# --- Combined summary ---
echo ""
echo "========================================"
echo "=== Run-All Combined Summary ==="
echo "========================================"

suite_pass() { [ "$1" -eq 0 ] && echo "PASS" || echo "FAIL"; }

printf "  Evals:        %s\n" "$(suite_pass $EVALS_EXIT)"
printf "  Hook Tests:   %s\n" "$(suite_pass $HOOKS_EXIT)"
printf "  Script Tests: %s\n" "$(suite_pass $SCRIPTS_EXIT)"
echo ""

OVERALL_EXIT=0
if [ "$EVALS_EXIT" -ne 0 ] || [ "$HOOKS_EXIT" -ne 0 ] || [ "$SCRIPTS_EXIT" -ne 0 ]; then
    OVERALL_EXIT=1
fi

if [ "$OVERALL_EXIT" -eq 0 ]; then
    echo "Overall: PASS — all suites green"
else
    echo "Overall: FAIL — one or more suites failed"
fi

exit "$OVERALL_EXIT"
