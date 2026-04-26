#!/usr/bin/env bash
# scripts/runners/bash-runner.sh — Bash test script runner driver
#
# Sourced by test-batched.sh to provide bash test script discovery and
# execution. Discovers test-*.sh files under --test-dir and runs each
# as a separate test item, enabling per-script resume on timeout.
#
# Requires these variables from the caller (test-batched.sh):
#   RUNNER        — "bash" for explicit, "" for auto-detect
#   TEST_DIR      — directory to search for test-*.sh files
#   COMPLETED_LIST — array of already-completed test IDs (for resume)
#   RESULTS_JSON  — JSON object of results so far
#   STATE_FILE    — path to the JSON state file
#   TIMEOUT       — timeout in seconds
#   DEFAULT_TIMEOUT — default timeout value (for resume command construction)
#   CMD           — fallback command (optional for bash runner)
#   FILTER_PATTERN — optional glob pattern; when set, only test files whose
#                    basename matches the pattern are run (set by test-batched.sh)
#
# After sourcing, the caller checks USE_BASH_RUNNER and, if set, calls
# _bash_runner_run to execute the bash runner path.
#
# Exports (set by this file):
#   USE_BASH_RUNNER  — 1 if bash runner is active, 0 otherwise
#   BASH_FILES       — array of discovered test script paths

# _bash_discover_files <dir>
# Prints one file path per line for test-*.sh files; returns non-zero if none found.
# Excludes run-*-tests.sh aggregator scripts — these are suite orchestrators that
# run all test-*.sh files internally. Including them causes the batched runner to
# treat the entire suite as a single test item, which gets killed by the time budget
# and prevents per-file resume from working.
_bash_discover_files() {
    local dir="$1"
    local found=0
    # Use a while loop with sorted glob expansion for portability (no find -print0)
    while IFS= read -r f; do
        [ -f "$f" ] && [ -x "$f" ] && { echo "$f"; found=1; }
    done < <(find "$dir" -maxdepth 1 -name 'test-*.sh' -print 2>/dev/null | sort)
    [ "$found" -eq 1 ]
}

# _bash_discover_all_dirs <colon-separated-dirs>
# Discovers test-*.sh files from all directories in a colon-separated list.
# Calls _bash_discover_files for each segment.
_bash_discover_all_dirs() {
    local dirs="${1:-}"
    local _saved_IFS="$IFS"
    IFS=:
    # shellcheck disable=SC2086
    set -- $dirs
    IFS="$_saved_IFS"
    local _found_any=1
    for _d in "$@"; do
        [ -n "$_d" ] && _bash_discover_files "$_d" && _found_any=0
    done
    return "$_found_any"
}

# _bash_apply_filter <pattern>
# Filters BASH_FILES in-place, keeping only files whose basename matches
# the given glob pattern. When no files match, prints a warning to stderr.
# No-op when pattern is empty.
_bash_apply_filter() {
    local pattern="${1:-}"
    [ -z "$pattern" ] && return 0
    local filtered=()
    for f in "${BASH_FILES[@]+"${BASH_FILES[@]}"}"; do
        local base
        base="$(basename "$f")"
        # shellcheck disable=SC2254
        case "$base" in
            $pattern) filtered+=("$f") ;;
        esac
    done
    if [ "${#filtered[@]}" -eq 0 ]; then
        echo "WARNING: --filter=$pattern: no test files matched; nothing to run." >&2
    fi
    BASH_FILES=("${filtered[@]+"${filtered[@]}"}")
}

# Determine effective runner ──────────────────────────────────────────────────
USE_BASH_RUNNER=0
BASH_FILES=()

if [ "$RUNNER" = "bash" ]; then
    # Explicit --runner=bash: attempt bash driver; fall back on failures
    if [ -z "$TEST_DIR" ]; then
        echo "WARNING: --runner=bash requested but --test-dir not set; falling back to generic runner." >&2
    else
        while IFS= read -r f; do
            BASH_FILES+=("$f")
        done < <(_bash_discover_all_dirs "$TEST_DIR" 2>/dev/null || true)

        # Apply filename filter if set
        _bash_apply_filter "${FILTER_PATTERN:-}"

        if [ "${#BASH_FILES[@]}" -eq 0 ]; then
            if [ -n "${FILTER_PATTERN:-}" ]; then
                # Filter matched nothing — warning already printed; exit cleanly (not an error).
                exit 0
            else
                echo "WARNING: --runner=bash: no test-*.sh files found under $TEST_DIR; falling back to generic runner." >&2
            fi
        else
            USE_BASH_RUNNER=1
        fi
    fi
elif [ -z "$RUNNER" ] && [ -n "$TEST_DIR" ]; then
    # Auto-detect: activate bash driver when test-*.sh files exist under TEST_DIR
    # Only auto-detect if node and pytest didn't already claim the runner
    while IFS= read -r f; do
        BASH_FILES+=("$f")
    done < <(_bash_discover_all_dirs "$TEST_DIR" 2>/dev/null || true)

    # Apply filename filter if set
    _bash_apply_filter "${FILTER_PATTERN:-}"

    if [ "${#BASH_FILES[@]}" -gt 0 ]; then
        USE_BASH_RUNNER=1
        RUNNER="bash"
    fi
fi

# _bash_runner_run
# Executes the bash runner path. Called by test-batched.sh when USE_BASH_RUNNER=1.
# Uses all shared state variables from the caller.
_bash_runner_run() {
    local TOTAL=${#BASH_FILES[@]}
    local START_TIME
    # Use the global script entry time if available so the time budget accounts
    # for startup overhead (state parsing, test discovery, path canonicalization).
    # This prevents the runner's "50s" timeout from actually consuming 50s + overhead,
    # which can exceed the ~73s Claude Code tool timeout ceiling (bug d04e-2f91).
    START_TIME="${_SCRIPT_ENTRY_TIME:-$(date +%s)}"
    # Preserve created_at from existing state (if resuming), otherwise use now.
    local SESSION_CREATED_AT="${_state_created_at:-$START_TIME}"
    _elapsed() { echo $(( $(date +%s) - START_TIME )); }
    local _bash_tmpdir
    _bash_tmpdir=$(mktemp -d /tmp/test-batched-bash-XXXXXX)
    local _existing_exit_trap
    _existing_exit_trap=$(trap -p EXIT | sed "s/^trap -- '//;s/' EXIT$//")
    if [ -n "$_existing_exit_trap" ]; then
        trap 'rm -rf "$_bash_tmpdir"; '"$_existing_exit_trap" EXIT
    else
        trap 'rm -rf "$_bash_tmpdir"' EXIT
    fi

    _save_state_and_resume_bash() {
        local completed_json results_json
        completed_json=$(_completed_to_json)
        results_json="$RESULTS_JSON"
        _state_write "$STATE_FILE" "bash:${TEST_DIR}" "$completed_json" "$results_json" "" "$SESSION_CREATED_AT" 2>/dev/null || {
            echo "WARNING: Could not write state file: $STATE_FILE" >&2
        }
        local done_count=${#COMPLETED_LIST[@]}
        local resume_runner_arg="--runner=bash"
        local resume_dir_arg="--test-dir=${TEST_DIR}"
        local resume_timeout_arg=""
        [ "$TIMEOUT" -ne "$DEFAULT_TIMEOUT" ] && resume_timeout_arg="--timeout=$TIMEOUT "
        local resume_filter_arg=""
        [ -n "${FILTER_PATTERN:-}" ] && resume_filter_arg="--filter=${FILTER_PATTERN} "
        local resume_cmd="TEST_BATCHED_STATE_FILE=$STATE_FILE bash $0 ${resume_runner_arg} ${resume_dir_arg} ${resume_timeout_arg}${resume_filter_arg}${CMD:+"'$CMD'"}"
        echo ""
        echo "$done_count/$TOTAL tests completed."
        echo ""
        echo "════════════════════════════════════════════════════════════"
        echo "  ⚠  ACTION REQUIRED — TESTS NOT COMPLETE  ⚠"
        echo "════════════════════════════════════════════════════════════"
        echo "RUN: $resume_cmd"
        echo "DO NOT PROCEED until the command above prints a final summary."
        echo "════════════════════════════════════════════════════════════"
        exit 0
    }

    # Resolve repo root once for stable, collision-free test IDs across multiple dirs.
    # With colon-separated --test-dir, files from different directories must have
    # distinct IDs — using repo-relative paths guarantees uniqueness.
    local _repo_root
    _repo_root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"

    for bash_file in "${BASH_FILES[@]}"; do
        # Use repo-relative path as test ID — unique across multi-dir runs and
        # stable across re-invocations regardless of the working directory.
        local test_id
        local _abs_bash_file
        _abs_bash_file="$(cd "$(dirname "$bash_file")" && pwd)/$(basename "$bash_file")"
        test_id="${_abs_bash_file#"${_repo_root}/"}"
        # Fallback to basename when outside the repo (e.g. tmpdir paths) to preserve
        # backward-compatible state file format. Multi-dir uniqueness is guaranteed for
        # in-repo files (distinct repo-relative paths); temp dirs in tests use unique names.
        [ -z "$test_id" ] || [ "$test_id" = "$_abs_bash_file" ] && test_id="$(basename "$bash_file")"

        if _is_completed "$test_id"; then
            echo "Skipping (already completed): $test_id"
            continue
        fi

        # Check timeout before running this file
        if [ "$(_elapsed)" -ge "$TIMEOUT" ]; then
            _save_state_and_resume_bash
        fi

        echo "Running: bash $bash_file"

        # Launch the test script as a direct background child.  Exit-code capture
        # uses `wait <pid>` — which is synchronous and race-free — instead of the
        # previous approach of writing "$?" to a file from inside a subshell and then
        # reading it from the parent (which could race with file-system buffering on
        # busy or network-mounted filesystems).
        local bash_exit=0
        bash "$bash_file" &
        local _test_bg_pid=$!
        _ACTIVE_CHILD_PID=$_test_bg_pid
        local _test_start_time
        _test_start_time=$(date +%s)

        # Monitor: poll until the test finishes or the time budget runs out.
        while kill -0 "$_test_bg_pid" 2>/dev/null; do
            # Per-test timeout: if this individual test has run longer than
            # PER_TEST_TIMEOUT seconds, mark it as terminal (not retried on resume).
            if [ -n "${PER_TEST_TIMEOUT:-}" ] && [ $(( $(date +%s) - _test_start_time )) -ge "$PER_TEST_TIMEOUT" ]; then
                _ACTIVE_CHILD_PID=""
                kill -- -"$_test_bg_pid" 2>/dev/null || kill "$_test_bg_pid" 2>/dev/null || true
                wait "$_test_bg_pid" 2>/dev/null || true
                COMPLETED_LIST+=("$test_id")
                RESULTS_JSON=$(_results_add "$RESULTS_JSON" "$test_id" "interrupted-timeout-exceeded")
                _save_state_and_resume_bash
            fi
            if [ "$(_elapsed)" -ge "$TIMEOUT" ]; then
                # Kill entire process group (negative PID) so child processes
                # spawned by the test script don't survive as orphans.
                _ACTIVE_CHILD_PID=""
                kill -- -"$_test_bg_pid" 2>/dev/null || kill "$_test_bg_pid" 2>/dev/null || true
                wait "$_test_bg_pid" 2>/dev/null || true
                COMPLETED_LIST+=("$test_id")
                RESULTS_JSON=$(_results_add "$RESULTS_JSON" "$test_id" "interrupted")
                _save_state_and_resume_bash
            fi
            sleep 0.1 2>/dev/null || sleep 1
        done

        # `wait` on a direct child always returns the child's actual exit code —
        # no file-write race is possible here.
        _ACTIVE_CHILD_PID=""
        wait "$_test_bg_pid" 2>/dev/null; bash_exit=$?

        local bash_outcome
        if [ "$bash_exit" -eq 0 ]; then
            bash_outcome="pass"
        else
            bash_outcome="fail"
        fi

        COMPLETED_LIST+=("$test_id")
        RESULTS_JSON=$(_results_add "$RESULTS_JSON" "$test_id" "$bash_outcome")

        local done_count=${#COMPLETED_LIST[@]}
        echo "$done_count/$TOTAL tests completed."
    done

    # All bash files processed — print summary
    local pass_count fail_count interrupted_count timed_out_count total_done
    pass_count=$(_results_count "$RESULTS_JSON" "pass")
    fail_count=$(_results_count "$RESULTS_JSON" "fail")
    interrupted_count=$(_results_count "$RESULTS_JSON" "interrupted")
    timed_out_count=$(_results_count "$RESULTS_JSON" "interrupted-timeout-exceeded")
    total_done=${#COMPLETED_LIST[@]}

    echo ""
    if [ "$timed_out_count" -gt 0 ]; then
        echo "All tests done. $total_done/$TOTAL tests completed. $pass_count passed, $fail_count failed, $interrupted_count interrupted, $timed_out_count timed-out (skipped on resume)."
    else
        echo "All tests done. $total_done/$TOTAL tests completed. $pass_count passed, $fail_count failed, $interrupted_count interrupted."
    fi

    if [ "$fail_count" -gt 0 ]; then
        echo ""
        echo "Failures:"
        _results_failures "$RESULTS_JSON" | while IFS= read -r fid; do
            echo "  FAIL: $fid"
        done
    fi

    rm -f "$STATE_FILE"
    # Interrupted and timed-out tests are non-passing — exit non-zero if any tests failed or were interrupted
    [ "$fail_count" -gt 0 ] || [ "$interrupted_count" -gt 0 ] || [ "$timed_out_count" -gt 0 ] && exit 1 || exit 0
}
