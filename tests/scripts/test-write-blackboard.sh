#!/usr/bin/env bash
# tests/scripts/test-write-blackboard.sh
# Tests for scripts/write-blackboard.sh — verifies blackboard writes to /tmp
# and that BLACKBOARD_DIR override works for test isolation.
#
# Tests:
#  1. test_writes_to_tmp_dir           — default path is /tmp/dso-blackboard-<worktree-name>/blackboard.json
#  2. test_blackboard_dir_override     — BLACKBOARD_DIR override redirects file location
#  3. test_clean_flag                  — --clean removes the file (idempotent)
#  4. test_invalid_json_exits_1        — malformed stdin exits 1
#  5. test_empty_stdin_exits_1         — empty stdin exits 1
#  6. test_missing_batch_key_exits_1   — JSON without 'batch' key exits 1
#  7. test_valid_batch_written         — output contains agents with task_id and files_owned
#
# Usage: bash tests/scripts/test-write-blackboard.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
REPO_ROOT="$(git rev-parse --show-toplevel)"
WRITE_BLACKBOARD="$PLUGIN_ROOT/scripts/write-blackboard.sh"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

_sample_batch_json() {
    cat <<'EOF'
{"batch":[{"id":"dso-test1","files":["src/foo.py","src/bar.py"]},{"id":"dso-test2","files":["src/baz.py"]}]}
EOF
}

# ---------------------------------------------------------------------------
# TEST 1: Default path is /tmp/dso-blackboard-<worktree-name>/blackboard.json
# ---------------------------------------------------------------------------

test_writes_to_tmp_dir() {
    local WORKTREE_NAME
    WORKTREE_NAME="$(basename "$REPO_ROOT")"
    local EXPECTED_DIR="${TMPDIR:-/tmp}/dso-blackboard-${WORKTREE_NAME}"
    local EXPECTED_FILE="$EXPECTED_DIR/blackboard.json"

    # Clean up before test
    rm -f "$EXPECTED_FILE"

    _sample_batch_json | bash "$WRITE_BLACKBOARD" 2>/dev/null

    if [[ -f "$EXPECTED_FILE" ]]; then
        (( ++PASS ))
    else
        (( ++FAIL ))
        printf "FAIL: test_writes_to_tmp_dir\n  Expected file: %s\n" "$EXPECTED_FILE" >&2
    fi

    # Cleanup
    rm -f "$EXPECTED_FILE"
}

test_writes_to_tmp_dir

# ---------------------------------------------------------------------------
# TEST 2: BLACKBOARD_DIR override redirects file location
# ---------------------------------------------------------------------------

test_blackboard_dir_override() {
    local TEST_DIR
    TEST_DIR="$(mktemp -d)"

    _sample_batch_json | BLACKBOARD_DIR="$TEST_DIR" bash "$WRITE_BLACKBOARD" 2>/dev/null

    if [[ -f "$TEST_DIR/blackboard.json" ]]; then
        (( ++PASS ))
    else
        (( ++FAIL ))
        printf "FAIL: test_blackboard_dir_override\n  Expected file: %s/blackboard.json\n" "$TEST_DIR" >&2
    fi

    rm -rf "$TEST_DIR"
}

test_blackboard_dir_override

# ---------------------------------------------------------------------------
# TEST 3: --clean removes the file (idempotent)
# ---------------------------------------------------------------------------

test_clean_flag() {
    local TEST_DIR
    TEST_DIR="$(mktemp -d)"
    local FILE="$TEST_DIR/blackboard.json"

    # Write first
    _sample_batch_json | BLACKBOARD_DIR="$TEST_DIR" bash "$WRITE_BLACKBOARD" 2>/dev/null

    if [[ ! -f "$FILE" ]]; then
        (( ++FAIL ))
        printf "FAIL: test_clean_flag (setup) — file not created\n" >&2
        rm -rf "$TEST_DIR"
        return
    fi

    # Clean
    BLACKBOARD_DIR="$TEST_DIR" bash "$WRITE_BLACKBOARD" --clean 2>/dev/null

    if [[ ! -f "$FILE" ]]; then
        (( ++PASS ))
    else
        (( ++FAIL ))
        printf "FAIL: test_clean_flag — file still exists after --clean\n" >&2
    fi

    # Idempotent second clean (no error)
    BLACKBOARD_DIR="$TEST_DIR" bash "$WRITE_BLACKBOARD" --clean 2>/dev/null
    (( ++PASS ))  # No crash = pass

    rm -rf "$TEST_DIR"
}

test_clean_flag

# ---------------------------------------------------------------------------
# TEST 4: Invalid JSON stdin exits 1
# ---------------------------------------------------------------------------

test_invalid_json_exits_1() {
    local TEST_DIR
    TEST_DIR="$(mktemp -d)"

    echo "not-json" | BLACKBOARD_DIR="$TEST_DIR" bash "$WRITE_BLACKBOARD" 2>/dev/null
    local EXIT_CODE=$?

    if [[ "$EXIT_CODE" -eq 1 ]]; then
        (( ++PASS ))
    else
        (( ++FAIL ))
        printf "FAIL: test_invalid_json_exits_1 — expected exit 1, got %s\n" "$EXIT_CODE" >&2
    fi

    rm -rf "$TEST_DIR"
}

test_invalid_json_exits_1

# ---------------------------------------------------------------------------
# TEST 5: Empty stdin exits 1
# ---------------------------------------------------------------------------

test_empty_stdin_exits_1() {
    local TEST_DIR
    TEST_DIR="$(mktemp -d)"

    echo "" | BLACKBOARD_DIR="$TEST_DIR" bash "$WRITE_BLACKBOARD" 2>/dev/null
    local EXIT_CODE=$?

    if [[ "$EXIT_CODE" -eq 1 ]]; then
        (( ++PASS ))
    else
        (( ++FAIL ))
        printf "FAIL: test_empty_stdin_exits_1 — expected exit 1, got %s\n" "$EXIT_CODE" >&2
    fi

    rm -rf "$TEST_DIR"
}

test_empty_stdin_exits_1

# ---------------------------------------------------------------------------
# TEST 6: JSON without 'batch' key exits 1
# ---------------------------------------------------------------------------

test_missing_batch_key_exits_1() {
    local TEST_DIR
    TEST_DIR="$(mktemp -d)"

    echo '{"tasks":[]}' | BLACKBOARD_DIR="$TEST_DIR" bash "$WRITE_BLACKBOARD" 2>/dev/null
    local EXIT_CODE=$?

    if [[ "$EXIT_CODE" -eq 1 ]]; then
        (( ++PASS ))
    else
        (( ++FAIL ))
        printf "FAIL: test_missing_batch_key_exits_1 — expected exit 1, got %s\n" "$EXIT_CODE" >&2
    fi

    rm -rf "$TEST_DIR"
}

test_missing_batch_key_exits_1

# ---------------------------------------------------------------------------
# TEST 7: Valid batch — output contains agents with task_id and files_owned
# ---------------------------------------------------------------------------

test_valid_batch_written() {
    local TEST_DIR
    TEST_DIR="$(mktemp -d)"

    _sample_batch_json | BLACKBOARD_DIR="$TEST_DIR" bash "$WRITE_BLACKBOARD" 2>/dev/null

    local FILE="$TEST_DIR/blackboard.json"

    if [[ ! -f "$FILE" ]]; then
        (( ++FAIL ))
        printf "FAIL: test_valid_batch_written — file not created\n" >&2
        rm -rf "$TEST_DIR"
        return
    fi

    local CONTENT
    CONTENT="$(cat "$FILE")"

    # Check version field
    if echo "$CONTENT" | python3 -c "import sys,json; d=json.load(sys.stdin); assert d['version']==1" 2>/dev/null; then
        (( ++PASS ))
    else
        (( ++FAIL ))
        printf "FAIL: test_valid_batch_written — version != 1\n" >&2
    fi

    # Check agents array with task_id and files_owned
    if echo "$CONTENT" | python3 -c "
import sys,json
d=json.load(sys.stdin)
agents=d['agents']
assert len(agents)==2
assert agents[0]['task_id']=='dso-test1'
assert 'src/foo.py' in agents[0]['files_owned']
assert agents[1]['task_id']=='dso-test2'
" 2>/dev/null; then
        (( ++PASS ))
    else
        (( ++FAIL ))
        printf "FAIL: test_valid_batch_written — agent content incorrect\n  Got: %s\n" "$CONTENT" >&2
    fi

    rm -rf "$TEST_DIR"
}

test_valid_batch_written

# ---------------------------------------------------------------------------

print_summary
