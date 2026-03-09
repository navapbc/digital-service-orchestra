#!/usr/bin/env bash
# lockpick-workflow/tests/run-all.sh
# Top-level regression runner: orchestrates all plugin test suites.
#
# Runs (hooks and scripts concurrently, evals after both complete):
#   1. lockpick-workflow/tests/hooks/run-hook-tests.sh  \  concurrent
#   2. lockpick-workflow/tests/scripts/run-script-tests.sh  /
#   3. lockpick-workflow/tests/evals/run-evals.sh
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

# --- Run a suite, capturing output to a temp file for clean sequential display ---
# Usage: run_suite_to_file <label> <runner_path> <outfile> <exitfile>
# Writes suite output to <outfile> and exit code to <exitfile>.
run_suite_to_file() {
    local label="$1"
    local runner="$2"
    local outfile="$3"
    local exitfile="$4"
    {
        echo ""
        echo "========================================"
        echo "Suite: $label"
        echo "========================================"
        bash "$runner"
    } >"$outfile" 2>&1
    echo $? >"$exitfile"
}

# --- Tracking ---
EVALS_EXIT=0
HOOKS_EXIT=0
SCRIPTS_EXIT=0

# --- Temp files for parallel suite output and exit codes ---
_HOOKS_OUT=$(mktemp)
_HOOKS_EXIT_FILE=$(mktemp)
_SCRIPTS_OUT=$(mktemp)
_SCRIPTS_EXIT_FILE=$(mktemp)

# --- Run hooks and scripts suites concurrently ---
run_suite_to_file "Hook Tests" "$HOOKS_RUNNER" "$_HOOKS_OUT" "$_HOOKS_EXIT_FILE" &
_HOOKS_PID=$!
run_suite_to_file "Script Tests" "$SCRIPTS_RUNNER" "$_SCRIPTS_OUT" "$_SCRIPTS_EXIT_FILE" &
_SCRIPTS_PID=$!

wait "$_HOOKS_PID"
wait "$_SCRIPTS_PID"

# Print captured output sequentially for readable logs
cat "$_HOOKS_OUT"
cat "$_SCRIPTS_OUT"

HOOKS_EXIT=$(cat "$_HOOKS_EXIT_FILE")
SCRIPTS_EXIT=$(cat "$_SCRIPTS_EXIT_FILE")
rm -f "$_HOOKS_OUT" "$_HOOKS_EXIT_FILE" "$_SCRIPTS_OUT" "$_SCRIPTS_EXIT_FILE"

# --- Run evals suite after parallel suites complete ---
echo ""
echo "========================================"
echo "Suite: Evals"
echo "========================================"
bash "$EVALS_RUNNER" || EVALS_EXIT=$?

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
