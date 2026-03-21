#!/usr/bin/env bash
# tests/lib/suite-engine.sh
# Shared parallel test suite runner with per-test timeouts, fail-fast,
# and progress reporting.
#
# Usage (as a script — receives test file paths as arguments):
#   bash suite-engine.sh test1.sh test2.sh test3.sh ...
#
# Usage (sourced — for access to helper functions):
#   source suite-engine.sh
#   run_test_suite "Label" file1.sh file2.sh ...
#
# Environment variables:
#   TEST_TIMEOUT=30              Per-test timeout in seconds (default: 30)
#   MAX_PARALLEL=8               Max concurrent test processes (default: 8)
#   MAX_CONSECUTIVE_FAILS=5      Abort after N consecutive failures (default: 5)
#   SUITE_LABEL="Tests"          Label for progress output (default: "Tests")
#
# Output format:
#   [1/10] test-foo.sh ... PASS (3 pass, 0 fail)
#   [2/10] test-bar.sh ... FAIL (1 pass, 2 fail)
#   [3/10] test-slow.sh ... TIMEOUT (exceeded 30s)
#   ABORT: 5 consecutive failures — likely systemic issue
#
# Aggregated summary:
#   PASSED: 42  FAILED: 3
#
# Exit code: 0 if all pass, 1 if any fail or abort

set -uo pipefail

# Temp dir cleanup on exit
_CLEANUP_DIRS=()
_cleanup() { for d in "${_CLEANUP_DIRS[@]}"; do rm -rf "$d"; done; }
trap _cleanup EXIT

# --- Configuration from environment ---
: "${TEST_TIMEOUT:=30}"
: "${MAX_PARALLEL:=8}"
: "${MAX_CONSECUTIVE_FAILS:=5}"
: "${SUITE_LABEL:=Tests}"

# --- Resolve timeout command (GNU coreutils on macOS = gtimeout) ---
_TIMEOUT_CMD=""
if command -v timeout >/dev/null 2>&1; then
    _TIMEOUT_CMD="timeout"
elif command -v gtimeout >/dev/null 2>&1; then
    _TIMEOUT_CMD="gtimeout"
fi

# --- Parse test output for PASS/FAIL counts ---
# Handles both formats:
#   "PASSED: N  FAILED: N"  (assert.sh)
#   "Results: N passed, N failed"  (custom)
# Outputs: "pass_count fail_count" (space-separated)
_parse_test_counts() {
    local output="$1"
    local clean_output
    # Strip ANSI color codes
    clean_output=$(echo "$output" | sed 's/\x1b\[[0-9;]*m//g')

    # Try "PASSED: N  FAILED: N" (assert.sh pattern)
    local summary_line
    summary_line=$(echo "$clean_output" | grep -E "^PASSED: [0-9]+  FAILED: [0-9]+" | tail -1 || true)
    if [ -n "$summary_line" ]; then
        local p f
        p=$(echo "$summary_line" | grep -oE "PASSED: [0-9]+" | grep -oE "[0-9]+" || echo 0)
        f=$(echo "$summary_line" | grep -oE "FAILED: [0-9]+" | grep -oE "[0-9]+" || echo 0)
        echo "$p $f"
        return
    fi

    # Try "Results: N passed, N failed" or bare "N passed, N failed"
    local results_line
    results_line=$(echo "$clean_output" | grep -E "[0-9]+ passed" | tail -1 || true)
    if [ -n "$results_line" ]; then
        local p f
        p=$(echo "$results_line" | grep -oE "[0-9]+ passed" | grep -oE "[0-9]+" || echo 0)
        f=$(echo "$results_line" | grep -oE "[0-9]+ failed" | grep -oE "[0-9]+" || echo 0)
        echo "$p $f"
        return
    fi

    # No recognized format
    echo "0 0"
}

# --- Run a single test file with timeout ---
# Usage: _run_single_test <test_path> <results_dir>
# Writes to <results_dir>/<basename>.{out,exit,counts}
_run_single_test() {
    local test_path="$1" results_dir="$2"
    local test_name
    test_name=$(basename "$test_path")

    local exit_code=0

    # Write output directly to file — NOT via $() command substitution.
    # $() waits for ALL processes holding the pipe fd to close, so if a test
    # spawns orphan children (background git ops, credential helpers, etc.),
    # the substitution hangs even after timeout kills the main process.
    # Direct file redirection avoids this: timeout kills the child, and we
    # read the file afterward regardless of orphan process state.
    if [ -n "$_TIMEOUT_CMD" ]; then
        "$_TIMEOUT_CMD" --signal=TERM --kill-after=5 "$TEST_TIMEOUT" \
            bash "$test_path" > "$results_dir/$test_name.out" 2>&1 || exit_code=$?
    else
        bash "$test_path" > "$results_dir/$test_name.out" 2>&1 || exit_code=$?
    fi

    echo "$exit_code" > "$results_dir/$test_name.exit"

    # Parse counts
    if [ "$exit_code" -eq 124 ] || [ "$exit_code" -eq 137 ]; then
        # Timeout (124 = TERM, 137 = KILL)
        echo "0 0 timeout" > "$results_dir/$test_name.counts"
    else
        local counts output
        output=$(cat "$results_dir/$test_name.out")
        counts=$(_parse_test_counts "$output")
        echo "$counts" > "$results_dir/$test_name.counts"
    fi
}

# --- Main suite runner ---
# Usage: run_test_suite "Label" test1.sh test2.sh ...
# Sets SUITE_TOTAL_PASS and SUITE_TOTAL_FAIL on return.
run_test_suite() {
    local label="$1"
    shift
    local test_files=("$@")
    local total=${#test_files[@]}

    SUITE_TOTAL_PASS=0
    SUITE_TOTAL_FAIL=0
    local consecutive_fails=0
    local aborted=false
    local failed_tests=()

    local results_dir
    results_dir=$(mktemp -d)
    _CLEANUP_DIRS+=("$results_dir")

    # --- Parallel execution ---
    local index=0
    local running_pids=()
    local running_names=()
    local running_indices=()

    while [ "$index" -lt "$total" ] || [ ${#running_pids[@]} -gt 0 ]; do
        # Launch new tests up to MAX_PARALLEL
        while [ "$index" -lt "$total" ] && [ ${#running_pids[@]} -lt "$MAX_PARALLEL" ]; do
            if [ "$aborted" = true ]; then
                break
            fi
            local test_file="${test_files[$index]}"
            _run_single_test "$test_file" "$results_dir" &
            running_pids+=($!)
            running_names+=("$(basename "$test_file")")
            running_indices+=($index)
            (( index++ ))
        done

        if [ ${#running_pids[@]} -eq 0 ]; then
            break
        fi

        # Wait for all current batch to complete
        for i in "${!running_pids[@]}"; do
            wait "${running_pids[$i]}" 2>/dev/null || true
            local tname="${running_names[$i]}"
            local tidx="${running_indices[$i]}"

            # Read results
            local exit_code=0
            if [ -f "$results_dir/$tname.exit" ]; then
                exit_code=$(cat "$results_dir/$tname.exit")
            fi

            local counts_line="0 0"
            local is_timeout=false
            if [ -f "$results_dir/$tname.counts" ]; then
                counts_line=$(cat "$results_dir/$tname.counts")
                if echo "$counts_line" | grep -q "timeout"; then
                    is_timeout=true
                    counts_line="0 0"
                fi
            fi

            local file_pass file_fail
            file_pass=$(echo "$counts_line" | awk '{print $1}')
            file_fail=$(echo "$counts_line" | awk '{print $2}')

            # Progress output
            local display_idx=$(( tidx + 1 ))
            if [ "$is_timeout" = true ]; then
                printf "[%d/%d] %s ... TIMEOUT (exceeded %ss)\n" "$display_idx" "$total" "$tname" "$TEST_TIMEOUT"
                # Count timeout as 1 failure
                (( file_fail++ ))
            elif [ "$exit_code" -ne 0 ]; then
                printf "[%d/%d] %s ... FAIL (%d pass, %d fail)\n" "$display_idx" "$total" "$tname" "$file_pass" "$file_fail"
                # If no counts parsed but exit non-zero, count as 1 fail
                if [ "$file_pass" -eq 0 ] && [ "$file_fail" -eq 0 ]; then
                    (( file_fail++ ))
                fi
            else
                printf "[%d/%d] %s ... PASS (%d pass, %d fail)\n" "$display_idx" "$total" "$tname" "$file_pass" "$file_fail"
            fi

            SUITE_TOTAL_PASS=$(( SUITE_TOTAL_PASS + file_pass ))
            SUITE_TOTAL_FAIL=$(( SUITE_TOTAL_FAIL + file_fail ))

            # Track consecutive failures for fail-fast
            if [ "$exit_code" -ne 0 ] || [ "$is_timeout" = true ]; then
                failed_tests+=("$tname")
                (( consecutive_fails++ ))
            else
                consecutive_fails=0
            fi

            if [ "$consecutive_fails" -ge "$MAX_CONSECUTIVE_FAILS" ]; then
                aborted=true
            fi
        done

        running_pids=()
        running_names=()
        running_indices=()

        if [ "$aborted" = true ]; then
            break
        fi
    done

    if [ "$aborted" = true ]; then
        local skipped=$(( total - index ))
        if [ "$skipped" -lt 0 ]; then skipped=0; fi
        printf "\nABORT: %d consecutive failures — likely systemic issue (%d tests skipped)\n" \
            "$MAX_CONSECUTIVE_FAILS" "$skipped" >&2
    fi

    # Dump output of failed tests for CI visibility
    if [ ${#failed_tests[@]} -gt 0 ] && [ -d "$results_dir" ]; then
        echo ""
        echo "=== Failed test output ==="
        for ftname in "${failed_tests[@]}"; do
            if [ -f "$results_dir/$ftname.out" ]; then
                echo "--- $ftname ---"
                # Limit to last 30 lines to avoid flooding CI logs
                tail -30 "$results_dir/$ftname.out"
                echo "--- end $ftname ---"
            fi
        done
        echo "=== End failed test output ==="
    fi

    # Print aggregated summary
    echo ""
    printf "PASSED: %d  FAILED: %d\n" "$SUITE_TOTAL_PASS" "$SUITE_TOTAL_FAIL"

    rm -rf "$results_dir"

    if [ "$SUITE_TOTAL_FAIL" -gt 0 ] || [ "$aborted" = true ]; then
        return 1
    fi
    return 0
}

# --- Script mode: run when invoked directly with test file args ---
if [ "${BASH_SOURCE[0]}" = "$0" ] && [ $# -gt 0 ]; then
    run_test_suite "$SUITE_LABEL" "$@"
    exit $?
fi
