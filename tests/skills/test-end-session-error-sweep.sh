#!/usr/bin/env bash
# lockpick-workflow/tests/skills/test-end-session-error-sweep.sh
# Tests for lockpick-workflow/skills/end-session/error-sweep.sh sweep_tool_errors()
#
# Each test:
#   - Creates an isolated TEST_HOME=$(mktemp -d)
#   - Sets HOME=$TEST_HOME so counter file path resolves to TEST_HOME/.claude/tool-error-counter.json
#   - Mocks tk via a TEST_BIN directory prepended to PATH
#   - Cleans up via trap EXIT
#
# Usage: bash lockpick-workflow/tests/skills/test-end-session-error-sweep.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR" && git rev-parse --show-toplevel)"
ERROR_SWEEP="$REPO_ROOT/lockpick-workflow/skills/end-session/error-sweep.sh"

source "$REPO_ROOT/lockpick-workflow/tests/lib/assert.sh"

echo "=== test-end-session-error-sweep.sh ==="

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# _setup_test: creates isolated home + bin dir, sets HOME and PATH
# Sets globals: TEST_HOME TEST_BIN TK_LOG COUNTER_FILE
_setup_test() {
    TEST_HOME=$(mktemp -d)
    TEST_BIN="$TEST_HOME/bin"
    TK_LOG="$TEST_HOME/tk.log"
    mkdir -p "$TEST_BIN"
    mkdir -p "$TEST_HOME/.claude"
    COUNTER_FILE="$TEST_HOME/.claude/tool-error-counter.json"
    export HOME="$TEST_HOME"
    export PATH="$TEST_BIN:$PATH"
}

# _teardown_test: removes isolated home dir
_teardown_test() {
    if [[ -n "${TEST_HOME:-}" && -d "$TEST_HOME" ]]; then
        rm -rf "$TEST_HOME"
    fi
}

# _write_counter: writes counter JSON with given category->count mappings
# Usage: _write_counter category1 count1 [category2 count2 ...]
_write_counter() {
    local index_entries=""
    local sep=""
    while [[ $# -ge 2 ]]; do
        local cat="$1"
        local cnt="$2"
        shift 2
        index_entries="${index_entries}${sep}\"${cat}\": ${cnt}"
        sep=", "
    done
    cat > "$COUNTER_FILE" <<EOF
{"index": {${index_entries}}, "errors": []}
EOF
}

# _mock_tk_list_empty: tk list returns empty (no matching open bugs)
_mock_tk_list_empty() {
    cat > "$TEST_BIN/tk" <<'MOCK'
#!/usr/bin/env bash
if [[ "$1" == "list" ]]; then
    echo ""
    exit 0
fi
echo "" >> "$TK_LOG" 2>/dev/null
echo "$@" >> "$TK_LOG" 2>/dev/null
exit 0
MOCK
    # Inline TK_LOG reference must use env var — rewrite with actual path
    cat > "$TEST_BIN/tk" <<MOCK
#!/usr/bin/env bash
if [[ "\$1" == "list" ]]; then
    echo ""
    exit 0
fi
echo "\$@" >> "$TK_LOG"
exit 0
MOCK
    chmod +x "$TEST_BIN/tk"
}

# _mock_tk_list_with_match: tk list returns a line matching "Recurring tool error: $1"
_mock_tk_list_with_match() {
    local category="$1"
    cat > "$TEST_BIN/tk" <<MOCK
#!/usr/bin/env bash
if [[ "\$1" == "list" ]]; then
    echo "lockpick-doc-to-logic-xxxx  Recurring tool error: ${category} (50 occurrences)"
    exit 0
fi
echo "\$@" >> "$TK_LOG"
exit 0
MOCK
    chmod +x "$TEST_BIN/tk"
}

# _mock_tk_list_smart: first call returns empty, subsequent calls return match for $1
# Used to simulate idempotency — first sweep creates ticket, second sees existing
_mock_tk_list_smart() {
    local category="$1"
    local call_count_file="$TEST_HOME/list_calls"
    echo "0" > "$call_count_file"
    cat > "$TEST_BIN/tk" <<MOCK
#!/usr/bin/env bash
if [[ "\$1" == "list" ]]; then
    count=\$(cat "$call_count_file" 2>/dev/null || echo 0)
    echo \$((count + 1)) > "$call_count_file"
    if [[ "\$count" -eq 0 ]]; then
        echo ""
        exit 0
    else
        echo "lockpick-doc-to-logic-xxxx  Recurring tool error: ${category} (50 occurrences)"
        exit 0
    fi
fi
echo "\$@" >> "$TK_LOG"
exit 0
MOCK
    chmod +x "$TEST_BIN/tk"
}

# _count_tk_create_calls: count lines in TK_LOG that start with "create"
_count_tk_create_calls() {
    grep -c '^create ' "$TK_LOG" 2>/dev/null || echo "0"
}

# _run_sweep: source error-sweep.sh and call sweep_tool_errors in subshell
# Captures exit code in SWEEP_EXIT
_run_sweep() {
    (
        source "$ERROR_SWEEP"
        sweep_tool_errors
    )
    SWEEP_EXIT=$?
}

# ---------------------------------------------------------------------------
# test_threshold_49_no_ticket
# Counter permission_denied=49. Assert tk create not called.
# ---------------------------------------------------------------------------
_snapshot_fail
_setup_test
trap '_teardown_test' EXIT
_write_counter "permission_denied" 49
_mock_tk_list_empty
_run_sweep
create_calls=$(_count_tk_create_calls)
assert_eq "test_threshold_49_no_ticket" "0" "$create_calls"
assert_pass_if_clean "test_threshold_49_no_ticket"
trap - EXIT
_teardown_test

# ---------------------------------------------------------------------------
# test_threshold_50_creates_ticket
# Counter permission_denied=50, mock tk list returns empty. Assert tk create called.
# ---------------------------------------------------------------------------
_snapshot_fail
_setup_test
trap '_teardown_test' EXIT
_write_counter "permission_denied" 50
_mock_tk_list_empty
_run_sweep
create_calls=$(_count_tk_create_calls)
assert_eq "test_threshold_50_creates_ticket" "1" "$create_calls"
assert_pass_if_clean "test_threshold_50_creates_ticket"
trap - EXIT
_teardown_test

# ---------------------------------------------------------------------------
# test_dedup_existing_ticket_skips
# Counter=50, mock tk list returns matching ticket line. Assert tk create NOT called.
# ---------------------------------------------------------------------------
_snapshot_fail
_setup_test
trap '_teardown_test' EXIT
_write_counter "permission_denied" 50
_mock_tk_list_with_match "permission_denied"
_run_sweep
create_calls=$(_count_tk_create_calls)
assert_eq "test_dedup_existing_ticket_skips" "0" "$create_calls"
assert_pass_if_clean "test_dedup_existing_ticket_skips"
trap - EXIT
_teardown_test

# ---------------------------------------------------------------------------
# test_idempotent_double_sweep
# Counter=50, mock tk list empty first, returns ticket second. Sweep twice.
# Assert tk create called exactly once.
# ---------------------------------------------------------------------------
_snapshot_fail
_setup_test
trap '_teardown_test' EXIT
_write_counter "permission_denied" 50
_mock_tk_list_smart "permission_denied"
# First sweep: list is empty → creates ticket
(
    source "$ERROR_SWEEP"
    sweep_tool_errors
)
# Second sweep: list returns existing ticket → skips create
(
    source "$ERROR_SWEEP"
    sweep_tool_errors
)
create_calls=$(_count_tk_create_calls)
assert_eq "test_idempotent_double_sweep" "1" "$create_calls"
assert_pass_if_clean "test_idempotent_double_sweep"
trap - EXIT
_teardown_test

# ---------------------------------------------------------------------------
# test_multiple_categories_independent
# Counter permission_denied=50, timeout=30. Assert ticket created only for permission_denied.
# ---------------------------------------------------------------------------
_snapshot_fail
_setup_test
trap '_teardown_test' EXIT
_write_counter "permission_denied" 50 "timeout" 30
_mock_tk_list_empty
_run_sweep
create_calls=$(_count_tk_create_calls)
# Only permission_denied >= 50; timeout < 50 → only 1 create call
assert_eq "test_multiple_categories_independent" "1" "$create_calls"
# Verify the created ticket mentions permission_denied
if [[ -f "$TK_LOG" ]]; then
    created_title=$(grep '^create ' "$TK_LOG" 2>/dev/null | head -1 || true)
else
    created_title=""
fi
assert_contains "test_multiple_categories_independent_title" "permission_denied" "$created_title"
assert_pass_if_clean "test_multiple_categories_independent"
trap - EXIT
_teardown_test

# ---------------------------------------------------------------------------
# test_missing_counter_graceful
# No counter file. Assert sweep exits 0, no tk calls.
# ---------------------------------------------------------------------------
_snapshot_fail
_setup_test
trap '_teardown_test' EXIT
# Do NOT create counter file
_mock_tk_list_empty
_run_sweep
exit_ok="no"
if [[ "$SWEEP_EXIT" -eq 0 ]]; then exit_ok="yes"; fi
assert_eq "test_missing_counter_graceful_exit" "yes" "$exit_ok"
create_calls=$(_count_tk_create_calls)
assert_eq "test_missing_counter_graceful_no_tk" "0" "$create_calls"
assert_pass_if_clean "test_missing_counter_graceful"
trap - EXIT
_teardown_test

print_summary
