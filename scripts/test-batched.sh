#!/usr/bin/env bash
# lockpick-workflow/scripts/test-batched.sh — Time-bounded test batching harness
#
# Runs a test command in a time-bounded loop, saving progress to a state file.
# When the time limit is reached, prints a NEXT: resume command and exits.
# When all tests complete, prints a summary and cleans up the state file.
#
# Usage:
#   test-batched.sh [OPTIONS] [<command>]
#
# Options:
#   --help              Show this help and exit
#   --timeout=N         Stop after N seconds (default: 50)
#   --state-file=PATH   Path to JSON state file (default: /tmp/test-batched-state.json)
#   --runner=RUNNER     Test runner driver: node, pytest, or generic (default: auto-detect)
#   --test-dir=PATH     Directory to search for test files (used by runner drivers)
#
# Runner drivers:
#   node      Discovers *.test.js and *.test.mjs files under --test-dir and runs
#             each via: node --test <file>
#             Auto-detected when: node is on PATH AND *.test.js / *.test.mjs
#             files exist under --test-dir.
#             Falls back to generic when: node not installed, or no test files found.
#   pytest    Uses pytest --collect-only -q for upfront test enumeration, then
#             runs each collected test ID via: pytest <test_id>
#             Auto-detected when: pytest is on PATH AND test_*.py / *_test.py
#             files exist under --test-dir.
#             Falls back to generic when: pytest not installed, no test files found,
#             collection fails, or collection yields no test IDs.
#   generic   (default) Runs <command> as a single test item.
#
# The <command> positional argument is required for the generic runner.
# For the node runner, <command> is optional (used as fallback command).
#
# Output format:
#   Between batches: progress line + "NEXT: <resume command>"
#   On completion:   "N/M tests completed. N passed, N failed." + failure details
#
# State file schema (JSON):
#   {
#     "runner":    "<command string>",
#     "completed": ["<id1>", "<id2>", ...],
#     "results":   {"<id1>": "pass", "<id2>": "fail", ...}
#   }
#
# Environment:
#   TEST_BATCHED_STATE_FILE   Override default state file path (useful in tests)
#
# Examples:
#   test-batched.sh "make test-unit-only"
#   test-batched.sh --timeout=30 "bash run-tests.sh"
#   test-batched.sh --timeout=1 "sleep 10"   # stops early; prints NEXT:
#   test-batched.sh --runner=node --test-dir=./src
#   test-batched.sh --runner=node --test-dir=./tests --timeout=30
#   test-batched.sh --runner=pytest --test-dir=./tests
#   test-batched.sh --runner=pytest --test-dir=./tests --timeout=30

set -uo pipefail
set -m  # Enable job control so background jobs get their own process group

# ── Constants ─────────────────────────────────────────────────────────────────
DEFAULT_TIMEOUT=50
DEFAULT_STATE_FILE="${TEST_BATCHED_STATE_FILE:-/tmp/test-batched-state.json}"

# ── Argument parsing ──────────────────────────────────────────────────────────
TIMEOUT=$DEFAULT_TIMEOUT
STATE_FILE="$DEFAULT_STATE_FILE"
CMD=""
RUNNER=""
TEST_DIR=""

for arg in "$@"; do
    case "$arg" in
        --help)
            sed -n '2,/^$/s/^# \{0,1\}//p' "$0" | head -60
            exit 0
            ;;
        --timeout=*)
            TIMEOUT="${arg#--timeout=}"
            ;;
        --state-file=*)
            STATE_FILE="${arg#--state-file=}"
            ;;
        --runner=*)
            RUNNER="${arg#--runner=}"
            ;;
        --test-dir=*)
            TEST_DIR="${arg#--test-dir=}"
            ;;
        --*)
            echo "ERROR: Unknown option: $arg" >&2
            echo "Run with --help for usage." >&2
            exit 1
            ;;
        *)
            if [ -z "$CMD" ]; then
                CMD="$arg"
            else
                echo "ERROR: Unexpected argument: $arg" >&2
                echo "Run with --help for usage." >&2
                exit 1
            fi
            ;;
    esac
done

# ── Validate required argument ─────────────────────────────────────────────────
# CMD is required for generic runner; node and pytest runners can operate without it.
if [ -z "$CMD" ] && [ "$RUNNER" != "node" ] && [ "$RUNNER" != "pytest" ]; then
    echo "ERROR: Missing required argument: <command>" >&2
    echo ""
    sed -n '2,/^$/s/^# \{0,1\}//p' "$0" | head -60 >&2
    exit 1
fi

# ── Command validation: bash -c handles all valid shell expressions ────────────
# CMD is always executed via `bash -c "$CMD"`, which means any valid shell
# expression is accepted — including compound commands (e.g., "cmd1 && cmd2"),
# pipes (e.g., "cmd | grep foo"), shell builtins (e.g., "exit 0"), and
# environment-variable prefixes (e.g., "FOO=bar cmd"). Using `which` or
# `command -v` on the first word would be a fragile heuristic that breaks on
# all of the above. The non-empty check above is sufficient validation.

# ── State file helpers ─────────────────────────────────────────────────────────

# _state_read_field <file> <field>
# Reads a field from a JSON state file using python3.
# Returns empty string on error.
_state_read_field() {
    local file="$1" field="$2"
    python3 -c "
import json, sys
try:
    d = json.load(open(sys.argv[1]))
    val = d.get(sys.argv[2], '')
    if isinstance(val, list):
        print('\n'.join(str(v) for v in val))
    elif isinstance(val, dict):
        print(json.dumps(val))
    else:
        print(val)
except Exception:
    sys.exit(1)
" "$file" "$field" 2>/dev/null || true
}

# _state_write <file> <runner> <completed_json_array> <results_json_obj>
_state_write() {
    local file="$1" runner="$2" completed="$3" results="$4"
    python3 -c "
import json, sys
state = {
    'runner': sys.argv[1],
    'completed': json.loads(sys.argv[2]),
    'results': json.loads(sys.argv[3])
}
with open(sys.argv[4], 'w') as f:
    json.dump(state, f, indent=2)
" "$runner" "$completed" "$results" "$file" 2>/dev/null
}

# _state_is_valid <file>
# Returns 0 if file contains valid JSON with required keys, 1 otherwise.
_state_is_valid() {
    local file="$1"
    [ -f "$file" ] || return 1
    python3 -c "
import json, sys
try:
    d = json.load(open(sys.argv[1]))
    assert 'runner' in d
    assert 'completed' in d
    assert 'results' in d
    sys.exit(0)
except Exception:
    sys.exit(1)
" "$file" 2>/dev/null
}

# ── Load or initialize state ──────────────────────────────────────────────────
COMPLETED_LIST=()
RESULTS_JSON="{}"
RESUME_MODE=0

if [ -f "$STATE_FILE" ]; then
    if _state_is_valid "$STATE_FILE"; then
        # Resume: read completed tests
        RESUME_MODE=1
        _completed_raw=$(_state_read_field "$STATE_FILE" "completed") || true
        if [ -n "$_completed_raw" ]; then
            while IFS= read -r line; do
                [ -n "$line" ] && COMPLETED_LIST+=("$line")
            done <<< "$_completed_raw"
        fi
        RESULTS_JSON=$(_state_read_field "$STATE_FILE" "results") || RESULTS_JSON="{}"
        echo "Resuming from state file: $STATE_FILE"
        echo "Already completed: ${#COMPLETED_LIST[@]} tests"
    else
        # Corrupted — start fresh
        echo "WARNING: State file corrupted; starting fresh: $STATE_FILE" >&2
        rm -f "$STATE_FILE"
    fi
fi

# ── Helper: check if a test ID is in the completed list ──────────────────────
_is_completed() {
    local id="$1"
    for c in "${COMPLETED_LIST[@]+"${COMPLETED_LIST[@]}"}"; do
        [ "$c" = "$id" ] && return 0
    done
    return 1
}

# ── Helper: serialize completed list to JSON array ────────────────────────────
_completed_to_json() {
    python3 -c "
import json, sys
items = sys.argv[1:]
print(json.dumps(items))
" "${COMPLETED_LIST[@]+"${COMPLETED_LIST[@]}"}" 2>/dev/null || echo "[]"
}

# ── Helper: update results JSON with a new result ─────────────────────────────
_results_add() {
    local results_json="$1" id="$2" outcome="$3"
    python3 -c "
import json, sys
d = json.loads(sys.argv[1])
d[sys.argv[2]] = sys.argv[3]
print(json.dumps(d))
" "$results_json" "$id" "$outcome" 2>/dev/null || echo "$results_json"
}

# ── Helper: count pass/fail in results JSON ───────────────────────────────────
_results_count() {
    local results_json="$1" outcome="$2"
    python3 -c "
import json, sys
d = json.loads(sys.argv[1])
print(sum(1 for v in d.values() if v == sys.argv[2]))
" "$results_json" "$outcome" 2>/dev/null || echo "0"
}

# ── Helper: list failed test IDs from results JSON ────────────────────────────
_results_failures() {
    local results_json="$1"
    python3 -c "
import json, sys
d = json.loads(sys.argv[1])
for k, v in d.items():
    if v == 'fail':
        print(k)
" "$results_json" 2>/dev/null || true
}


# ── Node.js runner driver (sourced from runners/node-runner.sh) ───────────────
# Sets USE_NODE_RUNNER and NODE_FILES; provides _node_runner_run function.
# shellcheck source=runners/node-runner.sh
source "$(dirname "$0")/runners/node-runner.sh"

# ── Node runner execution path ────────────────────────────────────────────────
if [ "$USE_NODE_RUNNER" -eq 1 ]; then
    _node_runner_run
fi

# ── Pytest runner driver (sourced from runners/pytest-runner.sh) ──────────────
# Sets USE_PYTEST_RUNNER and PYTEST_TESTS; provides _pytest_runner_run function.
# Only sourced when RUNNER is "pytest" or auto-detect is in effect (RUNNER="").
# shellcheck source=runners/pytest-runner.sh
source "$(dirname "$0")/runners/pytest-runner.sh"

# ── Pytest runner execution path ──────────────────────────────────────────────
if [ "$USE_PYTEST_RUNNER" -eq 1 ]; then
    _pytest_runner_run
fi

# ── Generic fallback runner ───────────────────────────────────────────────────
# Runs CMD as a single test item with an auto-generated ID.
# This is the default mode — a generic harness for any command.

# Ensure CMD is non-empty for generic runner (defensive check)
if [ -z "$CMD" ]; then
    echo "ERROR: Missing required argument: <command> (runner fell back to generic but no command given)" >&2
    exit 1
fi

# Assign a unique test ID for this run
TEST_ID="${CMD// /_}"
TEST_ID="${TEST_ID//[^a-zA-Z0-9_-]/}"
TEST_ID="${TEST_ID:-test_run}"

# REVIEW-DEFENSE: TOTAL=1 is intentional for the generic fallback runner.
# The generic fallback runs CMD as a single unit because it cannot enumerate
# individual tests without a runner driver (pytest, node, etc.). The state file
# and resume machinery exist for the runner drivers added in Tasks 2 and 3,
# which will set TOTAL > 1. This is the simplest implementation that exercises
# the full code path.
TOTAL=1
COMPLETED_BEFORE=${#COMPLETED_LIST[@]}

# ── Time-bounded execution ─────────────────────────────────────────────────────
START_TIME=$(date +%s)

_elapsed() { echo $(( $(date +%s) - START_TIME )); }

_save_state_and_resume() {
    local completed_json results_json
    completed_json=$(_completed_to_json)
    results_json="$RESULTS_JSON"
    _state_write "$STATE_FILE" "$CMD" "$completed_json" "$results_json" 2>/dev/null || {
        echo "WARNING: Could not write state file: $STATE_FILE" >&2
    }
    local done_count=${#COMPLETED_LIST[@]}
    echo ""
    echo "$done_count/$TOTAL tests completed."
    echo "NEXT: TEST_BATCHED_STATE_FILE=$STATE_FILE bash $0 $([ "$TIMEOUT" -ne "$DEFAULT_TIMEOUT" ] && echo "--timeout=$TIMEOUT ") '$CMD'"
    exit 0
}

# ── Check if already completed ────────────────────────────────────────────────
if _is_completed "$TEST_ID"; then
    echo "Skipping (already completed): $TEST_ID"
    # All done — no more tests
    pass_count=$(_results_count "$RESULTS_JSON" "pass")
    fail_count=$(_results_count "$RESULTS_JSON" "fail")
    interrupted_count=$(_results_count "$RESULTS_JSON" "interrupted")
    total_done=${#COMPLETED_LIST[@]}
    echo ""
    echo "$total_done/$TOTAL tests completed. $pass_count passed, $fail_count failed, $interrupted_count interrupted."
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
fi

# ── Check timeout before running ─────────────────────────────────────────────
if [ "$(_elapsed)" -ge "$TIMEOUT" ]; then
    _save_state_and_resume
fi

# ── Run the test ──────────────────────────────────────────────────────────────
echo "Running: $CMD"
test_exit=0

# Use mktemp for the exit code file to avoid PID-based collisions
_exit_code_file=$(mktemp /tmp/test-batched-exit-XXXXXX.txt)
trap 'rm -f "$_exit_code_file"' EXIT

# Use a background job to enforce timeout during execution
(
    # Run CMD in a subshell so shell builtins (like exit N) work correctly
    bash -c "$CMD"
    echo $? > "$_exit_code_file"
) &
CMD_PID=$!

# Wait for completion or timeout
while kill -0 "$CMD_PID" 2>/dev/null; do
    if [ "$(_elapsed)" -ge "$TIMEOUT" ]; then
        # Kill the entire process group (negative PID) so child processes
        # spawned by bash -c don't survive as orphans.
        kill -- -"$CMD_PID" 2>/dev/null || kill "$CMD_PID" 2>/dev/null || true
        wait "$CMD_PID" 2>/dev/null || true
        rm -f "$_exit_code_file"
        COMPLETED_LIST+=("$TEST_ID")
        RESULTS_JSON=$(_results_add "$RESULTS_JSON" "$TEST_ID" "interrupted")
        _save_state_and_resume
    fi
    sleep 0.1 2>/dev/null || sleep 1
done

wait "$CMD_PID" 2>/dev/null; test_exit=$?
# Read real exit code if written
if [ -f "$_exit_code_file" ]; then
    test_exit=$(cat "$_exit_code_file" 2>/dev/null || echo "$test_exit")
fi
rm -f "$_exit_code_file"

# ── Record result ─────────────────────────────────────────────────────────────
if [ "$test_exit" -eq 0 ]; then
    outcome="pass"
else
    outcome="fail"
fi

COMPLETED_LIST+=("$TEST_ID")
RESULTS_JSON=$(_results_add "$RESULTS_JSON" "$TEST_ID" "$outcome")

done_count=${#COMPLETED_LIST[@]}
echo "$done_count/$TOTAL tests completed."

# ── Final summary ──────────────────────────────────────────────────────────────
pass_count=$(_results_count "$RESULTS_JSON" "pass")
fail_count=$(_results_count "$RESULTS_JSON" "fail")
total_done=${#COMPLETED_LIST[@]}

echo ""
echo "All tests done. $total_done/$TOTAL tests completed. $pass_count passed, $fail_count failed."

if [ "$fail_count" -gt 0 ]; then
    echo ""
    echo "Failures:"
    _results_failures "$RESULTS_JSON" | while IFS= read -r fid; do
        echo "  FAIL: $fid"
    done
fi

# Clean up state file
rm -f "$STATE_FILE"

[ "$fail_count" -gt 0 ] && exit 1 || exit 0
