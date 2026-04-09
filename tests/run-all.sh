#!/usr/bin/env bash
# tests/run-all.sh
# Top-level regression runner: orchestrates all plugin test suites.
#
# Runs all five suites concurrently (sequential fallback via SERIAL_SUITES=1):
#   1. tests/hooks/run-hook-tests.sh          \
#   2. tests/scripts/run-script-tests.sh       |  concurrent
#   3. tests/evals/run-evals.sh                |
#   4. tests/skills/run-python-tests.sh        |
#   5. tests/skills/run-skill-bash-tests.sh   /
#
# Produces a combined PASS/FAIL summary across all suites.
# Exits 0 only if ALL suites exit 0; exits 1 otherwise.
#
# Process cleanup: uses session-safe PID files so that killing a stale
# run-all.sh doesn't affect other worktrees running concurrently.
#
# Note: test-estimate-context-load.sh (pre-existing in tests/)
# uses its own pass/fail helpers, not assert.sh. It is excluded from this
# orchestrator because it is a standalone test that predates the suite structure
# and its output format is incompatible with the suite runner aggregation.
# Run it separately: bash tests/test-estimate-context-load.sh
#
# Usage:
#   bash tests/run-all.sh
#
# Override individual suite runners (used by tests):
#   bash tests/run-all.sh \
#     --hooks-runner /path/to/mock-hooks.sh \
#     --scripts-runner /path/to/mock-scripts.sh \
#     --evals-runner /path/to/mock-evals.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null)"

# Ensure CLAUDE_PLUGIN_ROOT points to the plugin subdir for all tests.
# Plugin files live under plugins/dso/ after the dso-anlb restructure.
# Force-set to plugins/dso/ so dispatchers find hooks/lib/ at the right path.
export CLAUDE_PLUGIN_ROOT="$REPO_ROOT/plugins/dso"

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

# --- Isolate tests from real ticket data (many files slow git operations) ---
# Create a minimal temp tickets directory and set RUN_ALL_TEST_TICKETS_DIR
# for sub-runners to use. We do NOT export TICKETS_DIR here because some tests
# specifically test config-based directory resolution and would break if
# TICKETS_DIR is pre-set in the environment.
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
# parent repo (tests/) and when the plugin is the repo root.
HOOKS_RUNNER="$SCRIPT_DIR/hooks/run-hook-tests.sh"
SCRIPTS_RUNNER="$SCRIPT_DIR/scripts/run-script-tests.sh"
EVALS_RUNNER="$SCRIPT_DIR/evals/run-evals.sh"
PYTHON_RUNNER="$SCRIPT_DIR/skills/run-python-tests.sh"
SKILL_BASH_RUNNER="$SCRIPT_DIR/skills/run-skill-bash-tests.sh"

# --- Per-suite timeout (seconds). Override with --suite-timeout <N>. ---
SUITE_TIMEOUT="${SUITE_TIMEOUT:-600}"

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
        --python-runner)
            PYTHON_RUNNER="$2"; shift 2 ;;
        --skill-bash-runner)
            SKILL_BASH_RUNNER="$2"; shift 2 ;;
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
PYTHON_EXIT=0
SKILL_BASH_EXIT=0

# --- Run all four suites ---
# SERIAL_SUITES=1 runs all suites sequentially (lower peak memory for CI).
# Default: all four suites run concurrently with output captured to temp files.
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

    echo ""
    echo "========================================"
    echo "Suite: Evals"
    echo "========================================"
    _run_with_timeout "$SUITE_TIMEOUT" bash "$EVALS_RUNNER" </dev/null || EVALS_EXIT=$?

    echo ""
    echo "========================================"
    echo "Suite: Python Skill/Doc Tests"
    echo "========================================"
    _run_with_timeout "$SUITE_TIMEOUT" bash "$PYTHON_RUNNER" </dev/null || PYTHON_EXIT=$?

    echo ""
    echo "========================================"
    echo "Suite: Skill Bash Tests"
    echo "========================================"
    _run_with_timeout "$SUITE_TIMEOUT" bash "$SKILL_BASH_RUNNER" </dev/null || SKILL_BASH_EXIT=$?
else
    # --- Concurrent mode (all four suites in parallel) ---
    _HOOKS_OUT=$(mktemp)
    _HOOKS_EXIT_FILE=$(mktemp)
    _SCRIPTS_OUT=$(mktemp)
    _SCRIPTS_EXIT_FILE=$(mktemp)
    _EVALS_OUT=$(mktemp)
    _EVALS_EXIT_FILE=$(mktemp)
    _PYTHON_OUT=$(mktemp)
    _PYTHON_EXIT_FILE=$(mktemp)
    _SKILL_BASH_OUT=$(mktemp)
    _SKILL_BASH_EXIT_FILE=$(mktemp)

    run_suite_to_file "Hook Tests" "$HOOKS_RUNNER" "$_HOOKS_OUT" "$_HOOKS_EXIT_FILE" &
    _HOOKS_PID=$!
    run_suite_to_file "Script Tests" "$SCRIPTS_RUNNER" "$_SCRIPTS_OUT" "$_SCRIPTS_EXIT_FILE" &
    _SCRIPTS_PID=$!
    run_suite_to_file "Evals" "$EVALS_RUNNER" "$_EVALS_OUT" "$_EVALS_EXIT_FILE" &
    _EVALS_PID=$!
    run_suite_to_file "Python Skill/Doc Tests" "$PYTHON_RUNNER" "$_PYTHON_OUT" "$_PYTHON_EXIT_FILE" &
    _PYTHON_PID=$!
    run_suite_to_file "Skill Bash Tests" "$SKILL_BASH_RUNNER" "$_SKILL_BASH_OUT" "$_SKILL_BASH_EXIT_FILE" &
    _SKILL_BASH_PID=$!

    # Propagate signals to background suite runners so they don't orphan when
    # the parent is killed (by CI timeout, cancel-in-progress, or the 720s wrapper).
    _kill_suites() { kill "$_HOOKS_PID" "$_SCRIPTS_PID" "$_EVALS_PID" "$_PYTHON_PID" "$_SKILL_BASH_PID" 2>/dev/null || true; }
    trap '_kill_suites' TERM INT

    wait "$_HOOKS_PID"
    wait "$_SCRIPTS_PID"
    wait "$_EVALS_PID"
    wait "$_PYTHON_PID"
    wait "$_SKILL_BASH_PID"

    trap - TERM INT

    # Print captured output sequentially for readable logs
    cat "$_HOOKS_OUT"
    cat "$_SCRIPTS_OUT"
    cat "$_EVALS_OUT"
    cat "$_PYTHON_OUT"
    cat "$_SKILL_BASH_OUT"

    # Default to exit 1 if the exit file is missing/empty (e.g., suite killed by signal
    # before it could write the exit code).
    HOOKS_EXIT=$(cat "$_HOOKS_EXIT_FILE" 2>/dev/null)
    SCRIPTS_EXIT=$(cat "$_SCRIPTS_EXIT_FILE" 2>/dev/null)
    EVALS_EXIT=$(cat "$_EVALS_EXIT_FILE" 2>/dev/null)
    PYTHON_EXIT=$(cat "$_PYTHON_EXIT_FILE" 2>/dev/null)
    SKILL_BASH_EXIT=$(cat "$_SKILL_BASH_EXIT_FILE" 2>/dev/null)
    : "${HOOKS_EXIT:=1}"
    : "${SCRIPTS_EXIT:=1}"
    : "${EVALS_EXIT:=1}"
    : "${PYTHON_EXIT:=1}"
    : "${SKILL_BASH_EXIT:=1}"
    rm -f "$_HOOKS_OUT" "$_HOOKS_EXIT_FILE" "$_SCRIPTS_OUT" "$_SCRIPTS_EXIT_FILE" \
          "$_EVALS_OUT" "$_EVALS_EXIT_FILE" "$_PYTHON_OUT" "$_PYTHON_EXIT_FILE" \
          "$_SKILL_BASH_OUT" "$_SKILL_BASH_EXIT_FILE"
fi

# --- Combined summary ---
echo ""
echo "========================================"
echo "=== Run-All Combined Summary ==="
echo "========================================"

suite_pass() { [ "${1:-1}" -eq 0 ] && echo "PASS" || echo "FAIL"; }

printf "  Evals:             %s\n" "$(suite_pass $EVALS_EXIT)"
printf "  Hook Tests:        %s\n" "$(suite_pass $HOOKS_EXIT)"
printf "  Script Tests:      %s\n" "$(suite_pass $SCRIPTS_EXIT)"
printf "  Python Skill/Docs: %s\n" "$(suite_pass $PYTHON_EXIT)"
printf "  Skill Bash Tests:  %s\n" "$(suite_pass $SKILL_BASH_EXIT)"
echo ""

OVERALL_EXIT=0
if [ "$EVALS_EXIT" -ne 0 ] || [ "$HOOKS_EXIT" -ne 0 ] || [ "$SCRIPTS_EXIT" -ne 0 ] || [ "$PYTHON_EXIT" -ne 0 ] || [ "$SKILL_BASH_EXIT" -ne 0 ]; then
    OVERALL_EXIT=1
fi

if [ "$OVERALL_EXIT" -eq 0 ]; then
    echo "Overall: PASS — all suites green"
else
    echo "Overall: FAIL — one or more suites failed"
fi

exit "$OVERALL_EXIT"
