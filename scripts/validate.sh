#!/bin/bash
# validate.sh - Token-optimized validation script for AI agents
# Outputs only summary to stdout, saves details to log file on failure
#
# Runs format checks, linting (ruff + mypy), unit tests, and optionally E2E tests.
# MyPy type checking is critical - fails fast on type errors.
#
# VALIDATION STATE TRACKING:
#   Results are written to /tmp/lockpick-test-artifacts-<worktree-name>/status
#   The validation-gate.sh PreToolUse hook reads this state to warn agents
#   before they start work if validation hasn't passed.
#
# WORKTREE SUPPORT:
#   This script automatically detects and works correctly in Git worktrees.
#   When running in a worktree, it reports the worktree name in output.
#
# Usage:
#   ./lockpick-workflow/scripts/validate.sh           # Run all checks in parallel
#   ./lockpick-workflow/scripts/validate.sh --ci      # Also check CI status + smart E2E skip
#
# CI STATUS BEHAVIOR (with --ci flag):
#   - If CI is "completed:success": Reports PASS
#   - If CI is "completed:failure": Reports FAIL
#   - If CI is "pending"/"queued" and previous completed run succeeded: Reports PASS (assumes still good)
#   - If CI is "pending"/"queued" and previous completed run failed:
#       - If new commits contain "fix": waits for CI (polls at 8m, 10m, 15m after start)
#       - If new commits are unrelated: Reports FAIL immediately
#
# E2E TEST BEHAVIOR:
#   - In CI environment ($CI=true): Always runs E2E tests
#   - Locally with --ci flag: Skips E2E if CI is passing for main
#   - Locally without --ci: E2E tests are not run
#   - If E2E tests are run and fail, the state file records "e2e_failed=true"
#     so that push-blocking hooks can prevent pushing broken E2E code.
#
# PARALLEL EXECUTION:
#   Format, ruff, mypy, tests, migration, and CI checks all run in parallel.
#   Results are collected and reported after all checks complete.
#   E2E tests run after CI check completes (depends on CI result for skip logic).
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
#     VALIDATE_TIMEOUT_FORMAT  - Format check timeout (default: 30)
#     VALIDATE_TIMEOUT_RUFF    - Ruff lint timeout (default: 60)
#     VALIDATE_TIMEOUT_MYPY    - MyPy type check timeout (default: 120)
#     VALIDATE_TIMEOUT_TESTS   - Test suite timeout (default: 600)
#     VALIDATE_TIMEOUT_E2E     - E2E test timeout (default: 900)
#     VALIDATE_TIMEOUT_CI      - CI status check timeout (default: 30)
#     VALIDATE_TIMEOUT_LOG     - Path to timeout log (default: /tmp/lockpick-test-artifacts-<worktree>/validation-timeouts.log)
#
#   Example: VALIDATE_TIMEOUT_TESTS=900 ./lockpick-workflow/scripts/validate.sh

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Use the caller's git toplevel as REPO_ROOT so that worktrees are tested
# against their own working tree, not the main repo's.
CALLER_GIT_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || true)"
if [ -n "$CALLER_GIT_ROOT" ] && [ -d "$CALLER_GIT_ROOT/app" ]; then
    REPO_ROOT="$CALLER_GIT_ROOT"
else
    REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
fi
APP_DIR="$REPO_ROOT/app"

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
CI_PASSED=0  # Set to 1 when CI check passes (used for E2E skip logic)
E2E_RAN=0    # Set to 1 when E2E tests are actually executed
E2E_FAILED=0 # Set to 1 when E2E tests fail

# Validation state tracking (for validation gate hook)
VALIDATION_STATE_FILE="$ARTIFACTS_DIR/status"

# Timeout values in seconds - configurable via environment variables
# Check $TIMEOUT_LOG for timeout history to identify if values need adjustment
TIMEOUT_FORMAT="${VALIDATE_TIMEOUT_FORMAT:-30}"
TIMEOUT_RUFF="${VALIDATE_TIMEOUT_RUFF:-60}"
TIMEOUT_MYPY="${VALIDATE_TIMEOUT_MYPY:-120}"
TIMEOUT_TESTS="${VALIDATE_TIMEOUT_TESTS:-600}"  # 10 minutes default - test suite is large
TIMEOUT_E2E="${VALIDATE_TIMEOUT_E2E:-900}"      # 15 minutes for E2E tests (local is ~2-3x slower than CI ~180s)
TIMEOUT_CI="${VALIDATE_TIMEOUT_CI:-30}"

# Track sleep PIDs for cleanup at script exit
CLEANUP_PIDS=()

# Cleanup function to kill any remaining processes on exit
cleanup() {
    for pid in "${CLEANUP_PIDS[@]}"; do
        kill -TERM "$pid" 2>/dev/null || true
        kill -KILL "$pid" 2>/dev/null || true
    done
}

# Set up trap to clean up on exit
trap cleanup EXIT

# Create a beads bug automatically when a command times out
# This ensures timeout issues are tracked and investigated
# Uses deduplication to avoid creating duplicate issues
create_timeout_issue() {
    local cmd_name="$1"
    local timeout_secs="$2"
    local context="${3:-Triggered from validate.sh}"

    # Check if bd command is available
    if ! command -v bd &>/dev/null; then
        echo "WARNING: bd not available, cannot create timeout issue" >&2
        return 1
    fi

    # Search for existing open issues about this command's timeout
    # Our timeout issues all start with "Investigate timeout:" so search for that
    # Then grep for the specific command name
    local existing
    existing=$(bd search "Investigate" --status=open --limit=20 --quiet 2>/dev/null | grep -i "timeout.*$cmd_name" | head -1 || true)

    if [ -n "$existing" ]; then
        # Extract issue ID (first word on the line)
        local issue_id
        issue_id=$(echo "$existing" | awk '{print $1}')
        if [ -n "$issue_id" ]; then
            echo "Existing timeout issue found: $issue_id (adding comment instead of duplicate)"
            bd comments add "$issue_id" "Timeout occurred again at $(date '+%Y-%m-%d %H:%M:%S') - ${cmd_name} exceeded ${timeout_secs}s" --quiet 2>/dev/null || true
            return 0
        fi
    fi

    # Build issue title
    local title="Investigate timeout: ${cmd_name} exceeded ${timeout_secs}s"

    # Create the issue (quiet mode to minimize output)
    local issue_id
    issue_id=$(bd q "$title" -t bug -p 1 2>/dev/null || true)

    if [ -n "$issue_id" ]; then
        echo "Created timeout investigation issue: $issue_id"
        return 0
    else
        echo "WARNING: Failed to create timeout issue" >&2
        return 1
    fi
}

# Log timeout events for analysis and tuning
# Format: timestamp | command | timeout_value | pwd
# Also creates a beads issue for investigation
log_timeout() {
    local cmd_name="$1"
    local timeout_secs="$2"
    local timestamp
    timestamp=$(date "+%Y-%m-%d %H:%M:%S")

    # Log to file (existing behavior)
    echo "$timestamp | TIMEOUT | $cmd_name | ${timeout_secs}s | $(pwd)" >> "$TIMEOUT_LOG"

    # Create beads issue for investigation (with deduplication)
    create_timeout_issue "$cmd_name" "$timeout_secs" "Triggered from validate.sh"
}

# Portable timeout function for macOS/Linux compatibility
# Uses direct PID tracking to ensure clean cleanup - no orphan processes
# Usage: run_with_timeout <timeout_seconds> <command_name> <command...>
# Returns: 0 on success, 124 on timeout, or command's exit code on failure
run_with_timeout() {
    local timeout_secs="$1"
    local cmd_name="$2"
    shift 2
    local cmd=("$@")

    # Use timeout command if available (GNU coreutils on Linux)
    if command -v timeout &>/dev/null; then
        local exit_code=0
        timeout --signal=TERM "$timeout_secs" "${cmd[@]}" || exit_code=$?
        if [ $exit_code -eq 124 ]; then
            log_timeout "$cmd_name" "$timeout_secs"
        fi
        return $exit_code
    fi

    # Fallback for macOS: direct sleep background with polling
    # This avoids orphan processes by tracking PIDs directly

    # Start command in background
    "${cmd[@]}" &
    local cmd_pid=$!

    # Start timer sleep in background (not in a subshell - we need the actual sleep PID)
    sleep "$timeout_secs" &
    local sleep_pid=$!
    CLEANUP_PIDS+=("$sleep_pid")

    # Poll until either command finishes or sleep finishes (timeout)
    # Using 0.5s intervals for reasonable responsiveness vs CPU usage
    local timed_out=0
    while true; do
        # Check if command finished
        if ! kill -0 "$cmd_pid" 2>/dev/null; then
            break
        fi
        # Check if timeout expired (sleep finished)
        if ! kill -0 "$sleep_pid" 2>/dev/null; then
            timed_out=1
            break
        fi
        # Wait a bit before next check
        sleep 0.5
    done

    # Handle the result
    local exit_code=0
    if [ $timed_out -eq 1 ]; then
        # Timeout occurred - kill the command
        kill -TERM "$cmd_pid" 2>/dev/null || true
        sleep 0.1
        kill -KILL "$cmd_pid" 2>/dev/null || true
        log_timeout "$cmd_name" "$timeout_secs"
        exit_code=124
    else
        # Command finished - get its exit code
        wait "$cmd_pid" 2>/dev/null || exit_code=$?

        # Kill the sleep since we don't need it anymore
        kill -TERM "$sleep_pid" 2>/dev/null || true
    fi

    # Remove sleep_pid from cleanup array (it's handled)
    CLEANUP_PIDS=("${CLEANUP_PIDS[@]/$sleep_pid}")

    return $exit_code
}

# Parse arguments
for arg in "$@"; do
    case $arg in
        --ci) CHECK_CI=1 ;;
        --help)
            echo "Usage: ./lockpick-workflow/scripts/validate.sh [--ci]"
            echo "  --ci     Include CI status check + smart E2E skip"
            echo ""
            echo "E2E tests are skipped locally when --ci is used and CI is passing for main."
            echo "In CI environment (\$CI set), E2E tests always run."
            echo ""
            echo "CI wait behavior:"
            echo "  - Pending CI with previous success: assumes still good (no wait)"
            echo "  - Pending CI with previous failure: waits up to 20 min"
            echo ""
            echo "Timeouts (in seconds):"
            echo "  format: $TIMEOUT_FORMAT, ruff: $TIMEOUT_RUFF, mypy: $TIMEOUT_MYPY"
            echo "  tests: $TIMEOUT_TESTS, e2e: $TIMEOUT_E2E, ci: $TIMEOUT_CI"
            echo ""
            echo "Timeout log: $TIMEOUT_LOG"
            echo "If a timeout occurs, run the command directly to debug."
            echo "See script header for individual commands."
            exit 0
            ;;
    esac
done

if [ $WORKTREE_MODE -eq 1 ]; then
    echo "  (worktree: $(basename "$REPO_ROOT"))"
fi

# ── Pre-flight: Docker auto-start ────────────────────────────────────────
# If docker CLI is available but daemon isn't running, attempt auto-start.
# Source shared dependency library for try_start_docker.
HOOK_LIB="$REPO_ROOT/.claude/hooks/lib/deps.sh"
if [[ -f "$HOOK_LIB" ]]; then
    source "$HOOK_LIB"
    if command -v docker &>/dev/null && ! docker info &>/dev/null 2>&1; then
        if try_start_docker; then
            echo "  (Docker daemon auto-started)"
        fi
    fi
fi

# ── Parallel Check Execution ─────────────────────────────────────────────
# All independent checks run simultaneously. Results are collected and
# reported after all complete. E2E depends on CI result so runs after.

CHECK_DIR=$(mktemp -d)
trap "rm -rf '$CHECK_DIR'; cleanup" EXIT

# Run a make-based check in a subshell, storing exit code + log
run_check() {
    local name="$1" timeout="$2"
    shift 2
    local rc=0
    run_with_timeout "$timeout" "$name" "$@" > "$CHECK_DIR/${name}.log" 2>&1 || rc=$?
    echo "$rc" > "$CHECK_DIR/${name}.rc"
}

# Migration heads check (file-based, no DB required)
check_migrations() {
    local migration_dir="$APP_DIR/src/db/migrations/versions"
    if [ ! -d "$migration_dir" ]; then
        echo "skip" > "$CHECK_DIR/migrate.rc"
        return 0
    fi

    local all_revs down_revs head_count=0 heads=""
    all_revs=$(grep -h '^revision' "$migration_dir"/*.py 2>/dev/null | sed 's/.*= *"\([^"]*\)".*/\1/' | sort -u)
    down_revs=$(grep -h '^down_revision' "$migration_dir"/*.py 2>/dev/null | sed 's/.*= *"\([^"]*\)".*/\1/' | sort -u)

    for rev in $all_revs; do
        if ! echo "$down_revs" | grep -q "^${rev}$"; then
            head_count=$((head_count + 1))
            heads="$heads $rev"
        fi
    done

    if [ "$head_count" -le 1 ]; then
        echo "0" > "$CHECK_DIR/migrate.rc"
        echo "1 head" > "$CHECK_DIR/migrate.info"
    else
        echo "1" > "$CHECK_DIR/migrate.rc"
        echo "$head_count heads:$heads" > "$CHECK_DIR/migrate.info"
    fi
}

# CI status check (smart wait):
# - completed:success → PASS immediately
# - completed:failure → FAIL immediately
# - pending + previous success → PASS (assume still good)
# - pending + previous failure → evaluate commits:
#     - commits appear to fix the failure → wait (poll at 8m, 10m, 15m)
#     - commits unrelated to failure → FAIL immediately
check_ci() {
    # jq is required for CI status parsing (complex array/object expressions).
    # Without it, skip with a warning rather than producing garbage output.
    if ! command -v jq &>/dev/null; then
        echo "skip" > "$CHECK_DIR/ci.rc"
        echo "WARNING: jq not installed — CI status check skipped" > "$CHECK_DIR/ci.log"
        return
    fi
    cd "$REPO_ROOT"
    local gh_branch_flag=""
    [ $WORKTREE_MODE -eq 1 ] && gh_branch_flag="--branch main"

    # Fetch latest 2 CI runs with full metadata for commit analysis
    local ci_json
    ci_json=$(
        (
            run_with_timeout "$TIMEOUT_CI" "ci-status" \
                gh run list --workflow=CI $gh_branch_flag --limit 2 \
                --json status,conclusion,databaseId,headSha,createdAt \
                2>/dev/null
        ) || echo "TIMEOUT_OR_ERROR"
    )

    if [ "$ci_json" = "TIMEOUT_OR_ERROR" ]; then
        echo "TIMEOUT_OR_ERROR" > "$CHECK_DIR/ci.result"
        echo "error" > "$CHECK_DIR/ci.rc"
        return
    fi

    local latest_status latest_conclusion latest_id latest_sha latest_created
    latest_status=$(echo "$ci_json" | jq -r '.[0].status' 2>/dev/null)
    latest_conclusion=$(echo "$ci_json" | jq -r '.[0].conclusion // ""' 2>/dev/null)
    latest_id=$(echo "$ci_json" | jq -r '.[0].databaseId' 2>/dev/null)
    latest_sha=$(echo "$ci_json" | jq -r '.[0].headSha' 2>/dev/null)
    latest_created=$(echo "$ci_json" | jq -r '.[0].createdAt' 2>/dev/null)

    local prev_conclusion prev_id prev_sha
    prev_conclusion=$(echo "$ci_json" | jq -r '.[1].conclusion // ""' 2>/dev/null)
    prev_id=$(echo "$ci_json" | jq -r '.[1].databaseId // ""' 2>/dev/null)
    prev_sha=$(echo "$ci_json" | jq -r '.[1].headSha // ""' 2>/dev/null)

    # If latest run is completed, report directly
    if [ "$latest_status" = "completed" ]; then
        echo "completed:$latest_conclusion" > "$CHECK_DIR/ci.result"
        if [ "$latest_conclusion" = "success" ]; then
            echo "0" > "$CHECK_DIR/ci.rc"
        else
            echo "1" > "$CHECK_DIR/ci.rc"
        fi
        return
    fi

    # Latest is pending/in_progress — check previous completed run
    if [ "$prev_conclusion" = "success" ]; then
        # Previous CI was green — assume still good, don't wait
        echo "completed:success" > "$CHECK_DIR/ci.result"
        echo "0" > "$CHECK_DIR/ci.rc"
        echo "true" > "$CHECK_DIR/ci.skipped_wait"
        return
    fi

    # Previous CI failed, current is pending — evaluate whether new commits fix it
    # Step 1: Get failed job names from the previous run
    local failed_jobs
    failed_jobs=$(
        run_with_timeout "$TIMEOUT_CI" "ci-failed-jobs" \
            gh run view "$prev_id" --json jobs \
            --jq '[.jobs[] | select(.conclusion == "failure") | .name] | join(",")' \
            2>/dev/null || echo ""
    )

    # Step 2: Get commit messages between previous and current run
    local commit_msgs=""
    if [ -n "$prev_sha" ] && [ -n "$latest_sha" ] && [ "$prev_sha" != "$latest_sha" ]; then
        commit_msgs=$(
            git log --oneline "${prev_sha}..${latest_sha}" 2>/dev/null || echo ""
        )
    fi

    # Step 3: Determine if commits are likely fixing the CI failure
    # A commit is considered a fix if it contains "fix" in its message.
    # We match broadly because commit messages like "fix: prevent CI multi-worker
    # migration race" address CI failures without naming the specific job.
    local is_fix_attempt=false
    if [ -n "$commit_msgs" ] && echo "$commit_msgs" | grep -qi "fix"; then
        is_fix_attempt=true
    fi

    if [ "$is_fix_attempt" = "false" ]; then
        # Commits don't appear to fix the failure — fail immediately
        echo "in_progress:failure" > "$CHECK_DIR/ci.result"
        echo "1" > "$CHECK_DIR/ci.rc"
        echo "true" > "$CHECK_DIR/ci.pending_with_failure"
        echo "$failed_jobs" > "$CHECK_DIR/ci.failed_jobs"
        return
    fi

    # Step 4: Commits appear to fix the failure — wait with smart polling
    # Calculate when to check based on CI run start time
    # Average CI run is ~8 minutes; check at 8m, 10m, 15m after start
    echo "waiting (fix commits detected)" > "$CHECK_DIR/ci.waiting"

    # Convert CI run createdAt to epoch for timing calculations
    local ci_start_epoch
    if command -v gdate &>/dev/null; then
        ci_start_epoch=$(gdate -d "$latest_created" +%s 2>/dev/null || date +%s)
    elif date -d "2000-01-01" +%s &>/dev/null 2>&1; then
        ci_start_epoch=$(date -d "$latest_created" +%s 2>/dev/null || date +%s)
    else
        # macOS date fallback: parse ISO 8601 manually
        ci_start_epoch=$(date -jf "%Y-%m-%dT%H:%M:%SZ" "$latest_created" +%s 2>/dev/null || date +%s)
    fi

    # Poll at 8, 10, and 15 minutes after CI started
    local check_offsets=(480 600 900)  # seconds after CI start
    for offset in "${check_offsets[@]}"; do
        local target_epoch=$((ci_start_epoch + offset))
        local now_epoch
        now_epoch=$(date +%s)
        local sleep_secs=$((target_epoch - now_epoch))

        # If target time is in the past, check immediately
        if [ $sleep_secs -gt 0 ]; then
            sleep "$sleep_secs"
        fi

        # Poll CI status
        local ci_result
        ci_result=$(
            (
                run_with_timeout "$TIMEOUT_CI" "ci-status" \
                    gh run list --workflow=CI $gh_branch_flag --limit 1 \
                    --json status,conclusion \
                    --jq '.[0] | "\(.status):\(.conclusion)"' 2>/dev/null
            ) || echo "TIMEOUT_OR_ERROR"
        )

        if [ "$ci_result" = "TIMEOUT_OR_ERROR" ]; then
            continue  # Try next check point
        fi

        local status_part conclusion
        status_part=$(echo "$ci_result" | cut -d: -f1)
        conclusion=$(echo "$ci_result" | cut -d: -f2)

        if [ "$status_part" = "completed" ]; then
            echo "$ci_result" > "$CHECK_DIR/ci.result"
            if [ "$conclusion" = "success" ]; then
                echo "0" > "$CHECK_DIR/ci.rc"
            else
                echo "1" > "$CHECK_DIR/ci.rc"
            fi
            echo "true" > "$CHECK_DIR/ci.waited_for_fix"
            return
        fi
    done

    # Exhausted all check points — CI still running after 15 minutes
    echo "in_progress:timeout" > "$CHECK_DIR/ci.result"
    echo "1" > "$CHECK_DIR/ci.rc"
    echo "true" > "$CHECK_DIR/ci.pending_with_failure"
    echo "$failed_jobs" > "$CHECK_DIR/ci.failed_jobs"
}

# Launch all independent checks in parallel
cd "$APP_DIR"
run_check "format" "$TIMEOUT_FORMAT" make format-check &
run_check "ruff" "$TIMEOUT_RUFF" make lint-ruff &
run_check "mypy" "$TIMEOUT_MYPY" make lint-mypy &
run_check "tests" "$TIMEOUT_TESTS" make test-unit-only args="-q --tb=line" &
check_migrations &
if [ $CHECK_CI -eq 1 ]; then
    check_ci &
fi

# Wait for all parallel checks to complete
wait

# ── Report Results ───────────────────────────────────────────────────────

# Accumulate failed check names for the status file
FAILED_CHECKS=""

report_check() {
    local label="$1" name="$2" timeout="$3"
    local rc_file="$CHECK_DIR/${name}.rc"

    if [ ! -f "$rc_file" ]; then
        return 0
    fi

    local rc
    rc=$(cat "$rc_file")

    if [ "$rc" = "0" ]; then
        printf "  %-8s PASS\n" "${label}:"
    elif [ "$rc" = "124" ]; then
        printf "  %-8s TIMEOUT (%ss) - run 'cd app && make %s' to debug\n" "${label}:" "$timeout" "$name"
        cat "$CHECK_DIR/${name}.log" >> "$LOGFILE" 2>/dev/null || true
        FAILED_CHECKS="${FAILED_CHECKS:+$FAILED_CHECKS,}$label"
        FAILED=1
    else
        # For tests: parse pytest summary to distinguish failures from errors
        if [ "$name" = "tests" ] && [ -f "$CHECK_DIR/${name}.log" ]; then
            local summary
            # Match both verbose ("= N failed ... =") and quiet ("N failed, ...") pytest summaries
            summary=$(grep -E '(^=+ .*(failed|error|passed)|^[0-9]+ (failed|passed))' "$CHECK_DIR/${name}.log" | tail -1)
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

report_check "format" "format" "$TIMEOUT_FORMAT"
report_check "ruff" "ruff" "$TIMEOUT_RUFF"
report_check "mypy" "mypy" "$TIMEOUT_MYPY"
report_check "tests" "tests" "$TIMEOUT_TESTS"

# Migration result
if [ -f "$CHECK_DIR/migrate.rc" ]; then
    migrate_rc=$(cat "$CHECK_DIR/migrate.rc")
    migrate_info=$(cat "$CHECK_DIR/migrate.info" 2>/dev/null || echo "")
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
fi

# CI result + E2E
if [ $CHECK_CI -eq 1 ]; then
    CI_LABEL="ci"
    [ $WORKTREE_MODE -eq 1 ] && CI_LABEL="ci(main)"

    if [ -f "$CHECK_DIR/ci.rc" ]; then
        ci_rc=$(cat "$CHECK_DIR/ci.rc")
        # Handle jq-missing skip
        if [ "$ci_rc" = "skip" ]; then
            echo "  ${CI_LABEL}:     SKIP (jq not installed — install jq to enable CI and E2E checks)"
        else
            ci_result=$(cat "$CHECK_DIR/ci.result" 2>/dev/null || echo "unknown")
            skipped_wait=$(cat "$CHECK_DIR/ci.skipped_wait" 2>/dev/null || echo "")
            pending_with_failure=$(cat "$CHECK_DIR/ci.pending_with_failure" 2>/dev/null || echo "")
            waited_for_fix=$(cat "$CHECK_DIR/ci.waited_for_fix" 2>/dev/null || echo "")
            failed_jobs=$(cat "$CHECK_DIR/ci.failed_jobs" 2>/dev/null || echo "")

            if [ "$ci_rc" = "0" ]; then
                if [ "$skipped_wait" = "true" ]; then
                    echo "  ${CI_LABEL}:     PASS (pending, previous run passed)"
                elif [ "$waited_for_fix" = "true" ]; then
                    echo "  ${CI_LABEL}:     PASS (fix commits verified — CI passed)"
                else
                    echo "  ${CI_LABEL}:     PASS ($ci_result)"
                fi
                CI_PASSED=1
                echo "success" > "$ARTIFACTS_DIR/ci-baseline"
            elif [ "$pending_with_failure" = "true" ]; then
                detail=""
                if [ -n "$failed_jobs" ]; then
                    detail=" (failed: $failed_jobs)"
                fi
                if [ "$ci_result" = "in_progress:timeout" ]; then
                    echo "  ${CI_LABEL}:     FAIL (waited for fix, CI still running after 15m)${detail}"
                else
                    echo "  ${CI_LABEL}:     FAIL (pending, unrelated to previous failure)${detail}"
                fi
                echo "  ${CI_LABEL}:     Run 'ci-status.sh --wait' to wait for completion"
                echo "failure" > "$ARTIFACTS_DIR/ci-baseline"
                FAILED_CHECKS="${FAILED_CHECKS:+$FAILED_CHECKS,}ci"
                FAILED=1
            elif [ "$waited_for_fix" = "true" ]; then
                echo "  ${CI_LABEL}:     FAIL (fix commits detected, but CI still failed)"
                echo "failure" > "$ARTIFACTS_DIR/ci-baseline"
                FAILED_CHECKS="${FAILED_CHECKS:+$FAILED_CHECKS,}ci"
                FAILED=1
            elif [ "$ci_rc" = "error" ]; then
                echo "  ${CI_LABEL}:     TIMEOUT/ERROR - run 'gh run list --workflow=CI --limit 1' to debug"
                FAILED_CHECKS="${FAILED_CHECKS:+$FAILED_CHECKS,}ci"
                FAILED=1
            else
                echo "  ${CI_LABEL}:     FAIL ($ci_result)"
                echo "failure" > "$ARTIFACTS_DIR/ci-baseline"
                FAILED_CHECKS="${FAILED_CHECKS:+$FAILED_CHECKS,}ci"
                FAILED=1
            fi
        fi
    else
        echo "  ${CI_LABEL}:     ERROR (no result)"
        FAILED_CHECKS="${FAILED_CHECKS:+$FAILED_CHECKS,}ci"
        FAILED=1
    fi

    # E2E tests: skip if CI passed for main, always run in CI environment
    cd "$APP_DIR"
    if [ -n "$CI" ]; then
        # In CI environment: always run E2E tests
        E2E_RAN=1
        if run_with_timeout "$TIMEOUT_E2E" "test-e2e" make test-e2e >> "$LOGFILE" 2>&1; then
            echo "  e2e:     PASS"
        else
            EXIT_CODE=$?
            E2E_FAILED=1
            if [ $EXIT_CODE -eq 124 ]; then
                echo "  e2e:     TIMEOUT (${TIMEOUT_E2E}s) - run 'cd app && make test-e2e' to debug"
            else
                echo "  e2e:     FAIL"
            fi
            FAILED_CHECKS="${FAILED_CHECKS:+$FAILED_CHECKS,}e2e"
            FAILED=1
        fi
    elif [ "$CI_PASSED" = "1" ]; then
        echo "  e2e:     SKIP (CI passing for main)"
    else
        # CI not passing — run E2E locally
        E2E_RAN=1
        if run_with_timeout "$TIMEOUT_E2E" "test-e2e" make test-e2e >> "$LOGFILE" 2>&1; then
            echo "  e2e:     PASS"
        else
            EXIT_CODE=$?
            E2E_FAILED=1
            if [ $EXIT_CODE -eq 124 ]; then
                echo "  e2e:     TIMEOUT (${TIMEOUT_E2E}s) - run 'cd app && make test-e2e' to debug"
            else
                echo "  e2e:     FAIL"
            fi
            FAILED_CHECKS="${FAILED_CHECKS:+$FAILED_CHECKS,}e2e"
            FAILED=1
        fi
    fi
fi

if [ $FAILED -eq 0 ]; then
    # Write validation state for validation gate hook
    echo "passed" > "$VALIDATION_STATE_FILE"
    echo "timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$VALIDATION_STATE_FILE"
    [ "$E2E_RAN" = "1" ] && echo "e2e_ran=true" >> "$VALIDATION_STATE_FILE"
    rm -f "$LOGFILE"  # Clean up log on success
    exit 0
else
    echo "Some checks failed. Details: $LOGFILE"
    # Write failed state for validation gate hook
    echo "failed" > "$VALIDATION_STATE_FILE"
    echo "timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$VALIDATION_STATE_FILE"
    echo "logfile=$LOGFILE" >> "$VALIDATION_STATE_FILE"
    echo "failed_checks=$FAILED_CHECKS" >> "$VALIDATION_STATE_FILE"
    [ "$E2E_RAN" = "1" ] && echo "e2e_ran=true" >> "$VALIDATION_STATE_FILE"
    [ "$E2E_FAILED" = "1" ] && echo "e2e_failed=true" >> "$VALIDATION_STATE_FILE"
    exit 1
fi
