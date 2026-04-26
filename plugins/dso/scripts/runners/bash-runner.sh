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
#
# RED zone tolerance: when SUITE_TEST_INDEX env var points to a .test-index file,
# failures whose failing test functions are at/after a function-level RED marker
# are reclassified as 'pass' (with `_red_zone_tolerated_count` reported). This
# mirrors the behavior of tests/lib/suite-engine.sh so validate.sh's test runner
# matches the CI harness's tolerance semantics.
_bash_runner_run() {
    local TOTAL=${#BASH_FILES[@]}
    local START_TIME

    # Ensure CLAUDE_PLUGIN_ROOT is exported so child test processes that cd into
    # temp git repos can resolve the dso shim. Without this, tests that invoke
    # `.claude/scripts/dso ...` from inside a freshly-init'd temp repo fail
    # silently (shim emits "DSO plugin root not configured" to stderr, hooks
    # suppress stderr → tests misread the failure as "ticket not found").
    # Mirrors tests/hooks/run-hook-tests.sh:31 semantics. Only set if unset.
    if [ -z "${CLAUDE_PLUGIN_ROOT:-}" ]; then
        local _br_self_dir _br_resolved_root
        _br_self_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
        _br_resolved_root="$(cd "$_br_self_dir/../.." && pwd)"  # CLAUDE_PLUGIN_ROOT fallback
        export CLAUDE_PLUGIN_ROOT="$_br_resolved_root"
    fi

    # ── RED zone tolerance setup (mirrors tests/lib/suite-engine.sh) ─────────
    local _RED_ZONE_ENABLED=false
    declare -A _RED_MARKER_MAP=()
    local _red_zone_tolerated_count=0
    if [[ -n "${SUITE_TEST_INDEX:-}" ]] && [[ -f "${SUITE_TEST_INDEX}" ]]; then
        # Locate red-zone.sh — sibling to test-batched.sh's hooks/lib (this
        # script lives at $_PLUGIN_ROOT/scripts/runners/, so ../../../hooks/lib).
        local _br_dir _red_zone_sh="" _br_plugin_root
        _br_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
        _br_plugin_root="$(cd "$_br_dir/../.." && pwd)"  # CLAUDE_PLUGIN_ROOT-style fallback
        if [[ -f "$_br_plugin_root/hooks/lib/red-zone.sh" ]]; then
            _red_zone_sh="$_br_plugin_root/hooks/lib/red-zone.sh"
        fi
        if [[ -n "$_red_zone_sh" ]]; then
            # shellcheck source=../../hooks/lib/red-zone.sh
            source "$_red_zone_sh"
            _RED_ZONE_ENABLED=true
            # Build marker map from .test-index. Format:
            #   source/path: test/path1[, test/path2 [marker]]
            local _line _right _part _ppath _pmarker
            while IFS= read -r _line || [[ -n "$_line" ]]; do
                [[ -z "$_line" ]] && continue
                [[ "$_line" =~ ^[[:space:]]*# ]] && continue
                _right="${_line#*:}"
                local _IFS_save="$IFS"
                IFS=','
                # shellcheck disable=SC2206
                local _parts=( $_right )
                IFS="$_IFS_save"
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
        fi
    fi

    # _check_red_zone_tolerance <test_id> <out_file>
    # Returns 0 (tolerated) when SUITE_TEST_INDEX is enabled, the test has a
    # marker, and ALL failing test functions parsed from $out_file appear at or
    # after the marker line in the test file. Otherwise returns 1.
    _check_red_zone_tolerance() {
        local _t_id="$1" _t_out="$2"
        [[ "$_RED_ZONE_ENABLED" != true ]] && return 1
        local _marker=""
        if [[ -n "${_RED_MARKER_MAP[$_t_id]:-}" ]]; then
            _marker="${_RED_MARKER_MAP[$_t_id]}"
        else
            local _mk
            for _mk in "${!_RED_MARKER_MAP[@]}"; do
                if [[ -n "${_RED_MARKER_MAP[$_mk]}" ]] && [[ "$_t_id" == *"$_mk" ]]; then
                    _marker="${_RED_MARKER_MAP[$_mk]}"
                    break
                fi
            done
        fi
        [[ -z "$_marker" ]] && return 1
        local _t_path="$_t_id"
        [[ -f "$_repo_root/$_t_id" ]] && _t_path="$_repo_root/$_t_id"
        [[ ! -f "$_t_path" ]] && return 1
        local _marker_line
        _marker_line=$(REPO_ROOT="$_repo_root" get_red_zone_line_number "$_t_id" "$_marker" 2>/dev/null || echo -1)
        [[ "$_marker_line" -le 0 ]] && return 1
        local _failing
        _failing=$(parse_failing_tests_from_output "$_t_out" 2>/dev/null || true)
        [[ -z "$_failing" ]] && return 1
        local _ft _ft_line
        while IFS= read -r _ft; do
            [[ -z "$_ft" ]] && continue
            _ft_line=$(REPO_ROOT="$_repo_root" get_test_line_number "$_t_id" "$_ft" 2>/dev/null || echo -1)
            [[ "$_ft_line" -le 0 || "$_ft_line" -lt "$_marker_line" ]] && return 1
        done <<< "$_failing"
        return 0
    }

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
        _state_write "$STATE_FILE" "bash:${TEST_DIR}" "$completed_json" "$results_json" "${CMD_HASH:-}" "$SESSION_CREATED_AT" 2>/dev/null || {
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

        # Capture stdout+stderr to a file for RED-zone tolerance lookup
        # (parses failing test names from the output). Avoid `| tee` here —
        # piping makes _test_bg_pid the tee PID, breaking `wait` exit-code
        # capture (race-free wait is essential per the comment below).
        local _test_out_file
        _test_out_file="$_bash_tmpdir/$(basename "$bash_file").out"

        # Launch the test script as a direct background child.  Exit-code capture
        # uses `wait <pid>` — which is synchronous and race-free — instead of the
        # previous approach of writing "$?" to a file from inside a subshell and then
        # reading it from the parent (which could race with file-system buffering on
        # busy or network-mounted filesystems).
        local bash_exit=0
        bash "$bash_file" > "$_test_out_file" 2>&1 &
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

        # Surface the test's captured output to stdout for visibility.
        [ -f "$_test_out_file" ] && cat "$_test_out_file"

        local bash_outcome
        if [ "$bash_exit" -eq 0 ]; then
            bash_outcome="pass"
        elif _check_red_zone_tolerance "$test_id" "$_test_out_file"; then
            # RED-zone tolerated: failing test functions are at/after the marker.
            bash_outcome="pass"
            _red_zone_tolerated_count=$(( _red_zone_tolerated_count + 1 ))
            echo "TOLERATED (red-zone): $test_id"
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
