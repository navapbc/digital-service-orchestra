#!/usr/bin/env bash
# scripts/runners/node-runner.sh — Node.js runner driver
#
# Sourced by test-batched.sh to provide Node.js test file discovery and
# execution. Sets USE_NODE_RUNNER=1 and NODE_FILES array when activated.
#
# Requires these variables from the caller (test-batched.sh):
#   RUNNER        — "node" for explicit, "" for auto-detect
#   TEST_DIR      — directory to search for .test.js / .test.mjs files
#   COMPLETED_LIST — array of already-completed test IDs (for resume)
#   RESULTS_JSON  — JSON object of results so far
#   STATE_FILE    — path to the JSON state file
#   TIMEOUT       — timeout in seconds
#   DEFAULT_TIMEOUT — default timeout value (for resume command construction)
#   CMD           — fallback command (optional for node runner)
#
# After sourcing, the caller checks USE_NODE_RUNNER and, if set, calls
# _node_runner_run to execute the node runner path.
#
# Exports (set by this file):
#   USE_NODE_RUNNER  — 1 if node runner is active, 0 otherwise
#   NODE_FILES       — array of discovered .test.js / .test.mjs file paths

# ── Node.js runner driver ─────────────────────────────────────────────────────
# Discovers *.test.js and *.test.mjs files under TEST_DIR and runs each file
# individually via `node --test <file>`. Each file becomes one test item.
#
# Auto-detect conditions (when RUNNER is empty):
#   - node is on PATH
#   - TEST_DIR is set and contains *.test.js or *.test.mjs files
#
# Falls back to generic when:
#   - node is not installed
#   - no .test.js / .test.mjs files are found under TEST_DIR

# _node_discover_files <dir>
# Prints one file path per line; returns non-zero if none found.
_node_discover_files() {
    local dir="$1"
    local found=0
    while IFS= read -r -d '' f; do
        echo "$f"
        found=1
    done < <(find "$dir" \( -name '*.test.js' -o -name '*.test.mjs' \) -print0 2>/dev/null | sort -z)
    [ "$found" -eq 1 ]
}

# Determine effective runner ──────────────────────────────────────────────────
USE_NODE_RUNNER=0

if [ "$RUNNER" = "node" ]; then
    # Explicit --runner=node: attempt node driver; fall back on failures
    if ! command -v node >/dev/null 2>&1; then
        echo "WARNING: --runner=node requested but node is not on PATH; falling back to generic runner." >&2
    elif [ -z "$TEST_DIR" ]; then
        # No test dir — can't discover files; fall through to generic
        echo "WARNING: --runner=node requested but --test-dir not set; falling back to generic runner." >&2
    else
        # Check if any .test.js / .test.mjs files exist
        NODE_FILES=()
        while IFS= read -r f; do
            NODE_FILES+=("$f")
        done < <(_node_discover_files "$TEST_DIR" 2>/dev/null || true)

        if [ "${#NODE_FILES[@]}" -eq 0 ]; then
            echo "WARNING: --runner=node: no .test.js or .test.mjs files found under $TEST_DIR; falling back to generic runner." >&2
        else
            USE_NODE_RUNNER=1
        fi
    fi
elif [ -z "$RUNNER" ] && [ -n "$TEST_DIR" ]; then
    # Auto-detect: activate node driver when node is on PATH + test files exist
    if command -v node >/dev/null 2>&1; then
        NODE_FILES=()
        while IFS= read -r f; do
            NODE_FILES+=("$f")
        done < <(_node_discover_files "$TEST_DIR" 2>/dev/null || true)

        if [ "${#NODE_FILES[@]}" -gt 0 ]; then
            USE_NODE_RUNNER=1
            RUNNER="node"
        fi
    fi
fi

# _node_runner_run
# Executes the node runner path. Called by test-batched.sh when USE_NODE_RUNNER=1.
# Uses all shared state variables from the caller.
_node_runner_run() {
    local TOTAL=${#NODE_FILES[@]}
    local START_TIME
    START_TIME=$(date +%s)
    _elapsed() { echo $(( $(date +%s) - START_TIME )); }
    local _node_tmpdir
    _node_tmpdir=$(mktemp -d /tmp/test-batched-node-XXXXXX)
    trap 'rm -rf "$_node_tmpdir"' EXIT

    _save_state_and_resume_node() {
        local completed_json results_json
        completed_json=$(_completed_to_json)
        results_json="$RESULTS_JSON"
        _state_write "$STATE_FILE" "node:${TEST_DIR}" "$completed_json" "$results_json" 2>/dev/null || {
            echo "WARNING: Could not write state file: $STATE_FILE" >&2
        }
        local done_count=${#COMPLETED_LIST[@]}
        local resume_runner_arg="--runner=node"
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

    for node_file in "${NODE_FILES[@]}"; do
        # Use the file path as the test ID (sanitized)
        local test_id="${node_file// /_}"
        test_id="${test_id//[^a-zA-Z0-9_\/.-]/}"
        test_id="${test_id:-node_test}"

        if _is_completed "$test_id"; then
            echo "Skipping (already completed): $test_id"
            continue
        fi

        # Check timeout before running this file
        if [ "$(_elapsed)" -ge "$TIMEOUT" ]; then
            _save_state_and_resume_node
        fi

        echo "Running: node --test $node_file"

        local _exit_code_file
        _exit_code_file=$(mktemp "$_node_tmpdir/test-batched-exit-XXXXXX")

        (
            node --test "$node_file"
            echo $? > "$_exit_code_file"
        ) &
        local NODE_PID=$!
        _ACTIVE_CHILD_PID=$NODE_PID

        while kill -0 "$NODE_PID" 2>/dev/null; do
            if [ "$(_elapsed)" -ge "$TIMEOUT" ]; then
                _ACTIVE_CHILD_PID=""
                kill -- -"$NODE_PID" 2>/dev/null || kill "$NODE_PID" 2>/dev/null || true
                wait "$NODE_PID" 2>/dev/null || true
                rm -f "$_exit_code_file"
                COMPLETED_LIST+=("$test_id")
                RESULTS_JSON=$(_results_add "$RESULTS_JSON" "$test_id" "interrupted")
                _save_state_and_resume_node
            fi
            sleep 0.1 2>/dev/null || sleep 1
        done

        _ACTIVE_CHILD_PID=""
        wait "$NODE_PID" 2>/dev/null; local node_exit=$?
        if [ -f "$_exit_code_file" ]; then
            node_exit=$(cat "$_exit_code_file" 2>/dev/null || echo "$node_exit")
        fi
        rm -f "$_exit_code_file"

        local node_outcome
        if [ "$node_exit" -eq 0 ]; then
            node_outcome="pass"
        else
            node_outcome="fail"
        fi

        COMPLETED_LIST+=("$test_id")
        RESULTS_JSON=$(_results_add "$RESULTS_JSON" "$test_id" "$node_outcome")

        local done_count=${#COMPLETED_LIST[@]}
        echo "$done_count/$TOTAL tests completed."
    done

    # All node files processed — print summary
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
