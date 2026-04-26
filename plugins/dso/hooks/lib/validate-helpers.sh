#!/usr/bin/env bash
# hooks/lib/validate-helpers.sh
# Pure utility functions extracted from validate.sh:
#   - run_with_timeout: portable cross-platform timeout wrapper
#   - log_timeout: records timeout events to a log file
#   - verbose_print: serialized output for parallel subshells
#   - run_check: runs a check command, stores rc and log
#   - _test_state_already_passed: checks session test state for cached pass
#
# Callers must set the following before sourcing or calling these functions:
#   CHECK_DIR       - temp dir for per-check .rc and .log files
#   TIMEOUT_LOG     - path to timeout event log file
#   VERBOSE         - "1" to enable real-time dot-notation progress
#   CLEANUP_PIDS    - array of background PIDs to kill on exit (for run_with_timeout)
#
# Source this file from validate.sh after setting the above variables.

# Log timeout events for analysis and tuning
# Format: timestamp | command | timeout_value | pwd
log_timeout() {
    local cmd_name="$1"
    local timeout_secs="$2"
    local timestamp
    timestamp=$(date "+%Y-%m-%d %H:%M:%S")

    # Log to file
    echo "$timestamp | TIMEOUT | $cmd_name | ${timeout_secs}s | $(pwd)" >> "$TIMEOUT_LOG"
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

        # Kill the sleep since we don't need it anymore.
        # SIGTERM + SIGKILL ensures the process is dead before wait — avoids
        # a hang if SIGTERM delivery is delayed (observed on macOS).
        kill -TERM "$sleep_pid" 2>/dev/null || true
        kill -KILL "$sleep_pid" 2>/dev/null || true
        # Reap it silently so the shell doesn't print job termination noise
        wait "$sleep_pid" 2>/dev/null || true
    fi

    # Remove sleep_pid from cleanup array (it's handled)
    CLEANUP_PIDS=("${CLEANUP_PIDS[@]/$sleep_pid}")

    return $exit_code
}

# Verbose print helper: serializes output lines using a lock file to prevent
# interleaving from parallel subshells. Uses flock if available, otherwise
# falls back to an atomic temp-file rename trick.
# Usage: verbose_print "name" "state"   e.g. verbose_print "format" "running"
# Requires: VERBOSE_LOCK_FILE to be set (typically "$CHECK_DIR/verbose.lock")
verbose_print() {
    local name="$1" state="$2"
    local line="... ${name}: ${state}"
    if command -v flock &>/dev/null; then
        # flock is available (macOS Homebrew or Linux) — use it for atomicity.
        # Use -w 5 timeout: if a crashed parallel check holds the lock, we fall
        # back to the temp-file path instead of blocking indefinitely.
        local _flock_rc=0
        (
            flock -x -w 5 9 || exit 1
            printf '%s\n' "$line"
        ) 9>"$VERBOSE_LOCK_FILE" || _flock_rc=$?
        if [ "$_flock_rc" -ne 0 ]; then
            # flock timed out or failed — fall back to temp-file output
            local tmp
            tmp=$(mktemp "$CHECK_DIR/verbose.tmp.XXXXXX")
            printf '%s\n' "$line" > "$tmp"
            cat "$tmp"
            rm -f "$tmp"
        fi
    else
        # Fallback: write to a temp file and move atomically (best-effort)
        local tmp
        tmp=$(mktemp "$CHECK_DIR/verbose.tmp.XXXXXX")
        printf '%s\n' "$line" > "$tmp"
        cat "$tmp"
        rm -f "$tmp"
    fi
}

# Run a make-based check in a subshell, storing exit code + log
run_check() {
    local name="$1" timeout="$2"
    shift 2
    local rc=0
    [ "$VERBOSE" = "1" ] && verbose_print "$name" "running"
    run_with_timeout "$timeout" "$name" "$@" > "$CHECK_DIR/${name}.log" 2>&1 || rc=$?
    echo "$rc" > "$CHECK_DIR/${name}.rc"
    if [ "$VERBOSE" = "1" ]; then
        if [ "$rc" = "0" ]; then
            verbose_print "$name" "PASS"
        elif [ "$rc" = "124" ]; then
            verbose_print "$name" "FAIL (timeout ${timeout}s)"
        else
            verbose_print "$name" "FAIL"
        fi
    fi
}

# _test_state_already_passed <state_file> <cmd>
# Returns 0 if the state file records "pass" for the given command.
# Returns 1 if the command has not completed or failed.
# Uses python3 for reliable JSON parsing (no jq dependency).
_test_state_already_passed() {
    local state_file="$1" test_cmd="$2"
    [ -f "$state_file" ] || return 1
    # Compute the expected command hash so we can verify the state file
    # belongs to this command (not a different test command).
    local expected_hash
    expected_hash=$(python3 -c "import hashlib,sys; print(hashlib.sha256(sys.argv[1].encode()).hexdigest())" "${test_cmd}:$(pwd)")
    python3 - "$expected_hash" "$state_file" <<PYEOF 2>/dev/null
import json, sys
expected_hash = sys.argv[1]
state_file = sys.argv[2]
try:
    state = json.load(open(state_file))
    # Verify command hash matches — reject state from a different command.
    stored_hash = state.get("command_hash", "")
    if not stored_hash or stored_hash != expected_hash:
        sys.exit(1)
    results = state.get("results", {})
    completed = state.get("completed", [])
    # Check if any result is "pass" (generic runner uses single test item)
    has_pass = any(v == "pass" for v in results.values())
    has_fail_or_interrupted = any(v in ("fail", "interrupted", "interrupted-timeout-exceeded") for v in results.values())
    # Pass only if we have at least one pass and no failures/interruptions/timeouts
    sys.exit(0 if (has_pass and not has_fail_or_interrupted and len(completed) > 0) else 1)
except Exception:
    sys.exit(1)
PYEOF
}
