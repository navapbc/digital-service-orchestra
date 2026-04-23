#!/usr/bin/env bash
# scripts/runners/pytest-runner.sh — Pytest runner driver
#
# Sourced by test-batched.sh to provide pytest test discovery and execution.
# Uses `pytest --collect-only -q` for upfront test enumeration, then batches
# multiple tests per invocation using `pytest <test_id_1> <test_id_2> ...`.
#
# Requires these variables from the caller (test-batched.sh):
#   RUNNER        — "pytest" for explicit, "" for auto-detect
#   TEST_DIR      — directory to search for tests/**/*.py files
#   COMPLETED_LIST — array of already-completed test IDs (for resume)
#   RESULTS_JSON  — JSON object of results so far
#   STATE_FILE    — path to the JSON state file
#   TIMEOUT       — timeout in seconds
#   DEFAULT_TIMEOUT — default timeout value (for resume command construction)
#   CMD           — fallback command (optional for pytest runner)
#
# After sourcing, the caller checks USE_PYTEST_RUNNER and, if set, calls
# _pytest_runner_run to execute the pytest runner path.
#
# Exports (set by this file):
#   USE_PYTEST_RUNNER  — 1 if pytest runner is active, 0 otherwise
#   PYTEST_TESTS       — array of discovered test IDs (node::test_fn format)
#
# Auto-detect conditions (when RUNNER is empty):
#   - pytest is on PATH
#   - TEST_DIR is set and contains *.py test files matching tests/**/*.py
#
# Falls back to generic when:
#   - pytest is not on PATH
#   - no .py test files are found under TEST_DIR
#   - pytest --collect-only fails (collection error, e.g., syntax error)
#   - pytest --collect-only produces no parseable test IDs (empty collection)

# _pytest_discover_tests <dir>
# Prints one test ID per line using pytest --collect-only -q.
# Returns non-zero if collection fails or yields no tests.
_pytest_discover_tests() {
    local dir="$1"
    local raw_output
    # --collect-only -q produces lines like:
    #   tests/test_foo.py::test_bar
    #   tests/test_foo.py::TestClass::test_method
    # We filter to lines matching the nodeID pattern (contains ::)
    raw_output=$(pytest --collect-only -q --tb=no --no-header "$dir" 2>/dev/null) || return 1
    local found=0
    while IFS= read -r line; do
        # Only emit lines that look like test node IDs (contain ::)
        case "$line" in
            *::*)
                echo "$line"
                found=1
                ;;
        esac
    done <<< "$raw_output"
    [ "$found" -eq 1 ]
}

# Determine effective runner ──────────────────────────────────────────────────
USE_PYTEST_RUNNER=0
PYTEST_TESTS=()

if [ "$RUNNER" = "pytest" ]; then
    # Explicit --runner=pytest: attempt pytest driver; fall back on failures
    if ! command -v pytest >/dev/null 2>&1; then
        echo "WARNING: --runner=pytest requested but pytest is not on PATH; falling back to generic runner." >&2
    elif [ -z "$TEST_DIR" ]; then
        # No test dir — can't discover tests; fall through to generic
        echo "WARNING: --runner=pytest requested but --test-dir not set; falling back to generic runner." >&2
    else
        # Run collection
        _raw_tests=()
        while IFS= read -r t; do
            _raw_tests+=("$t")
        done < <(_pytest_discover_tests "$TEST_DIR" 2>/dev/null || true)

        if [ "${#_raw_tests[@]}" -eq 0 ]; then
            echo "WARNING: --runner=pytest: no tests collected under $TEST_DIR; falling back to generic runner." >&2
        else
            PYTEST_TESTS=("${_raw_tests[@]}")
            USE_PYTEST_RUNNER=1
        fi
    fi
elif [ -z "$RUNNER" ] && [ -n "$TEST_DIR" ]; then
    # Auto-detect: activate pytest driver when pytest is on PATH + .py test files exist
    if command -v pytest >/dev/null 2>&1; then
        # Only auto-detect if there are *.py files matching test patterns under TEST_DIR
        _py_files=()
        while IFS= read -r -d '' f; do
            _py_files+=("$f")
        done < <(find "$TEST_DIR" \( -name 'test_*.py' -o -name '*_test.py' \) -print0 2>/dev/null | sort -z)

        if [ "${#_py_files[@]}" -gt 0 ]; then
            # Attempt collection
            _auto_tests=()
            while IFS= read -r t; do
                _auto_tests+=("$t")
            done < <(_pytest_discover_tests "$TEST_DIR" 2>/dev/null || true)

            if [ "${#_auto_tests[@]}" -gt 0 ]; then
                PYTEST_TESTS=("${_auto_tests[@]}")
                USE_PYTEST_RUNNER=1
                RUNNER="pytest"
            fi
        fi
    fi
fi

# _pytest_runner_run
# Executes the pytest runner path. Called by test-batched.sh when USE_PYTEST_RUNNER=1.
# Runs tests in time-bounded batches; each test ID is a separate item.
# Uses shared state variables from the caller.
_pytest_runner_run() {
    local TOTAL=${#PYTEST_TESTS[@]}
    local START_TIME
    START_TIME=$(date +%s)
    _elapsed() { echo $(( $(date +%s) - START_TIME )); }
    local _pytest_tmpdir
    _pytest_tmpdir=$(mktemp -d /tmp/test-batched-pytest-XXXXXX)
    # Chain with any existing EXIT trap set by caller (e.g., test-batched.sh)
    local _existing_exit_trap
    _existing_exit_trap=$(trap -p EXIT | sed "s/^trap -- '//;s/' EXIT$//")
    if [ -n "$_existing_exit_trap" ]; then
        trap 'rm -rf "$_pytest_tmpdir"; '"$_existing_exit_trap" EXIT
    else
        trap 'rm -rf "$_pytest_tmpdir"' EXIT
    fi

    _save_state_and_resume_pytest() {
        local completed_json results_json
        completed_json=$(_completed_to_json)
        results_json="$RESULTS_JSON"
        _state_write "$STATE_FILE" "pytest:${TEST_DIR}" "$completed_json" "$results_json" 2>/dev/null || {
            echo "WARNING: Could not write state file: $STATE_FILE" >&2
        }
        local done_count=${#COMPLETED_LIST[@]}
        local resume_runner_arg="--runner=pytest"
        local resume_dir_arg="--test-dir=${TEST_DIR}"
        local resume_timeout_arg=""
        [ "$TIMEOUT" -ne "$DEFAULT_TIMEOUT" ] && resume_timeout_arg="--timeout=$TIMEOUT "
        local resume_cmd="TEST_BATCHED_STATE_FILE=$STATE_FILE bash $0 ${resume_runner_arg} ${resume_dir_arg} ${resume_timeout_arg}${CMD:+"'$CMD'"}"
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

    for pytest_test in "${PYTEST_TESTS[@]}"; do
        # Use the test node ID as the test item ID (sanitize for storage)
        local test_id="${pytest_test// /_}"
        test_id="${test_id//[^a-zA-Z0-9_\/.:@-]/}"
        test_id="${test_id:-pytest_test}"

        if _is_completed "$test_id"; then
            echo "Skipping (already completed): $test_id"
            continue
        fi

        # Check timeout before running this test
        if [ "$(_elapsed)" -ge "$TIMEOUT" ]; then
            _save_state_and_resume_pytest
        fi

        echo "Running: pytest $pytest_test"

        # Run pytest in background; capture exit code via wait (no temp file race)
        pytest "$pytest_test" --tb=short -q --no-header &
        local PYTEST_PID=$!
        _ACTIVE_CHILD_PID=$PYTEST_PID

        while kill -0 "$PYTEST_PID" 2>/dev/null; do
            if [ "$(_elapsed)" -ge "$TIMEOUT" ]; then
                _ACTIVE_CHILD_PID=""
                kill -- -"$PYTEST_PID" 2>/dev/null || kill "$PYTEST_PID" 2>/dev/null || true
                wait "$PYTEST_PID" 2>/dev/null || true
                COMPLETED_LIST+=("$test_id")
                RESULTS_JSON=$(_results_add "$RESULTS_JSON" "$test_id" "interrupted")
                _save_state_and_resume_pytest
            fi
            sleep 0.1 2>/dev/null || sleep 1
        done

        _ACTIVE_CHILD_PID=""
        wait "$PYTEST_PID" 2>/dev/null; local pytest_exit=$?

        local pytest_outcome
        if [ "$pytest_exit" -eq 0 ]; then
            pytest_outcome="pass"
        else
            pytest_outcome="fail"
        fi

        COMPLETED_LIST+=("$test_id")
        RESULTS_JSON=$(_results_add "$RESULTS_JSON" "$test_id" "$pytest_outcome")

        local done_count=${#COMPLETED_LIST[@]}
        echo "$done_count/$TOTAL tests completed."
    done

    # All pytest tests processed — print summary
    local pass_count fail_count interrupted_count total_done
    pass_count=$(_results_count "$RESULTS_JSON" "pass")
    fail_count=$(_results_count "$RESULTS_JSON" "fail")
    interrupted_count=$(_results_count "$RESULTS_JSON" "interrupted")
    total_done=${#COMPLETED_LIST[@]}

    echo ""
    echo "All tests done. $total_done/$TOTAL tests completed. $pass_count passed, $fail_count failed, $interrupted_count interrupted."

    if [ "$fail_count" -gt 0 ]; then
        echo ""
        echo "Failures:"
        _results_failures "$RESULTS_JSON" | while IFS= read -r fid; do
            echo "  FAIL: $fid"
        done
    fi

    rm -f "$STATE_FILE"
    # Interrupted tests are non-passing — exit non-zero if any tests failed or were interrupted
    [ "$fail_count" -gt 0 ] || [ "$interrupted_count" -gt 0 ] && exit 1 || exit 0
}
