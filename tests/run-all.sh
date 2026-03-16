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
# Process cleanup: uses session-safe PID files so that killing a stale
# run-all.sh doesn't affect other worktrees running concurrently.
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

# --- Session-safe process cleanup (Fix 3) ---
# Source the cleanup library and clear stale processes from prior runs
# of the SAME session (worktree). Does NOT touch other sessions.
# Skip cleanup if we're a nested invocation (e.g., spawned by test-run-all.sh)
# to avoid killing the parent run-all.sh process (fratricide bug).
if [ -z "${_RUN_ALL_ACTIVE:-}" ] && [ -f "$SCRIPT_DIR/lib/process-cleanup.sh" ]; then
    source "$SCRIPT_DIR/lib/process-cleanup.sh"

    _SESSION_ID=$(_get_session_id)
    _PIDFILE_DIR=$(_get_pidfile_dir)

    # Clean up stale processes from prior runs of this session
    _cleanup_stale_session_processes "$_PIDFILE_DIR" "$_SESSION_ID" "$$"

    # Register ourselves
    _write_pidfile "$_PIDFILE_DIR/run-all-$$.pid" "$$" "$_SESSION_ID"

    # Ensure we remove our pidfile on exit
    _orig_trap=$(trap -p EXIT | sed "s/^trap -- '//;s/' EXIT$//")
    trap '
        _remove_pidfile "$_PIDFILE_DIR/run-all-$$.pid" 2>/dev/null || true
        '"${_orig_trap:+$_orig_trap}"'
    ' EXIT
fi

# --- Process group / orphan cleanup on exit ---
# Kill all child processes in this process group on exit so orphaned suite
# runners (e.g., timed-out suites) do not linger after run-all.sh exits.
# Appended AFTER any existing EXIT trap to avoid replacing it.
_kill_children() {
    # Kill direct child process group members; suppress errors for already-dead procs
    kill -- -$$ 2>/dev/null || true
}
_prev_exit_for_pgid=$(trap -p EXIT | sed "s/^trap -- '//;s/' EXIT$//")
trap '
    _kill_children
    '"${_prev_exit_for_pgid:+$_prev_exit_for_pgid}"'
' EXIT

# Mark ourselves as active so nested invocations (e.g., from test-run-all.sh)
# skip process cleanup and don't kill us.
export _RUN_ALL_ACTIVE=1

# --- Isolate tests from real .tickets/ (290+ files slow git operations) ---
# Create a minimal temp .tickets/ directory and set RUN_ALL_TEST_TICKETS_DIR
# for sub-runners to use. We do NOT export TICKETS_DIR here because some tests
# (e.g., test-tickets-config.sh) specifically test tk's config-based directory
# resolution and would break if TICKETS_DIR is pre-set in the environment.
if [[ -z "${RUN_ALL_TEST_TICKETS_DIR:-}" ]]; then
    _TEST_TICKETS_DIR=$(mktemp -d)
    export RUN_ALL_TEST_TICKETS_DIR="$_TEST_TICKETS_DIR"
    # Append to existing trap
    _prev_trap=$(trap -p EXIT | sed "s/^trap -- '//;s/' EXIT$//")
    trap '
        rm -rf "$_TEST_TICKETS_DIR" 2>/dev/null || true
        '"${_prev_trap:+$_prev_trap}"'
    ' EXIT
fi

# --- Default suite runner paths ---
# Use SCRIPT_DIR-relative paths so this script works both when embedded in a
# parent repo (lockpick-workflow/tests/) and when the plugin is the repo root.
HOOKS_RUNNER="$SCRIPT_DIR/hooks/run-hook-tests.sh"
SCRIPTS_RUNNER="$SCRIPT_DIR/scripts/run-script-tests.sh"
EVALS_RUNNER="$SCRIPT_DIR/evals/run-evals.sh"

# --- Per-suite timeout (seconds). Override with --suite-timeout <N>. ---
SUITE_TIMEOUT="${SUITE_TIMEOUT:-180}"

# --- Resolve portable timeout command (gtimeout on macOS, timeout on Linux) ---
# Falls back to a no-op wrapper when neither is available, so suites still run
# (just without per-suite timeout enforcement).
_TIMEOUT_CMD=""
if command -v gtimeout >/dev/null 2>&1; then
    _TIMEOUT_CMD="gtimeout"
elif command -v timeout >/dev/null 2>&1; then
    _TIMEOUT_CMD="timeout"
fi

# Portable wrapper: applies timeout if available, otherwise runs command directly.
_run_with_timeout() {
    if [ -n "$_TIMEOUT_CMD" ]; then
        "$_TIMEOUT_CMD" "$@"
    else
        # Skip the timeout argument, run the rest directly
        shift
        "$@"
    fi
}

# --- Parse optional overrides (for TDD mock injection) ---
while [[ $# -gt 0 ]]; do
    case "$1" in
        --hooks-runner)
            HOOKS_RUNNER="$2"; shift 2 ;;
        --scripts-runner)
            SCRIPTS_RUNNER="$2"; shift 2 ;;
        --evals-runner)
            EVALS_RUNNER="$2"; shift 2 ;;
        --suite-timeout)
            SUITE_TIMEOUT="$2"; shift 2 ;;
        *)
            echo "Unknown argument: $1" >&2; exit 1 ;;
    esac
done

# --- Run a suite with per-suite timeout, capturing output to a temp file ---
# Usage: run_suite_to_file <label> <runner_path> <outfile> <exitfile>
# Writes suite output to <outfile> and exit code to <exitfile>.
# Exits 124 if the suite exceeds SUITE_TIMEOUT seconds (not 144/SIGURG).
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
        _run_with_timeout "$SUITE_TIMEOUT" bash "$runner" </dev/null
    } >"$outfile" 2>&1
    echo $? >"$exitfile"
}

# --- Tracking ---
EVALS_EXIT=0
HOOKS_EXIT=0
SCRIPTS_EXIT=0

# --- Run hooks and scripts suites ---
# SERIAL_SUITES=1 runs hooks then scripts sequentially (lower peak memory for CI).
# Default: concurrent execution with output captured to temp files.
if [ "${SERIAL_SUITES:-0}" = "1" ]; then
    # --- Sequential mode (CI-friendly) ---
    echo ""
    echo "========================================"
    echo "Suite: Hook Tests"
    echo "========================================"
    _run_with_timeout "$SUITE_TIMEOUT" bash "$HOOKS_RUNNER" </dev/null || HOOKS_EXIT=$?

    echo ""
    echo "========================================"
    echo "Suite: Script Tests"
    echo "========================================"
    _run_with_timeout "$SUITE_TIMEOUT" bash "$SCRIPTS_RUNNER" </dev/null || SCRIPTS_EXIT=$?
else
    # --- Concurrent mode (local dev) ---
    _HOOKS_OUT=$(mktemp)
    _HOOKS_EXIT_FILE=$(mktemp)
    _SCRIPTS_OUT=$(mktemp)
    _SCRIPTS_EXIT_FILE=$(mktemp)

    run_suite_to_file "Hook Tests" "$HOOKS_RUNNER" "$_HOOKS_OUT" "$_HOOKS_EXIT_FILE" &
    _HOOKS_PID=$!
    run_suite_to_file "Script Tests" "$SCRIPTS_RUNNER" "$_SCRIPTS_OUT" "$_SCRIPTS_EXIT_FILE" &
    _SCRIPTS_PID=$!

    # Propagate signals to background suite runners so they don't orphan when
    # the parent is killed (by CI timeout, cancel-in-progress, or the 720s wrapper).
    _kill_suites() { kill "$_HOOKS_PID" "$_SCRIPTS_PID" 2>/dev/null || true; }
    trap '_kill_suites' TERM INT

    wait "$_HOOKS_PID"
    wait "$_SCRIPTS_PID"

    trap - TERM INT

    # Print captured output sequentially for readable logs
    cat "$_HOOKS_OUT"
    cat "$_SCRIPTS_OUT"

    HOOKS_EXIT=$(cat "$_HOOKS_EXIT_FILE")
    SCRIPTS_EXIT=$(cat "$_SCRIPTS_EXIT_FILE")
    rm -f "$_HOOKS_OUT" "$_HOOKS_EXIT_FILE" "$_SCRIPTS_OUT" "$_SCRIPTS_EXIT_FILE"
fi

# --- Run evals suite after parallel suites complete ---
echo ""
echo "========================================"
echo "Suite: Evals"
echo "========================================"
_run_with_timeout "$SUITE_TIMEOUT" bash "$EVALS_RUNNER" </dev/null || EVALS_EXIT=$?

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
