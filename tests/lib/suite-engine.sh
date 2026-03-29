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

# --- RED zone tolerance (optional, enabled when SUITE_TEST_INDEX is set) ---
# Source red-zone.sh for parse_failing_tests_from_output helper
_RED_ZONE_ENABLED=false
declare -A _RED_MARKER_MAP=()
if [[ -n "${SUITE_TEST_INDEX:-}" ]] && [[ -f "${SUITE_TEST_INDEX}" ]]; then
    _RED_ZONE_ENABLED=true
    # Source red-zone.sh (located next to this file or in the hooks lib dir)
    _SE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    _RED_ZONE_SH=""
    # Check sibling dirs: tests/lib -> plugins/dso/hooks/lib
    _REPO_ROOT_GUESS="$(cd "$_SE_DIR/../.." && pwd)"
    if [[ -f "$_SE_DIR/red-zone.sh" ]]; then
        _RED_ZONE_SH="$_SE_DIR/red-zone.sh"
    elif [[ -f "$_REPO_ROOT_GUESS/plugins/dso/hooks/lib/red-zone.sh" ]]; then
        _RED_ZONE_SH="$_REPO_ROOT_GUESS/plugins/dso/hooks/lib/red-zone.sh"
    fi
    if [[ -n "$_RED_ZONE_SH" ]]; then
        # shellcheck source=../plugins/dso/hooks/lib/red-zone.sh
        source "$_RED_ZONE_SH"

        # Build marker map from SUITE_TEST_INDEX file.
        # Format: source/path.ext: test/path.ext [marker_name], ...
        # We parse the file directly (can't use read_red_markers_by_test_file
        # because that function builds the path as ${REPO_ROOT}/${test_file},
        # which breaks for absolute test-file paths in fixture environments).
        while IFS= read -r _line || [[ -n "$_line" ]]; do
            [[ -z "$_line" ]] && continue
            [[ "$_line" =~ ^[[:space:]]*# ]] && continue
            _right="${_line#*:}"
            IFS=',' read -ra _parts <<< "$_right"
            for _part in "${_parts[@]}"; do
                _part="${_part#"${_part%%[![:space:]]*}"}"
                _part="${_part%"${_part##*[![:space:]]}"}"
                [[ -z "$_part" ]] && continue
                _ppath="" _pmarker=""
                if [[ "$_part" =~ ^(.*[^[:space:]])[[:space:]]+\[([^]]+)\]$ ]]; then
                    _ppath="${BASH_REMATCH[1]}"
                    _pmarker="${BASH_REMATCH[2]}"
                    _ppath="${_ppath%"${_ppath##*[![:space:]]}"}"
                else
                    _ppath="$_part"
                    _pmarker=""
                fi
                if [[ -n "$_pmarker" ]] || [[ -z "${_RED_MARKER_MAP[$_ppath]:-}" ]]; then
                    _RED_MARKER_MAP["$_ppath"]="$_pmarker"
                fi
            done
        done < "${SUITE_TEST_INDEX}"
    else
        # red-zone.sh not found — disable RED tolerance gracefully
        _RED_ZONE_ENABLED=false
    fi
fi

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
    SUITE_TOTAL_TOLERATED=0
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
    local running_paths=()

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
            running_paths+=("$test_file")
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
            local tpath="${running_paths[$i]}"

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
            local is_tolerated=false
            if [ "$is_timeout" = true ]; then
                printf "[%d/%d] %s ... TIMEOUT (exceeded %ss)\n" "$display_idx" "$total" "$tname" "$TEST_TIMEOUT"
                # Count timeout as 1 failure
                (( file_fail++ ))
            elif [ "$exit_code" -ne 0 ]; then
                # If no counts parsed but exit non-zero, count as 1 fail
                if [ "$file_pass" -eq 0 ] && [ "$file_fail" -eq 0 ]; then
                    (( file_fail++ ))
                fi

                # --- RED zone tolerance check ---
                # If SUITE_TEST_INDEX is set and this test file has a RED marker,
                # check whether ALL failures are in the RED zone (at or after marker).
                # If yes → TOLERATED (don't count as failure, exit 0 still possible).
                # If no or unparseable → keep as FAIL (conservative fail-safe).
                #
                # Path matching: try exact match first (for absolute paths in index),
                # then suffix match (for relative paths like "tests/hooks/test-foo.sh"
                # in index vs absolute path in tpath). This handles both fixture tests
                # (which store absolute paths) and real .test-index (relative paths).
                local _red_marker_lookup=""
                if [[ -n "${_RED_MARKER_MAP[$tpath]:-}" ]]; then
                    _red_marker_lookup="${_RED_MARKER_MAP[$tpath]}"
                else
                    # Try suffix match: find a key in the map whose value matches
                    # and whose key is a suffix of tpath (handles relative vs absolute)
                    local _mk
                    for _mk in "${!_RED_MARKER_MAP[@]}"; do
                        if [[ -n "${_RED_MARKER_MAP[$_mk]}" ]] && [[ "$tpath" == *"$_mk" ]]; then
                            _red_marker_lookup="${_RED_MARKER_MAP[$_mk]}"
                            break
                        fi
                    done
                fi
                if [[ "$_RED_ZONE_ENABLED" = true ]] && [[ -n "$_red_marker_lookup" ]]; then
                    local _marker="$_red_marker_lookup"
                    local _out_file="$results_dir/$tname.out"

                    # Get the line number of the RED marker in the test file
                    local _marker_line=-1
                    if [[ -f "$tpath" ]]; then
                        local _lnum=0
                        local _mpat="(^|[^a-zA-Z0-9_-])${_marker}([^a-zA-Z0-9_-]|\$)"
                        while IFS= read -r _ml || [[ -n "$_ml" ]]; do
                            (( _lnum++ )) || true
                            [[ "$_ml" =~ ^[[:space:]]*# ]] && continue
                            if [[ "$_ml" =~ $_mpat ]]; then
                                _marker_line=$_lnum
                                break
                            fi
                        done < "$tpath"
                    fi

                    if [[ "$_marker_line" -gt 0 ]]; then
                        # Parse failing test names from output
                        local _failing_tests
                        _failing_tests=$(parse_failing_tests_from_output "$_out_file" 2>/dev/null || true)

                        if [[ -n "$_failing_tests" ]]; then
                            # Check each failing test's line number >= marker line
                            local _all_in_zone=true
                            while IFS= read -r _ft; do
                                [[ -z "$_ft" ]] && continue
                                local _ft_line=-1
                                local _flnum=0
                                local _ftpat="(^|[^a-zA-Z0-9_-])${_ft}([^a-zA-Z0-9_-]|\$)"
                                while IFS= read -r _fl || [[ -n "$_fl" ]]; do
                                    (( _flnum++ )) || true
                                    [[ "$_fl" =~ ^[[:space:]]*# ]] && continue
                                    if [[ "$_fl" =~ $_ftpat ]]; then
                                        _ft_line=$_flnum
                                        break
                                    fi
                                done < "$tpath"
                                if [[ "$_ft_line" -lt "$_marker_line" ]]; then
                                    _all_in_zone=false
                                    break
                                fi
                            done <<< "$_failing_tests"

                            if [[ "$_all_in_zone" = true ]]; then
                                is_tolerated=true
                            fi
                        fi
                        # If _failing_tests is empty (unparseable) → _all_in_zone stays
                        # false implicitly because we never set is_tolerated=true
                    fi
                fi

                if [[ "$is_tolerated" = true ]]; then
                    printf "[%d/%d] %s ... TOLERATED (%d pass, %d red-zone)\n" \
                        "$display_idx" "$total" "$tname" "$file_pass" "$file_fail"
                    SUITE_TOTAL_TOLERATED=$(( SUITE_TOTAL_TOLERATED + file_fail ))
                    file_fail=0
                else
                    printf "[%d/%d] %s ... FAIL (%d pass, %d fail)\n" "$display_idx" "$total" "$tname" "$file_pass" "$file_fail"
                fi
            else
                printf "[%d/%d] %s ... PASS (%d pass, %d fail)\n" "$display_idx" "$total" "$tname" "$file_pass" "$file_fail"
            fi

            SUITE_TOTAL_PASS=$(( SUITE_TOTAL_PASS + file_pass ))
            SUITE_TOTAL_FAIL=$(( SUITE_TOTAL_FAIL + file_fail ))

            # Track consecutive failures for fail-fast
            if [ "$is_timeout" = true ]; then
                failed_tests+=("$tname")
                (( consecutive_fails++ ))
            elif [ "$exit_code" -ne 0 ] && [ "$is_tolerated" = false ]; then
                failed_tests+=("$tname")
                (( consecutive_fails++ ))
            elif [ "$exit_code" -eq 0 ] || [ "$is_tolerated" = true ]; then
                consecutive_fails=0
            fi

            if [ "$consecutive_fails" -ge "$MAX_CONSECUTIVE_FAILS" ]; then
                aborted=true
            fi
        done

        running_pids=()
        running_names=()
        running_indices=()
        running_paths=()

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
    if [[ "$_RED_ZONE_ENABLED" = true ]] && [[ "${SUITE_TOTAL_TOLERATED:-0}" -gt 0 ]]; then
        printf "PASSED: %d  FAILED: %d  TOLERATED: %d\n" \
            "$SUITE_TOTAL_PASS" "$SUITE_TOTAL_FAIL" "$SUITE_TOTAL_TOLERATED"
    else
        printf "PASSED: %d  FAILED: %d\n" "$SUITE_TOTAL_PASS" "$SUITE_TOTAL_FAIL"
    fi

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
