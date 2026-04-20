#!/bin/bash
set -uo pipefail
# validate.sh - Token-optimized validation script for AI agents
# Outputs only summary to stdout, saves details to log file on failure
#
# Runs format checks, linting (ruff + mypy), unit tests, and optionally E2E tests.
# MyPy type checking is critical - fails fast on type errors.
#
# VALIDATION STATE TRACKING:
#   Results are written to /tmp/lockpick-test-artifacts-<worktree-name>/status
#   The hook_test_failure_guard reads test-status files to block commits
#   when tests have failed in the current worktree session.
#
# WORKTREE SUPPORT:
#   This script automatically detects and works correctly in Git worktrees.
#   When running in a worktree, it reports the worktree name in output.
#
# Usage:
#   ./scripts/validate.sh           # Run all checks in parallel
#   ./scripts/validate.sh --ci      # Also check CI status + smart E2E skip
#
# CI STATUS BEHAVIOR (with --ci flag):
#   - If CI is "completed:success": Reports PASS
#   - If CI is "completed:failure": Reports FAIL
#   - If CI is "pending"/"queued" and previous non-cancelled completed run succeeded: Reports PASS
#   - If CI is "pending"/"queued" and previous non-cancelled completed run failed: Reports FAIL immediately
#   - If CI is "pending"/"queued" and no previous non-cancelled completed run: Reports PASS (no failure evidence)
#
# E2E TEST BEHAVIOR:
#   - In CI environment ($CI=true): Always runs E2E tests
#   - Locally with --ci flag: Skips E2E if CI is passing for main
#   - Locally with --ci flag: Starts E2E in parallel when CI completed with failure
#   - Locally without --ci: E2E tests are not run
#   - If E2E tests are run and fail, the state file records "e2e_failed=true"
#     so that push-blocking hooks can prevent pushing broken E2E code.
#
# PARALLEL EXECUTION:
#   Format, ruff, mypy, tests, migration, and CI checks all run in parallel.
#   Results are collected and reported after all checks complete.
#   E2E tests: when CI definitively fails (completed:failure), E2E starts immediately
#   in parallel with remaining checks (triggered ~30s after CI result). Otherwise,
#   E2E runs after CI check completes (skip if CI passing, run if CI pending).
#
# TIMEOUTS:
#   Each command has an explicit timeout to prevent hanging processes.
#   Timeout events are logged to: /tmp/lockpick-test-artifacts-<worktree>/validation-timeouts.log
#   If a timeout occurs, run the command directly to debug:
#
#   Format check (30s):  cd app && make format-check
#   Ruff lint (60s):     cd app && make lint-ruff
#   MyPy check (120s):   cd app && make lint-mypy
#   Tests (600s/10min):  cd app && make test-unit-only
#   E2E tests (600s):    cd app && make test-e2e
#   CI status (30s):     gh run list --workflow=CI --limit 1 --json status,conclusion
#
# ENVIRONMENT VARIABLES:
#   Configure timeouts via environment variables (values in seconds):
#     VALIDATE_TIMEOUT_SYNTAX  - Syntax check timeout (default: 30)
#     VALIDATE_TIMEOUT_FORMAT  - Format check timeout (default: 30)
#     VALIDATE_TIMEOUT_RUFF    - Ruff lint timeout (default: 60)
#     VALIDATE_TIMEOUT_MYPY    - MyPy type check timeout (default: 120)
#     VALIDATE_TIMEOUT_TESTS   - Test suite timeout (default: 600)
#     VALIDATE_TIMEOUT_E2E     - E2E test timeout (default: 900)
#     VALIDATE_TIMEOUT_CI      - CI status check timeout (default: 60)
#     VALIDATE_TIMEOUT_LOG     - Path to timeout log (default: /tmp/lockpick-test-artifacts-<worktree>/validation-timeouts.log)
#
#   Example: VALIDATE_TIMEOUT_TESTS=900 ./scripts/validate.sh
#
#   Test-batched integration (for suites that exceed the ~73s Claude tool timeout):
#     VALIDATE_TEST_STATE_FILE  - Path to test-batched.sh state file for session-level
#                                 result reuse across validate.sh invocations.
#                                 Default: /tmp/lockpick-test-artifacts-<worktree>/test-session-state.json
#     VALIDATE_TEST_BATCHED_SCRIPT - Path to test-batched.sh (default: adjacent to validate.sh)
#                                    Override in tests to inject a stub.
#
#   When tests are pending (Structured Action-Required Block printed by test-batched.sh), validate.sh exits 2:
#     Exit 0: all checks passed
#     Exit 1: one or more checks failed
#     Exit 2: tests are pending (run validate.sh again to resume)

set -e

# Capture original args for use in SIGURG handler ACTION REQUIRED block
_ORIG_ARGS=("$@")

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLAUDE_PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$SCRIPT_DIR/..}"
[[ ! -f "${CLAUDE_PLUGIN_ROOT}/plugin.json" ]] && CLAUDE_PLUGIN_ROOT="$SCRIPT_DIR/.."

# Use the caller's git toplevel as REPO_ROOT so that worktrees are tested
# against their own working tree, not the main repo's.
CALLER_GIT_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || true)"
if [ -n "$CALLER_GIT_ROOT" ]; then
    REPO_ROOT="$CALLER_GIT_ROOT"
else
    REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
fi

# --- Config-driven command and path resolution ---
# All commands are read from .claude/dso-config.conf via read-config.sh.
# Fallback defaults preserve backward compatibility when config keys are absent.
READ_CONFIG="$SCRIPT_DIR/read-config.sh"
CONFIG_FILE="${CONFIG_FILE:-$REPO_ROOT/.claude/dso-config.conf}"

_cfg() {
    local key="$1" default="${2:-}"
    local val=""
    if [ -f "$CONFIG_FILE" ] && [ -x "$READ_CONFIG" ]; then
        val=$("$READ_CONFIG" "$key" "$CONFIG_FILE" 2>/dev/null || true)
    fi
    if [ -z "$val" ]; then
        echo "$default"
    else
        echo "$val"
    fi
}

# Resolve APP_DIR from config (fallback: app)
_APP_DIR_REL=$(_cfg "paths.app_dir" "app")
APP_DIR="$REPO_ROOT/$_APP_DIR_REL"

# Cache command config at startup (with fallback defaults matching current make targets)
CMD_SYNTAX_CHECK=$(_cfg "commands.syntax_check" "make syntax-check")
CMD_FORMAT_CHECK=$(_cfg "commands.format_check" "make format-check")
CMD_LINT_RUFF=$(_cfg "commands.lint_ruff" "make lint-ruff")
CMD_LINT_MYPY=$(_cfg "commands.lint_mypy" "make lint-mypy")
# Allow VALIDATE_CMD_TEST env override (for testing/stubs)
CMD_TEST_UNIT="${VALIDATE_CMD_TEST:-$(_cfg "commands.test_unit" "make test-unit-only")}"
SCRIPT_WRITE_SCAN_DIR=$(_cfg "checks.script_write_scan_dir" "")
PLUGIN_SCRIPTS="$SCRIPT_DIR"
CMD_TEST_E2E=$(_cfg "commands.test_e2e" "make test-e2e")
# Optional: run a build/compile step (e.g., npm run build, poetry build).
# Empty string (default) disables the build check — no impact on repos without a build step.
CMD_BUILD=$(_cfg "commands.build" "")
# Optional: unified lint command (commands.lint). When set, it replaces the
# separate ruff + mypy checks. When absent, the individual commands.lint_ruff
# and commands.lint_mypy checks run as before (backward compatible).
CMD_LINT=$(_cfg "commands.lint" "")
if [[ -z "$CMD_LINT" ]]; then
    echo "[DSO WARN] commands.lint not configured — lint step will be skipped." >&2
fi

# Detect if running in a worktree
if [ -f "$REPO_ROOT/.git" ]; then
    # .git is a file (worktree) - read the actual git dir
    WORKTREE_MODE=1
else
    WORKTREE_MODE=0
fi

# Session-isolated artifacts directory (matches Makefile convention)
WORKTREE_NAME=$(basename "$REPO_ROOT")
ARTIFACTS_DIR="/tmp/lockpick-test-artifacts-${WORKTREE_NAME}"
mkdir -p "$ARTIFACTS_DIR"

LOGFILE="$ARTIFACTS_DIR/validation-$$.log"
TIMEOUT_LOG="${VALIDATE_TIMEOUT_LOG:-$ARTIFACTS_DIR/validation-timeouts.log}"
FAILED=0
CHECK_CI=0
SKIP_CI=0      # Set to 1 when --skip-ci is passed (disables CI status check even if --ci is set)
VERBOSE=0      # Set to 1 when --verbose is passed (exported so subshells see it)
BACKGROUND=0   # Set to 1 when --background is passed (self-daemonize mode)
export VERBOSE
CI_PASSED=0  # Set to 1 when CI check passes (used for E2E skip logic)
E2E_RAN=0    # Set to 1 when E2E tests are actually executed
E2E_FAILED=0 # Set to 1 when E2E tests fail
TESTS_PENDING=0  # Set to 1 when test-batched.sh reports partial run (ACTION REQUIRED block in output)

# ── Test-batched.sh integration ───────────────────────────────────────────────
# Path to test-batched.sh (adjacent to validate.sh by default).
# Override with VALIDATE_TEST_BATCHED_SCRIPT for testing/stubs.
VALIDATE_TEST_BATCHED_SCRIPT="${VALIDATE_TEST_BATCHED_SCRIPT:-$SCRIPT_DIR/test-batched.sh}"

# Session-level test state file for result reuse across multiple invocations.
# When test-batched.sh records "pass" for the test command, validate.sh skips
# re-running the test step (enabling incremental progress across tool calls).
# Override with VALIDATE_TEST_STATE_FILE for testing isolation.
VALIDATE_TEST_STATE_FILE="${VALIDATE_TEST_STATE_FILE:-$ARTIFACTS_DIR/test-session-state.json}"
# Export so test-batched.sh picks up the same state file path
export VALIDATE_TEST_STATE_FILE
export TEST_BATCHED_STATE_FILE="$VALIDATE_TEST_STATE_FILE"

# Track which checks were launched so we can detect silent crashes
# (background process killed without writing .rc file)
LAUNCHED_CHECKS=""

# Validation state tracking (for validation gate hook)
VALIDATION_STATE_FILE="$ARTIFACTS_DIR/status"

# Timeout values in seconds - configurable via environment variables
# Check $TIMEOUT_LOG for timeout history to identify if values need adjustment
TIMEOUT_SYNTAX="${VALIDATE_TIMEOUT_SYNTAX:-60}"  # E999 + bash/YAML/JSON syntax check — scans 300+ files (parallel)
TIMEOUT_FORMAT="${VALIDATE_TIMEOUT_FORMAT:-30}"
TIMEOUT_RUFF="${VALIDATE_TIMEOUT_RUFF:-60}"
TIMEOUT_MYPY="${VALIDATE_TIMEOUT_MYPY:-120}"
TIMEOUT_LINT="${VALIDATE_TIMEOUT_LINT:-60}"
TIMEOUT_TESTS="${VALIDATE_TIMEOUT_TESTS:-600}"  # 10 minutes default - test suite is large
TIMEOUT_E2E="${VALIDATE_TIMEOUT_E2E:-900}"      # 15 minutes for E2E tests (local is ~2-3x slower than CI ~180s)
TIMEOUT_CI="${VALIDATE_TIMEOUT_CI:-60}"  # GitHub API call — 60s headroom for rate limiting/slow network

# Track sleep PIDs for cleanup at script exit
CLEANUP_PIDS=()

# Cleanup function to kill any remaining processes on exit
# Also writes "interrupted" to the status file if validate.sh exits unexpectedly
# while still in the "in_progress" state (i.e., before success/fail is written).
# shellcheck disable=SC2329
cleanup() {
    # Write "interrupted" state if we are still in_progress (unexpected exit)
    if [[ -f "$VALIDATION_STATE_FILE" ]]; then
        local _current_state
        _current_state=$(head -n 1 "$VALIDATION_STATE_FILE" 2>/dev/null || echo "")
        if [[ "$_current_state" == "in_progress" ]]; then
            local _interrupted_content
            _interrupted_content="interrupted
timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
            if declare -f atomic_write_file &>/dev/null; then
                atomic_write_file "$VALIDATION_STATE_FILE" "$_interrupted_content"
            else
                printf '%s\n' "$_interrupted_content" > "$VALIDATION_STATE_FILE" 2>/dev/null || true
            fi
        fi
    fi
    for pid in "${CLEANUP_PIDS[@]+"${CLEANUP_PIDS[@]}"}"; do
        kill -TERM "$pid" 2>/dev/null || true
        kill -KILL "$pid" 2>/dev/null || true
    done
}

# Set up trap to clean up on exit
trap cleanup EXIT

# ── SIGURG handler ─────────────────────────────────────────────────────────
# Claude Code sends SIGURG to the process group when the Bash tool call times
# out (~73s). test-batched.sh already handles SIGURG and saves state; this
# handler ensures validate.sh also exits cleanly with ACTION REQUIRED so the
# caller knows to re-run rather than treating timeout as a failure.
# shellcheck disable=SC2329  # invoked via trap _sigurg_handler SIGURG
_sigurg_handler() {
    # Write pending state so the validation gate knows to re-run
    local _ts
    _ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    local _pending_content="pending
timestamp=${_ts}"
    if declare -f atomic_write_file &>/dev/null; then
        atomic_write_file "$VALIDATION_STATE_FILE" "$_pending_content"
    else
        printf '%s\n' "$_pending_content" > "$VALIDATION_STATE_FILE" 2>/dev/null || true
    fi
    echo ""
    echo "════════════════════════════════════════════════════════════"
    echo "  ⚠  ACTION REQUIRED — VALIDATE NOT COMPLETE  ⚠"
    echo "════════════════════════════════════════════════════════════"
    printf 'RUN: bash %s' "$0"
    printf ' %q' "${_ORIG_ARGS[@]+"${_ORIG_ARGS[@]}"}"
    printf '\n'
    echo "DO NOT PROCEED until the command above prints PASSED or FAILED."
    echo "════════════════════════════════════════════════════════════"
    exit 0
}
trap _sigurg_handler SIGURG

# Parse arguments
for arg in "$@"; do
    case $arg in
        --ci) CHECK_CI=1 ;;
        --skip-ci) SKIP_CI=1 ;;
        --verbose) VERBOSE=1 ;;
        --background) BACKGROUND=1 ;;
        --help)
            echo "Usage: ./scripts/validate.sh [--ci] [--skip-ci] [--verbose] [--background]"
            echo "  --ci         Include CI status check + smart E2E skip"
            echo "  --skip-ci    Skip the CI status check (overrides --ci); use when the"
            echo "               CI check is handled by a separate sub-agent (e.g. in"
            echo "               /dso:validate-work where Sub-Agent 2 owns CI status)"
            echo "  --verbose    Print real-time dot-notation progress as each check runs"
            echo "               (suppresses batch summary output)"
            echo "  --background Self-daemonize: invoke bg-run.sh with label validate-<worktree>"
            echo "               and output /tmp/validate-<worktree>.out, then exit 0 immediately."
            echo "               Results go to /tmp/validate-<worktree>.out and .exit files."
            echo "               If bg-run.sh is not in PATH, exits 0 with a warning."
            echo ""
            echo "E2E tests are skipped locally when --ci is used and CI is passing for main."
            echo "E2E tests are also skipped when CI completed with failure (fix CI first)."
            echo "In CI environment (\$CI set), E2E tests always run."
            echo ""
            echo "CI pending behavior:"
            echo "  - Pending CI with previous success: assumes still good (PASS)"
            echo "  - Pending CI with previous failure: FAIL immediately"
            echo "  - Pending CI with no previous completed run: PASS (no failure evidence)"
            echo "  - Completed CI with failure: FAIL immediately; E2E starts in parallel immediately"
            echo ""
            echo "Timeouts (in seconds):"
            echo "  syntax: $TIMEOUT_SYNTAX, format: $TIMEOUT_FORMAT, ruff: $TIMEOUT_RUFF, mypy: $TIMEOUT_MYPY"
            echo "  tests: $TIMEOUT_TESTS"
            echo "  e2e: $TIMEOUT_E2E, ci: $TIMEOUT_CI"
            echo ""
            echo "Timeout log: $TIMEOUT_LOG"
            echo "If a timeout occurs, run the command directly to debug."
            echo "See script header for individual commands."
            exit 0
            ;;
    esac
done

# --skip-ci overrides --ci: disable the CI status check even if --ci was set.
# This allows callers (e.g. /dso:validate-work Sub-Agent 1) to run local checks
# without duplicating the CI status check performed by a dedicated sub-agent.
if [ $SKIP_CI -eq 1 ]; then
    CHECK_CI=0
fi

if [ $WORKTREE_MODE -eq 1 ]; then
    echo "  (worktree: $(basename "$REPO_ROOT"))"
fi

# ── Background self-daemonize mode ────────────────────────────────────────
# When --background is passed, invoke bg-run.sh (Session A) with:
#   label:  validate-<worktree-name>
#   output: /tmp/validate-<worktree-name>.out
# Then exit 0 immediately — caller does not wait for validation to complete.
# Results are available in /tmp/validate-<worktree-name>.out and .exit files.
# GATED: requires bg-run.sh to be available in PATH. If unavailable, exits 0
# with a warning so callers that probe for --background support are not broken.
if [ $BACKGROUND -eq 1 ]; then
    BG_LABEL="validate-${WORKTREE_NAME}"
    BG_OUTPUT="/tmp/validate-${WORKTREE_NAME}.out"
    if command -v bg-run.sh &>/dev/null; then
        # Build the forward args (all original args except --background itself)
        FWD_ARGS=()
        for _a in "$@"; do
            [ "$_a" = "--background" ] || FWD_ARGS+=("$_a")
        done
        # Invoke bg-run.sh: <label> <output-file> -- <command> [args...]
        # bg-run.sh launches the command in the background and exits immediately;
        # results land in BG_OUTPUT and BG_OUTPUT.exit (written by bg-run.sh).
        bg-run.sh "$BG_LABEL" "$BG_OUTPUT" -- \
            bash "$0" "${FWD_ARGS[@]+"${FWD_ARGS[@]}"}"
        exit 0
    else
        echo "WARNING: --background requested but bg-run.sh not found in PATH; skipping background launch" >&2
        exit 0
    fi
fi

# ── Pre-flight: Docker auto-start ────────────────────────────────────────
# If docker CLI is available but daemon isn't running, attempt auto-start.
# Source shared dependency library for try_start_docker.
# Source deps.sh from plugin (canonical location)
HOOK_LIB="${CLAUDE_PLUGIN_ROOT}/hooks/lib/deps.sh"
if [[ ! -f "$HOOK_LIB" ]]; then
    # Fallback: try legacy .claude/hooks path
    HOOK_LIB="$REPO_ROOT/.claude/hooks/lib/deps.sh"
fi
if [[ -f "$HOOK_LIB" ]]; then
    source "$HOOK_LIB"
    if command -v docker &>/dev/null && ! docker info &>/dev/null 2>&1; then
        if try_start_docker; then
            echo "  (Docker daemon auto-started)"
        fi
    fi
    # Redirect VALIDATION_STATE_FILE to the portable workflow-plugin path that
    # hooks read via get_artifacts_dir(). The old lockpick-test-artifacts
    # path is kept for log files; only the gate-readable status file moves.
    if declare -f get_artifacts_dir &>/dev/null; then
        VALIDATION_STATE_FILE="$(get_artifacts_dir)/status"
    fi
fi

# ── Validate utility helpers (timeout, verbose_print, run_check, test state) ──
# shellcheck source=${CLAUDE_PLUGIN_ROOT}/hooks/lib/validate-helpers.sh
if [[ -f "${CLAUDE_PLUGIN_ROOT}/hooks/lib/validate-helpers.sh" ]]; then
    source "${CLAUDE_PLUGIN_ROOT}/hooks/lib/validate-helpers.sh"
fi
# ── Validate check runners (run_test_check, check_migrations, check_hook_drift, check_ci) ──
# shellcheck source=${CLAUDE_PLUGIN_ROOT}/hooks/lib/validate-check-runners.sh
if [[ -f "${CLAUDE_PLUGIN_ROOT}/hooks/lib/validate-check-runners.sh" ]]; then
    source "${CLAUDE_PLUGIN_ROOT}/hooks/lib/validate-check-runners.sh"
fi

# ── Write in_progress state before launching any checks ──────────────────
# This ensures that if validate.sh is killed or crashes, the EXIT trap can
# detect the unfinished run and write "interrupted" instead of leaving a
# stale "passed" or "failed" from the previous run.
{
    local_in_progress_content="in_progress
timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    mkdir -p "$(dirname "$VALIDATION_STATE_FILE")" 2>/dev/null || true
    if declare -f atomic_write_file &>/dev/null; then
        atomic_write_file "$VALIDATION_STATE_FILE" "$local_in_progress_content"
    else
        printf '%s\n' "$local_in_progress_content" > "$VALIDATION_STATE_FILE" 2>/dev/null || true
    fi
}

# ── Parallel Check Execution ─────────────────────────────────────────────
# All independent checks run simultaneously. Results are collected and
# reported after all complete. E2E depends on CI result so runs after.

CHECK_DIR=$(mktemp -d)
VERBOSE_LOCK_FILE="$CHECK_DIR/verbose.lock"
# shellcheck disable=SC2064
trap "rm -rf '$CHECK_DIR'; cleanup" EXIT

# Launch all independent checks in parallel
# Guard: if APP_DIR doesn't exist (e.g. DSO plugin repo has no app/ subdir),
# fall back to running checks from REPO_ROOT.
if [ -d "$APP_DIR" ]; then
    cd "$APP_DIR"
else
    cd "$REPO_ROOT"
fi

# Pre-flight: check if E2E command is available (must run after cd so make finds the Makefile)
E2E_AVAILABLE=1
if [ -z "$CMD_TEST_E2E" ] || [ "$CMD_TEST_E2E" = "none" ]; then
    E2E_AVAILABLE=0
elif [[ "$CMD_TEST_E2E" == make\ * ]]; then
    # REVIEW-DEFENSE: Availability check is scoped to make-based commands only. The default
    # CMD_TEST_E2E is make-based (e.g., make test-e2e), and the FAIL-vs-SKIP bug this guard
    # fixes is most common when the make target does not exist. Non-make commands (e.g.,
    # 'pytest e2e/', 'npm run e2e', './scripts/run-e2e.sh') are left at E2E_AVAILABLE=1
    # intentionally: they are only configured via explicit opt-in in dso-config.conf, so a
    # configured non-make command is assumed to be valid. Extending the guard to arbitrary
    # shell commands would require heuristics (command -v, dry-run flags) that vary per runner
    # and are out of scope for this targeted fix.
    _e2e_target="${CMD_TEST_E2E#make }"
    _e2e_target="${_e2e_target%% *}"
    if ! make -n "$_e2e_target" >/dev/null 2>&1; then
        E2E_AVAILABLE=0
    fi
fi

# Track launched checks for crash detection (missing .rc file = process crash)
# REVIEW-DEFENSE: Keep this list in sync with the run_check/check_* calls below.
# Each name must match the first argument passed to run_check or check_*.
LAUNCHED_CHECKS="syntax format tests migrate"
if [[ -n "$CMD_LINT" ]]; then
    LAUNCHED_CHECKS="$LAUNCHED_CHECKS lint"
elif [[ -n "$CMD_LINT_RUFF" || -n "$CMD_LINT_MYPY" ]]; then
    [[ -n "$CMD_LINT_RUFF" ]] && LAUNCHED_CHECKS="$LAUNCHED_CHECKS ruff"
    [[ -n "$CMD_LINT_MYPY" ]] && LAUNCHED_CHECKS="$LAUNCHED_CHECKS mypy"
fi
if [ "${VALIDATE_SKIP_PLUGIN_CHECKS:-}" != "1" ]; then
    LAUNCHED_CHECKS="$LAUNCHED_CHECKS hook-drift"
fi
[ -n "$SCRIPT_WRITE_SCAN_DIR" ] && LAUNCHED_CHECKS="$LAUNCHED_CHECKS script-writes"
if [ "${VALIDATE_SKIP_PLUGIN_CHECKS:-}" != "1" ]; then
    LAUNCHED_CHECKS="$LAUNCHED_CHECKS skill-refs"
    [ -f "$PLUGIN_SCRIPTS/check-shim-refs.sh" ] && LAUNCHED_CHECKS="$LAUNCHED_CHECKS shim-refs"
    [ -f "$PLUGIN_SCRIPTS/check-model-id-lint.sh" ] && LAUNCHED_CHECKS="$LAUNCHED_CHECKS model-id-lint"
    [ -f "$PLUGIN_SCRIPTS/check-contract-schemas.sh" ] && LAUNCHED_CHECKS="$LAUNCHED_CHECKS contract-schema"
    [ -f "$PLUGIN_SCRIPTS/check-referential-integrity.sh" ] && LAUNCHED_CHECKS="$LAUNCHED_CHECKS referential-integrity"
fi
[ -n "$CMD_BUILD" ] && LAUNCHED_CHECKS="$LAUNCHED_CHECKS build"
# REVIEW-DEFENSE: CMD_* variables are intentionally unquoted to allow word splitting.
# Commands like "make format-check" must split into ["make", "format-check"] for run_check.
# This is the standard bash pattern for stored multi-word commands.
# shellcheck disable=SC2086
run_check "syntax" "$TIMEOUT_SYNTAX" $CMD_SYNTAX_CHECK &
# shellcheck disable=SC2086
run_check "format" "$TIMEOUT_FORMAT" $CMD_FORMAT_CHECK &
# Lint: commands.lint (unified) takes precedence over individual ruff/mypy checks.
# When commands.lint is set, run it as a single "lint" check; otherwise fall back
# to the individual ruff + mypy checks (backward compatible).
if [[ -n "$CMD_LINT" ]]; then
    # shellcheck disable=SC2086
    (run_check "lint" "$TIMEOUT_LINT" $CMD_LINT) &
    LINT_PID=$!
elif [[ -n "$CMD_LINT_RUFF" ]]; then
    # shellcheck disable=SC2086
    run_check "ruff" "$TIMEOUT_RUFF" $CMD_LINT_RUFF &
    RUFF_PID=$!
    if [[ -n "$CMD_LINT_MYPY" ]]; then
        # shellcheck disable=SC2086
        run_check "mypy" "$TIMEOUT_MYPY" $CMD_LINT_MYPY &
        MYPY_PID=$!
    fi
elif [[ -n "$CMD_LINT_MYPY" ]]; then
    # shellcheck disable=SC2086
    run_check "mypy" "$TIMEOUT_MYPY" $CMD_LINT_MYPY &
    MYPY_PID=$!
fi
# Tests use run_test_check (test-batched.sh integration) for time-bounded execution.
# This allows validate.sh to run in < 73s even for test suites that take 120+ seconds.
run_test_check &
check_migrations &
if [ -n "$SCRIPT_WRITE_SCAN_DIR" ]; then
    (cd "$REPO_ROOT" && run_check "script-writes" "$TIMEOUT_SYNTAX" python3 "$PLUGIN_SCRIPTS/check-script-writes.py" --scan-dir="$SCRIPT_WRITE_SCAN_DIR") &
fi
if [ "${VALIDATE_SKIP_PLUGIN_CHECKS:-}" != "1" ]; then
    (cd "$REPO_ROOT" && run_check "skill-refs" "$TIMEOUT_SYNTAX" bash "$PLUGIN_SCRIPTS/check-skill-refs.sh") &
    if [ -f "$PLUGIN_SCRIPTS/check-shim-refs.sh" ]; then
        (cd "$REPO_ROOT" && run_check "shim-refs" "$TIMEOUT_SYNTAX" bash "$PLUGIN_SCRIPTS/check-shim-refs.sh") &
    fi
    if [ -f "$PLUGIN_SCRIPTS/check-model-id-lint.sh" ]; then
        (cd "$REPO_ROOT" && run_check "model-id-lint" "$TIMEOUT_SYNTAX" bash "$PLUGIN_SCRIPTS/check-model-id-lint.sh") &
    fi
    if [ -f "$PLUGIN_SCRIPTS/check-contract-schemas.sh" ]; then
        (cd "$REPO_ROOT" && run_check "contract-schema" "$TIMEOUT_SYNTAX" bash "$PLUGIN_SCRIPTS/check-contract-schemas.sh") &
    fi
    if [ -f "$PLUGIN_SCRIPTS/check-referential-integrity.sh" ]; then
        (cd "$REPO_ROOT" && run_check "referential-integrity" "$TIMEOUT_SYNTAX" bash "$PLUGIN_SCRIPTS/check-referential-integrity.sh") &
    fi
fi
if [ "${VALIDATE_SKIP_PLUGIN_CHECKS:-}" != "1" ]; then
    check_hook_drift &
fi
# shellcheck disable=SC2086
[ -n "$CMD_BUILD" ] && run_check "build" "$TIMEOUT_FORMAT" $CMD_BUILD &
if [ $CHECK_CI -eq 1 ]; then
    check_ci &
    # When CI definitively fails, start E2E immediately in parallel rather than
    # waiting for all other checks to complete first. CI typically finishes in ~30s
    # while unit tests / mypy can take 60-600s, so this saves significant wall time.
    # Only triggers locally (not in CI environment, where E2E always runs separately).
    (
        # Wait for the CI check to write its result file
        while [ ! -f "$CHECK_DIR/ci.rc" ]; do sleep 1; done
        local_ci_rc=$(cat "$CHECK_DIR/ci.rc")
        local_e2e_result=$(cat "$CHECK_DIR/ci.result" 2>/dev/null || echo "")
        # Only trigger when CI definitively completed with failure and we are not
        # already inside a CI environment (where the E2E block above handles it).
        if [ "$E2E_AVAILABLE" = "1" ] && [ "$local_ci_rc" != "0" ] && [ "$local_ci_rc" != "skip" ] && \
           [[ "$local_e2e_result" == completed:* ]] && [ -z "${CI:-}" ]; then
            [ "$VERBOSE" = "1" ] && verbose_print "e2e" "running (parallel, CI failed)"
            # shellcheck disable=SC2086
            run_check "e2e" "$TIMEOUT_E2E" $CMD_TEST_E2E
            echo "parallel" > "$CHECK_DIR/e2e.mode"
        fi
    ) &
fi

# Wait for all parallel checks to complete
wait

# ── Report Results ───────────────────────────────────────────────────────

# Accumulate failed check names for the status file
FAILED_CHECKS=""

report_check() {
    local label="$1" name="$2" timeout="$3" hint_cmd="${4:-cd app && make $2}"
    local rc_file="$CHECK_DIR/${name}.rc"

    if [ ! -f "$rc_file" ]; then
        # If this check was launched, missing .rc means the process crashed
        if [[ " $LAUNCHED_CHECKS " == *" $name "* ]]; then
            printf "  %-8s CRASH (check process did not report) - run '%s' to debug\n" "${label}:" "$hint_cmd"
            FAILED_CHECKS="${FAILED_CHECKS:+$FAILED_CHECKS,}$label"
            FAILED=1
        fi
        return 0
    fi

    local rc
    rc=$(cat "$rc_file")

    if [ "$rc" = "0" ]; then
        printf "  %-8s PASS\n" "${label}:"
    elif [ "$rc" = "skip" ]; then
        printf "  %-8s SKIP\n" "${label}:"
    elif [ "$rc" = "42" ] && [ "$name" = "tests" ]; then
        # rc=42: test-batched.sh reported partial progress (ACTION REQUIRED block in output).
        # Tests are not done yet — the orchestrator must run validate.sh again.
        printf "  %-8s PENDING (run validate.sh again to continue)\n" "${label}:"
        TESTS_PENDING=1
    elif [ "$rc" = "124" ]; then
        printf "  %-8s TIMEOUT (%ss) - run '%s' to debug\n" "${label}:" "$timeout" "$hint_cmd"
        cat "$CHECK_DIR/${name}.log" >> "$LOGFILE" 2>/dev/null || true
        FAILED_CHECKS="${FAILED_CHECKS:+$FAILED_CHECKS,}$label"
        FAILED=1
    else
        # For tests: parse pytest summary to distinguish failures from errors
        if [ "$name" = "tests" ] && [ -f "$CHECK_DIR/${name}.log" ]; then
            local summary
            # Match both verbose ("= N failed ... =") and quiet ("N failed, ...") pytest summaries
            summary=$(grep -E '(^=+ .*(failed|error|passed)|^[0-9]+ (failed|passed))' "$CHECK_DIR/${name}.log" | tail -1 || true)
            if [ -n "$summary" ]; then
                local n_failed n_errors
                n_failed=$(echo "$summary" | grep -oE '[0-9]+ failed' | grep -oE '[0-9]+' || echo "0")
                n_errors=$(echo "$summary" | grep -oE '[0-9]+ error' | grep -oE '[0-9]+' || echo "0")
                : "${n_failed:=0}" "${n_errors:=0}"
                local detail=""
                [ "$n_failed" -gt 0 ] 2>/dev/null && detail="${n_failed} failed"
                if [ "$n_errors" -gt 0 ] 2>/dev/null; then
                    [ -n "$detail" ] && detail="$detail, "
                    detail="${detail}${n_errors} errors"
                fi
                if [ -n "$detail" ]; then
                    printf "  %-8s FAIL (%s)\n" "${label}:" "$detail"
                else
                    printf "  %-8s FAIL\n" "${label}:"
                fi
            else
                printf "  %-8s FAIL\n" "${label}:"
            fi
        else
            printf "  %-8s FAIL\n" "${label}:"
        fi
        cat "$CHECK_DIR/${name}.log" >> "$LOGFILE" 2>/dev/null || true
        FAILED_CHECKS="${FAILED_CHECKS:+$FAILED_CHECKS,}$label"
        FAILED=1
    fi
}

# tally_check: accumulate FAILED/FAILED_CHECKS without printing (used in verbose mode)
# Dot-notation output was already printed in real-time by run_check/check_migrations/check_ci.
tally_check() {
    local label="$1" name="$2"
    local rc_file="$CHECK_DIR/${name}.rc"

    if [ ! -f "$rc_file" ]; then
        # If this check was launched, missing .rc means the process crashed
        if [[ " $LAUNCHED_CHECKS " == *" $name "* ]]; then
            FAILED_CHECKS="${FAILED_CHECKS:+$FAILED_CHECKS,}$label"
            FAILED=1
        fi
        return 0
    fi

    local rc
    rc=$(cat "$rc_file")

    if [ "$rc" = "42" ] && [ "$name" = "tests" ]; then
        # Pending — verbose mode already printed the PENDING label via run_test_check.
        # Tally it as pending (not failed, not passed).
        TESTS_PENDING=1
    elif [ "$rc" = "skip" ]; then
        # Skipped — verbose mode already printed the SKIP label.
        :  # no tally for skipped checks
    elif [ "$rc" != "0" ]; then
        cat "$CHECK_DIR/${name}.log" >> "$LOGFILE" 2>/dev/null || true
        FAILED_CHECKS="${FAILED_CHECKS:+$FAILED_CHECKS,}$label"
        FAILED=1
    fi
}

if [ "$VERBOSE" = "0" ]; then
    report_check "syntax" "syntax" "$TIMEOUT_SYNTAX"
    report_check "format" "format" "$TIMEOUT_FORMAT"
    if [[ -n "$CMD_LINT" ]]; then
        report_check "lint" "lint" "$TIMEOUT_LINT"
    else
        [[ -n "$CMD_LINT_RUFF" ]] && report_check "ruff" "ruff" "$TIMEOUT_RUFF"
        [[ -n "$CMD_LINT_MYPY" ]] && report_check "mypy" "mypy" "$TIMEOUT_MYPY"
    fi
    report_check "tests" "tests" "$TIMEOUT_TESTS"
    [ -n "$SCRIPT_WRITE_SCAN_DIR" ] && report_check "script-writes" "script-writes" "$TIMEOUT_SYNTAX" "python3 $PLUGIN_SCRIPTS/check-script-writes.py --scan-dir=$SCRIPT_WRITE_SCAN_DIR"
    if [ "${VALIDATE_SKIP_PLUGIN_CHECKS:-}" != "1" ]; then
        report_check "skill-refs" "skill-refs" "$TIMEOUT_SYNTAX" "bash $PLUGIN_SCRIPTS/check-skill-refs.sh"
        [ -f "$PLUGIN_SCRIPTS/check-shim-refs.sh" ] && report_check "shim-refs" "shim-refs" "$TIMEOUT_SYNTAX" "bash $PLUGIN_SCRIPTS/check-shim-refs.sh"
        [ -f "$PLUGIN_SCRIPTS/check-model-id-lint.sh" ] && report_check "model-id-lint" "model-id-lint" "$TIMEOUT_SYNTAX" "bash $PLUGIN_SCRIPTS/check-model-id-lint.sh"
        [ -f "$PLUGIN_SCRIPTS/check-contract-schemas.sh" ] && report_check "contract-schema" "contract-schema" "$TIMEOUT_SYNTAX" "bash $PLUGIN_SCRIPTS/check-contract-schemas.sh"
        [ -f "$PLUGIN_SCRIPTS/check-referential-integrity.sh" ] && report_check "referential-integrity" "referential-integrity" "$TIMEOUT_SYNTAX" "bash $PLUGIN_SCRIPTS/check-referential-integrity.sh"
        report_check "hook-drift" "hook-drift" "$TIMEOUT_SYNTAX" "diff <(grep 'id:' .pre-commit-config.yaml) <(grep 'id:' ${CLAUDE_PLUGIN_ROOT}/docs/examples/pre-commit-config.example.yaml)"
    fi
else
    tally_check "syntax" "syntax"
    tally_check "format" "format"
    if [[ -n "$CMD_LINT" ]]; then
        tally_check "lint" "lint"
    else
        [[ -n "$CMD_LINT_RUFF" ]] && tally_check "ruff" "ruff"
        [[ -n "$CMD_LINT_MYPY" ]] && tally_check "mypy" "mypy"
    fi
    tally_check "tests" "tests"
    [ -n "$SCRIPT_WRITE_SCAN_DIR" ] && tally_check "script-writes" "script-writes"
    if [ "${VALIDATE_SKIP_PLUGIN_CHECKS:-}" != "1" ]; then
        tally_check "skill-refs" "skill-refs"
        [ -f "$PLUGIN_SCRIPTS/check-shim-refs.sh" ] && tally_check "shim-refs" "shim-refs"
        [ -f "$PLUGIN_SCRIPTS/check-model-id-lint.sh" ] && tally_check "model-id-lint" "model-id-lint"
        [ -f "$PLUGIN_SCRIPTS/check-contract-schemas.sh" ] && tally_check "contract-schema" "contract-schema"
        [ -f "$PLUGIN_SCRIPTS/check-referential-integrity.sh" ] && tally_check "referential-integrity" "referential-integrity"
        tally_check "hook-drift" "hook-drift"
    fi
fi

# Migration result
if [ -f "$CHECK_DIR/migrate.rc" ]; then
    migrate_rc=$(cat "$CHECK_DIR/migrate.rc")
    migrate_info=$(cat "$CHECK_DIR/migrate.info" 2>/dev/null || echo "")
    if [ "$VERBOSE" = "0" ]; then
        if [ "$migrate_rc" = "0" ]; then
            echo "  migrate: PASS ($migrate_info)"
        elif [ "$migrate_rc" = "skip" ]; then
            echo "  migrate: SKIP (no migrations directory)"
        else
            echo "  migrate: FAIL ($migrate_info)"
            echo "  -> Run 'make db-migrate-merge-heads' to merge, then commit the merge migration"
            FAILED_CHECKS="${FAILED_CHECKS:+$FAILED_CHECKS,}migrate"
            FAILED=1
        fi
    else
        # Verbose: tally only (dot-notation was already printed by check_migrations)
        if [ "$migrate_rc" != "0" ] && [ "$migrate_rc" != "skip" ]; then
            FAILED_CHECKS="${FAILED_CHECKS:+$FAILED_CHECKS,}migrate"
            FAILED=1
        fi
    fi
fi

# CI result + E2E
if [ $CHECK_CI -eq 1 ]; then
    CI_LABEL="ci"
    [ $WORKTREE_MODE -eq 1 ] && CI_LABEL="ci(main)"

    if [ -f "$CHECK_DIR/ci.rc" ]; then
        ci_rc=$(cat "$CHECK_DIR/ci.rc")
        # Handle jq-missing skip
        if [ "$ci_rc" = "skip" ]; then
            [ "$VERBOSE" = "0" ] && echo "  ${CI_LABEL}:     SKIP (jq not installed — install jq to enable CI and E2E checks)"
        else
            ci_result=$(cat "$CHECK_DIR/ci.result" 2>/dev/null || echo "unknown")
            skipped_wait=$(cat "$CHECK_DIR/ci.skipped_wait" 2>/dev/null || echo "")
            was_cancelled=$(cat "$CHECK_DIR/ci.was_cancelled" 2>/dev/null || echo "")
            pending_with_failure=$(cat "$CHECK_DIR/ci.pending_with_failure" 2>/dev/null || echo "")

            if [ "$ci_rc" = "0" ]; then
                if [ "$VERBOSE" = "0" ]; then
                    if [ "$was_cancelled" = "true" ] && [ "$skipped_wait" = "true" ]; then
                        echo "  ${CI_LABEL}:     PASS (run cancelled; previous run passed)"
                    elif [ "$was_cancelled" = "true" ]; then
                        echo "  ${CI_LABEL}:     PASS (run cancelled — not a test failure)"
                    elif [ "$skipped_wait" = "true" ]; then
                        echo "  ${CI_LABEL}:     PASS (pending, previous run passed)"
                    else
                        echo "  ${CI_LABEL}:     PASS ($ci_result)"
                    fi
                fi
                CI_PASSED=1
                echo "success" > "$ARTIFACTS_DIR/ci-baseline"
            elif [ "$pending_with_failure" = "true" ]; then
                if [ "$VERBOSE" = "0" ]; then
                    echo "  ${CI_LABEL}:     FAIL (pending, previous run failed)"
                    echo "  ${CI_LABEL}:     Run 'ci-status.sh --wait' to wait for completion"
                fi
                echo "failure" > "$ARTIFACTS_DIR/ci-baseline"
                FAILED_CHECKS="${FAILED_CHECKS:+$FAILED_CHECKS,}ci"
                FAILED=1
            elif [ "$ci_rc" = "error" ]; then
                [ "$VERBOSE" = "0" ] && echo "  ${CI_LABEL}:     TIMEOUT/ERROR - run 'gh run list --workflow=CI --limit 1' to debug"
                FAILED_CHECKS="${FAILED_CHECKS:+$FAILED_CHECKS,}ci"
                FAILED=1
            else
                [ "$VERBOSE" = "0" ] && echo "  ${CI_LABEL}:     FAIL ($ci_result)"
                echo "failure" > "$ARTIFACTS_DIR/ci-baseline"
                FAILED_CHECKS="${FAILED_CHECKS:+$FAILED_CHECKS,}ci"
                FAILED=1
            fi
        fi
    else
        [ "$VERBOSE" = "0" ] && echo "  ${CI_LABEL}:     ERROR (no result)"
        FAILED_CHECKS="${FAILED_CHECKS:+$FAILED_CHECKS,}ci"
        FAILED=1
    fi

    # E2E tests: skip if CI passed for main, always run in CI environment
    if [ -d "$APP_DIR" ]; then cd "$APP_DIR"; else cd "$REPO_ROOT"; fi
    if [ "$E2E_AVAILABLE" = "0" ]; then
        # E2E command not available (no make target or configured as "none")
        if [ "$VERBOSE" = "0" ]; then
            echo "  e2e:     SKIP (not configured)"
        else
            verbose_print "e2e" "SKIP (not configured)"
        fi
    elif [ -n "${CI:-}" ]; then
        # In CI environment: always run E2E tests
        E2E_RAN=1
        [ "$VERBOSE" = "1" ] && verbose_print "e2e" "running"
        # shellcheck disable=SC2086
        if run_with_timeout "$TIMEOUT_E2E" "test-e2e" $CMD_TEST_E2E >> "$LOGFILE" 2>&1; then
            if [ "$VERBOSE" = "0" ]; then
                echo "  e2e:     PASS"
            else
                verbose_print "e2e" "PASS"
            fi
        else
            EXIT_CODE=$?
            E2E_FAILED=1
            if [ "$VERBOSE" = "0" ]; then
                if [ $EXIT_CODE -eq 124 ]; then
                    echo "  e2e:     TIMEOUT (${TIMEOUT_E2E}s) - run 'cd app && make test-e2e' to debug"
                else
                    echo "  e2e:     FAIL"
                fi
            else
                if [ $EXIT_CODE -eq 124 ]; then
                    verbose_print "e2e" "FAIL (timeout ${TIMEOUT_E2E}s)"
                else
                    verbose_print "e2e" "FAIL"
                fi
            fi
            FAILED_CHECKS="${FAILED_CHECKS:+$FAILED_CHECKS,}e2e"
            FAILED=1
        fi
    elif [ "$CI_PASSED" = "1" ]; then
        [ "$VERBOSE" = "0" ] && echo "  e2e:     SKIP (CI passing for main)"
    else
        # CI not passing — only run E2E locally if CI result is still uncertain
        # (pending/in_progress). If CI definitively completed with failure, skip
        # E2E to avoid a 15-minute hang: CI already ran E2E, fix CI first.
        e2e_ci_result=$(cat "$CHECK_DIR/ci.result" 2>/dev/null || echo "")
        if [[ "$e2e_ci_result" == completed:* ]]; then
            # CI definitively completed with failure. Check if the parallel trigger
            # already started E2E (it writes e2e.mode=parallel and e2e.rc when done).
            e2e_mode=$(cat "$CHECK_DIR/e2e.mode" 2>/dev/null || echo "")
            if [ "$e2e_mode" = "parallel" ]; then
                # E2E already ran in parallel — report its result
                E2E_RAN=1
                e2e_rc=$(cat "$CHECK_DIR/e2e.rc" 2>/dev/null || echo "1")
                if [ "$e2e_rc" = "0" ]; then
                    if [ "$VERBOSE" = "0" ]; then
                        echo "  e2e:     PASS (ran in parallel)"
                    else
                        verbose_print "e2e" "PASS (ran in parallel)"
                    fi
                elif [ "$e2e_rc" = "124" ]; then
                    E2E_FAILED=1
                    if [ "$VERBOSE" = "0" ]; then
                        echo "  e2e:     TIMEOUT (${TIMEOUT_E2E}s) - run 'cd app && make test-e2e' to debug"
                    else
                        verbose_print "e2e" "FAIL (timeout ${TIMEOUT_E2E}s)"
                    fi
                    FAILED_CHECKS="${FAILED_CHECKS:+$FAILED_CHECKS,}e2e"
                    FAILED=1
                else
                    E2E_FAILED=1
                    if [ "$VERBOSE" = "0" ]; then
                        echo "  e2e:     FAIL (ran in parallel)"
                    else
                        verbose_print "e2e" "FAIL (ran in parallel)"
                    fi
                    FAILED_CHECKS="${FAILED_CHECKS:+$FAILED_CHECKS,}e2e"
                    FAILED=1
                fi
            else
                # Parallel trigger did not fire (e.g. ci.rc was non-1 edge case)
                [ "$VERBOSE" = "0" ] && echo "  e2e:     SKIP (CI completed with failure — fix CI first)"
            fi
        else
            # CI still running/pending — run E2E locally to catch issues early
            E2E_RAN=1
            [ "$VERBOSE" = "1" ] && verbose_print "e2e" "running"
            # shellcheck disable=SC2086
            if run_with_timeout "$TIMEOUT_E2E" "test-e2e" $CMD_TEST_E2E >> "$LOGFILE" 2>&1; then
                if [ "$VERBOSE" = "0" ]; then
                    echo "  e2e:     PASS"
                else
                    verbose_print "e2e" "PASS"
                fi
            else
                EXIT_CODE=$?
                E2E_FAILED=1
                if [ "$VERBOSE" = "0" ]; then
                    if [ $EXIT_CODE -eq 124 ]; then
                        echo "  e2e:     TIMEOUT (${TIMEOUT_E2E}s) - run 'cd app && make test-e2e' to debug"
                    else
                        echo "  e2e:     FAIL"
                    fi
                else
                    if [ $EXIT_CODE -eq 124 ]; then
                        verbose_print "e2e" "FAIL (timeout ${TIMEOUT_E2E}s)"
                    else
                        verbose_print "e2e" "FAIL"
                    fi
                fi
                FAILED_CHECKS="${FAILED_CHECKS:+$FAILED_CHECKS,}e2e"
                FAILED=1
            fi
        fi
    fi
fi

if [ $FAILED -eq 0 ] && [ $TESTS_PENDING -eq 0 ]; then
    # Write validation state atomically for validation gate hook
    _state_content="passed
timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    [ "$E2E_RAN" = "1" ] && _state_content="$_state_content
e2e_ran=true"
    if declare -f atomic_write_file &>/dev/null; then
        atomic_write_file "$VALIDATION_STATE_FILE" "$_state_content"
    else
        echo "$_state_content" > "$VALIDATION_STATE_FILE"
    fi
    rm -f "$LOGFILE"  # Clean up log on success
    exit 0
elif [ $TESTS_PENDING -eq 1 ] && [ $FAILED -eq 0 ]; then
    # Tests are still running (time-bounded by test-batched.sh) — all other checks passed.
    # Exit 2 signals "pending": the orchestrator should run validate.sh again to resume.
    echo ""
    echo "════════════════════════════════════════════════════════════"
    echo "  ⚠  ACTION REQUIRED — TESTS NOT COMPLETE  ⚠"
    echo "════════════════════════════════════════════════════════════"
    printf 'RUN: bash %s' "$0"; printf ' %q' "$@"; printf '\n'
    echo "DO NOT PROCEED until the command above prints a final summary."
    echo "════════════════════════════════════════════════════════════"
    _state_content="pending
timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)
test_state_file=$VALIDATE_TEST_STATE_FILE"
    if declare -f atomic_write_file &>/dev/null; then
        atomic_write_file "$VALIDATION_STATE_FILE" "$_state_content"
    else
        echo "$_state_content" > "$VALIDATION_STATE_FILE"
    fi
    exit 2
else
    echo "Some checks failed. Details: $LOGFILE"
    # Write failed state atomically for validation gate hook
    _state_content="failed
timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)
logfile=$LOGFILE
failed_checks=$FAILED_CHECKS"
    [ "$E2E_RAN" = "1" ] && _state_content="$_state_content
e2e_ran=true"
    [ "$E2E_FAILED" = "1" ] && _state_content="$_state_content
e2e_failed=true"
    if declare -f atomic_write_file &>/dev/null; then
        atomic_write_file "$VALIDATION_STATE_FILE" "$_state_content"
    else
        echo "$_state_content" > "$VALIDATION_STATE_FILE"
    fi
    exit 1
fi
