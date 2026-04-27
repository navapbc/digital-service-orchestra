#!/usr/bin/env bash
# shellcheck disable=SC2030,SC2031,SC2154  # TICKET_CMD intentionally subshell-local per test; _fail_snapshot set by assert.sh _snapshot_fail
# tests/skills/test-end-session-error-sweep.sh
# Tests for scripts/end-session/error-sweep.sh sweep_tool_errors()
#
# Each test:
#   - Creates an isolated TEST_HOME=$(mktemp -d)
#   - Sets HOME=$TEST_HOME so counter file path resolves to TEST_HOME/.claude/tool-error-counter.json
#   - Mocks ticket CLI via TICKET_CMD pointing to a mock script in TEST_BIN
#   - Cleans up via trap EXIT
#
# Usage: bash tests/skills/test-end-session-error-sweep.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DSO_PLUGIN_DIR="$PLUGIN_ROOT/plugins/dso"
REPO_ROOT="$(cd "$SCRIPT_DIR" && git rev-parse --show-toplevel)"
ERROR_SWEEP="$DSO_PLUGIN_DIR/scripts/end-session/error-sweep.sh"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

echo "=== test-end-session-error-sweep.sh ==="

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# _setup_test: creates isolated home + bin dir, sets HOME
# Sets globals: TEST_HOME TEST_BIN TK_LOG COUNTER_FILE
_setup_test() {
    TEST_HOME=$(mktemp -d)
    TEST_BIN="$TEST_HOME/bin"
    TK_LOG="$TEST_HOME/tk.log"
    mkdir -p "$TEST_BIN"
    mkdir -p "$TEST_HOME/.claude"
    COUNTER_FILE="$TEST_HOME/.claude/tool-error-counter.json"
    export HOME="$TEST_HOME"
}

# _teardown_test: removes isolated home dir
_teardown_test() {
    if [[ -n "${TEST_HOME:-}" && -d "$TEST_HOME" ]]; then
        rm -rf "$TEST_HOME"
    fi
}

# _write_counter: writes counter JSON with given category->count mappings and optional errors
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

# _write_counter_with_errors: writes counter JSON with index AND error detail entries
# Usage: _write_counter_with_errors '<full json>'
_write_counter_with_errors() {
    echo "$1" > "$COUNTER_FILE"
}

# _mock_ticket_list_empty: ticket list returns empty JSON array (no matching open bugs)
_mock_ticket_list_empty() {
    cat > "$TEST_BIN/ticket" <<MOCK
#!/usr/bin/env bash
if [[ "\$1" == "list" ]]; then
    echo "[]"
    exit 0
fi
echo "\$@" >> "$TK_LOG"
if [[ "\$1" == "create" ]]; then
    echo "mock-1234"
fi
exit 0
MOCK
    chmod +x "$TEST_BIN/ticket"
    export TICKET_CMD="$TEST_BIN/ticket"
}

# _mock_ticket_list_with_match: ticket list returns JSON with a matching bug ticket for category $1
_mock_ticket_list_with_match() {
    local category="$1"
    cat > "$TEST_BIN/ticket" <<MOCK
#!/usr/bin/env bash
if [[ "\$1" == "list" ]]; then
    echo '[{"ticket_id":"lockpick-doc-to-logic-xxxx","ticket_type":"bug","status":"open","title":"Recurring tool error: ${category} (50 occurrences)"}]'
    exit 0
fi
echo "\$@" >> "$TK_LOG"
if [[ "\$1" == "create" ]]; then
    echo "mock-1234"
fi
exit 0
MOCK
    chmod +x "$TEST_BIN/ticket"
    export TICKET_CMD="$TEST_BIN/ticket"
}

# _mock_ticket_list_smart: first call returns empty JSON, subsequent calls return match for $1
# Used to simulate idempotency — first sweep creates ticket, second sees existing
_mock_ticket_list_smart() {
    local category="$1"
    local call_count_file="$TEST_HOME/list_calls"
    echo "0" > "$call_count_file"
    cat > "$TEST_BIN/ticket" <<MOCK
#!/usr/bin/env bash
if [[ "\$1" == "list" ]]; then
    count=\$(cat "$call_count_file" 2>/dev/null || echo 0)
    echo \$((count + 1)) > "$call_count_file"
    if [[ "\$count" -eq 0 ]]; then
        echo "[]"
        exit 0
    else
        echo '[{"ticket_id":"lockpick-doc-to-logic-xxxx","ticket_type":"bug","status":"open","title":"Recurring tool error: ${category} (50 occurrences)"}]'
        exit 0
    fi
fi
echo "\$@" >> "$TK_LOG"
if [[ "\$1" == "create" ]]; then
    echo "mock-1234"
fi
exit 0
MOCK
    chmod +x "$TEST_BIN/ticket"
    export TICKET_CMD="$TEST_BIN/ticket"
}

# _count_tk_create_calls: count lines in TK_LOG that start with "create"
_count_tk_create_calls() {
    grep -c '^create ' "$TK_LOG" 2>/dev/null || echo "0"
}

# _get_tk_create_args: get the full create command args from the log
_get_tk_create_args() {
    grep '^create ' "$TK_LOG" 2>/dev/null | head -1 || true
}

# _run_sweep: source error-sweep.sh and call sweep_tool_errors in subshell
# Passes TICKET_CMD pointing to mock in TEST_BIN. Captures exit code in SWEEP_EXIT
_run_sweep() {
    (
        TICKET_CMD="$TEST_BIN/ticket"
        source "$ERROR_SWEEP"
        sweep_tool_errors
    )
    SWEEP_EXIT=$?
}

# _get_counter_index_count: read a category count from the counter file
# Usage: _get_counter_index_count category
_get_counter_index_count() {
    local category="$1"
    python3 -c "
import json, sys
with open('$COUNTER_FILE') as f:
    data = json.load(f)
print(data.get('index', {}).get('$category', 0))
" 2>/dev/null || echo "error"
}

# _get_counter_error_count: count error entries for a category
_get_counter_error_count() {
    local category="$1"
    python3 -c "
import json, sys
with open('$COUNTER_FILE') as f:
    data = json.load(f)
print(len([e for e in data.get('errors', []) if e.get('category') == '$category']))
" 2>/dev/null || echo "error"
}

# ---------------------------------------------------------------------------
# test_threshold_49_no_ticket
# Counter permission_denied=49. Assert ticket create not called.
# ---------------------------------------------------------------------------
_snapshot_fail
_setup_test
trap '_teardown_test' EXIT
_write_counter "permission_denied" 49
_mock_ticket_list_empty
_run_sweep
create_calls=$(_count_tk_create_calls)
assert_eq "test_threshold_49_no_ticket" "0" "$create_calls"
assert_pass_if_clean "test_threshold_49_no_ticket"
trap - EXIT
_teardown_test

# ---------------------------------------------------------------------------
# test_threshold_50_creates_ticket
# Counter permission_denied=50, mock ticket list returns empty. Assert ticket create called.
# ---------------------------------------------------------------------------
_snapshot_fail
_setup_test
trap '_teardown_test' EXIT
_write_counter "permission_denied" 50
_mock_ticket_list_empty
_run_sweep
create_calls=$(_count_tk_create_calls)
assert_eq "test_threshold_50_creates_ticket" "1" "$create_calls"
assert_pass_if_clean "test_threshold_50_creates_ticket"
trap - EXIT
_teardown_test

# ---------------------------------------------------------------------------
# test_dedup_existing_ticket_skips
# Counter=50, mock ticket list returns matching ticket line. Assert ticket create NOT called.
# ---------------------------------------------------------------------------
_snapshot_fail
_setup_test
trap '_teardown_test' EXIT
_write_counter "permission_denied" 50
_mock_ticket_list_with_match "permission_denied"
_run_sweep
create_calls=$(_count_tk_create_calls)
assert_eq "test_dedup_existing_ticket_skips" "0" "$create_calls"
assert_pass_if_clean "test_dedup_existing_ticket_skips"
trap - EXIT
_teardown_test

# ---------------------------------------------------------------------------
# test_idempotent_double_sweep
# Counter=50, mock ticket list empty first, returns ticket second. Sweep twice.
# Assert ticket create called exactly once.
# ---------------------------------------------------------------------------
_snapshot_fail
_setup_test
trap '_teardown_test' EXIT
_write_counter "permission_denied" 50
_mock_ticket_list_smart "permission_denied"
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
_mock_ticket_list_empty
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
# No counter file. Assert sweep exits 0, no ticket calls.
# ---------------------------------------------------------------------------
_snapshot_fail
_setup_test
trap '_teardown_test' EXIT
# Do NOT create counter file
_mock_ticket_list_empty
_run_sweep
exit_ok="no"
if [[ "$SWEEP_EXIT" -eq 0 ]]; then exit_ok="yes"; fi
assert_eq "test_missing_counter_graceful_exit" "yes" "$exit_ok"
create_calls=$(_count_tk_create_calls)
assert_eq "test_missing_counter_graceful_no_tk" "0" "$create_calls"
assert_pass_if_clean "test_missing_counter_graceful"
trap - EXIT
_teardown_test

# ---------------------------------------------------------------------------
# test_noise_category_file_not_found_skipped
# Counter file_not_found=100 (noise). Assert ticket create NOT called.
# ---------------------------------------------------------------------------
_snapshot_fail
_setup_test
trap '_teardown_test' EXIT
_write_counter "file_not_found" 100
_mock_ticket_list_empty
_run_sweep
create_calls=$(_count_tk_create_calls)
assert_eq "test_noise_category_file_not_found_skipped" "0" "$create_calls"
assert_pass_if_clean "test_noise_category_file_not_found_skipped"
trap - EXIT
_teardown_test

# ---------------------------------------------------------------------------
# test_noise_category_command_exit_nonzero_skipped
# Counter command_exit_nonzero=200 (noise). Assert ticket create NOT called.
# ---------------------------------------------------------------------------
_snapshot_fail
_setup_test
trap '_teardown_test' EXIT
_write_counter "command_exit_nonzero" 200
_mock_ticket_list_empty
_run_sweep
create_calls=$(_count_tk_create_calls)
assert_eq "test_noise_category_command_exit_nonzero_skipped" "0" "$create_calls"
assert_pass_if_clean "test_noise_category_command_exit_nonzero_skipped"
trap - EXIT
_teardown_test

# ---------------------------------------------------------------------------
# test_noise_mixed_with_real_category
# Counter file_not_found=100 (noise) + permission_denied=50 (real).
# Assert only 1 ticket created (for permission_denied, not file_not_found).
# ---------------------------------------------------------------------------
_snapshot_fail
_setup_test
trap '_teardown_test' EXIT
_write_counter "file_not_found" 100 "command_exit_nonzero" 75 "permission_denied" 50
_mock_ticket_list_empty
_run_sweep
create_calls=$(_count_tk_create_calls)
assert_eq "test_noise_mixed_with_real_category_count" "1" "$create_calls"
if [[ -f "$TK_LOG" ]]; then
    created_title=$(grep '^create ' "$TK_LOG" 2>/dev/null | head -1 || true)
else
    created_title=""
fi
assert_contains "test_noise_mixed_with_real_category_title" "permission_denied" "$created_title"
assert_pass_if_clean "test_noise_mixed_with_real_category"
trap - EXIT
_teardown_test

# ---------------------------------------------------------------------------
# test_ticket_includes_description
# Counter with error details. Assert ticket create called and comment includes details.
# ---------------------------------------------------------------------------
_snapshot_fail
_setup_test
trap '_teardown_test' EXIT
_write_counter_with_errors '{"index":{"permission_denied":50},"errors":[{"category":"permission_denied","timestamp":"2026-03-15T10:00:00Z","tool_name":"Bash","input_summary":"Bash: rm /protected","error_message":"permission denied","session_id":"s1"}]}'
_mock_ticket_list_empty
_run_sweep
create_calls=$(_count_tk_create_calls)
assert_eq "test_ticket_includes_description_created" "1" "$create_calls"
# v3: description is passed via 'ticket comment' (not -d on create); check log for comment call
tk_log_content=$(cat "$TK_LOG" 2>/dev/null || true)
assert_contains "test_ticket_includes_description_has_d_flag" "comment" "$tk_log_content"
# Description is multi-line — check full tk.log for table content
assert_contains "test_ticket_includes_description_has_table" "permission denied" "$tk_log_content"
assert_pass_if_clean "test_ticket_includes_description"
trap - EXIT
_teardown_test

# ---------------------------------------------------------------------------
# test_counter_cleaned_after_ticket_creation
# Counter with errors. After sweep, category should be removed from counter.
# ---------------------------------------------------------------------------
_snapshot_fail
_setup_test
trap '_teardown_test' EXIT
_write_counter_with_errors '{"index":{"permission_denied":50,"timeout":10},"errors":[{"category":"permission_denied","timestamp":"2026-03-15T10:00:00Z","tool_name":"Bash","input_summary":"Bash: cmd","error_message":"permission denied","session_id":"s1"},{"category":"timeout","timestamp":"2026-03-15T10:01:00Z","tool_name":"Bash","input_summary":"Bash: slow","error_message":"timed out","session_id":"s2"}]}'
_mock_ticket_list_empty
_run_sweep
# permission_denied (>=50) should be removed from counter
pd_count=$(_get_counter_index_count "permission_denied")
assert_eq "test_counter_cleaned_pd_index" "0" "$pd_count"
pd_errors=$(_get_counter_error_count "permission_denied")
assert_eq "test_counter_cleaned_pd_errors" "0" "$pd_errors"
# timeout (<50) should still be in counter
to_count=$(_get_counter_index_count "timeout")
assert_eq "test_counter_cleaned_timeout_preserved" "10" "$to_count"
to_errors=$(_get_counter_error_count "timeout")
assert_eq "test_counter_cleaned_timeout_errors_preserved" "1" "$to_errors"
assert_pass_if_clean "test_counter_cleaned_after_ticket_creation"
trap - EXIT
_teardown_test

# ---------------------------------------------------------------------------
# test_noise_category_drained_from_counter
# Noise categories should be removed from counter even though no ticket is created.
# ---------------------------------------------------------------------------
_snapshot_fail
_setup_test
trap '_teardown_test' EXIT
_write_counter_with_errors '{"index":{"file_not_found":100,"command_exit_nonzero":200},"errors":[{"category":"file_not_found","timestamp":"2026-03-15T10:00:00Z","tool_name":"Read","input_summary":"Read: missing.py","error_message":"file not found","session_id":"s1"},{"category":"command_exit_nonzero","timestamp":"2026-03-15T10:01:00Z","tool_name":"Bash","input_summary":"Bash: false","error_message":"exit code 1","session_id":"s2"}]}'
_mock_ticket_list_empty
_run_sweep
create_calls=$(_count_tk_create_calls)
assert_eq "test_noise_drained_no_ticket" "0" "$create_calls"
fnf_count=$(_get_counter_index_count "file_not_found")
assert_eq "test_noise_drained_fnf_index" "0" "$fnf_count"
cen_count=$(_get_counter_index_count "command_exit_nonzero")
assert_eq "test_noise_drained_cen_index" "0" "$cen_count"
assert_pass_if_clean "test_noise_category_drained_from_counter"
trap - EXIT
_teardown_test

# ---------------------------------------------------------------------------
# test_dedup_still_drains_counter
# When a matching ticket already exists, entries should still be drained.
# ---------------------------------------------------------------------------
_snapshot_fail
_setup_test
trap '_teardown_test' EXIT
_write_counter_with_errors '{"index":{"permission_denied":60},"errors":[{"category":"permission_denied","timestamp":"2026-03-15T10:00:00Z","tool_name":"Bash","input_summary":"Bash: cmd","error_message":"permission denied","session_id":"s1"}]}'
_mock_ticket_list_with_match "permission_denied"
_run_sweep
create_calls=$(_count_tk_create_calls)
assert_eq "test_dedup_drains_no_ticket" "0" "$create_calls"
pd_count=$(_get_counter_index_count "permission_denied")
assert_eq "test_dedup_drains_counter_cleaned" "0" "$pd_count"
assert_pass_if_clean "test_dedup_still_drains_counter"
trap - EXIT
_teardown_test

# ---------------------------------------------------------------------------
# Helpers for sweep_validation_failures tests
# ---------------------------------------------------------------------------

# _mock_ticket_list_with_validation_match: ticket list returns JSON matching "Untracked validation failure: $1"
_mock_ticket_list_with_validation_match() {
    local category="$1"
    cat > "$TEST_BIN/ticket" <<MOCK
#!/usr/bin/env bash
if [[ "\$1" == "list" ]]; then
    echo '[{"ticket_id":"lockpick-doc-to-logic-xxxx","ticket_type":"bug","status":"open","title":"Untracked validation failure: ${category}"}]'
    exit 0
fi
echo "\$@" >> "$TK_LOG"
if [[ "\$1" == "create" ]]; then
    echo "mock-1234"
fi
exit 0
MOCK
    chmod +x "$TEST_BIN/ticket"
    export TICKET_CMD="$TEST_BIN/ticket"
}

# _run_sweep_validation: source error-sweep.sh and call sweep_validation_failures in subshell
# Requires ARTIFACTS_DIR to be set in the test environment.
# Passes TICKET_CMD pointing to mock in TEST_BIN. Captures exit code in SWEEP_EXIT
_run_sweep_validation() {
    (
        TICKET_CMD="$TEST_BIN/ticket"
        source "$ERROR_SWEEP"
        sweep_validation_failures
    )
    SWEEP_EXIT=$?
}

# ---------------------------------------------------------------------------
# test_validation_sweep_creates_ticket_from_log
# ARTIFACTS_DIR set, log contains one category. Assert ticket create called once.
# ---------------------------------------------------------------------------
_snapshot_fail
_setup_test
trap '_teardown_test' EXIT
export ARTIFACTS_DIR="$TEST_HOME/artifacts"
mkdir -p "$ARTIFACTS_DIR"
echo "lint_failure" > "$ARTIFACTS_DIR/untracked-validation-failures.log"
_mock_ticket_list_empty
_run_sweep_validation
create_calls=$(_count_tk_create_calls)
assert_eq "test_validation_sweep_creates_ticket_from_log_count" "1" "$create_calls"
if [[ "$FAIL" -eq "$_fail_snapshot" ]]; then
    echo "PASS: test_validation_sweep_creates_ticket_from_log"
fi
assert_pass_if_clean "test_validation_sweep_creates_ticket_from_log"
trap - EXIT
_teardown_test

# ---------------------------------------------------------------------------
# test_validation_sweep_dedup_skips_existing
# Log has category, matching open ticket exists. Assert tk create NOT called.
# ---------------------------------------------------------------------------
_snapshot_fail
_setup_test
trap '_teardown_test' EXIT
export ARTIFACTS_DIR="$TEST_HOME/artifacts"
mkdir -p "$ARTIFACTS_DIR"
echo "lint_failure" > "$ARTIFACTS_DIR/untracked-validation-failures.log"
_mock_ticket_list_with_validation_match "lint_failure"
_run_sweep_validation
create_calls=$(_count_tk_create_calls)
assert_eq "test_validation_sweep_dedup_skips_existing" "0" "$create_calls"
assert_pass_if_clean "test_validation_sweep_dedup_skips_existing"
trap - EXIT
_teardown_test

# ---------------------------------------------------------------------------
# test_validation_sweep_missing_log_graceful
# ARTIFACTS_DIR set but log file absent. Assert exits 0, no ticket calls.
# ---------------------------------------------------------------------------
_snapshot_fail
_setup_test
trap '_teardown_test' EXIT
export ARTIFACTS_DIR="$TEST_HOME/artifacts"
mkdir -p "$ARTIFACTS_DIR"
# Do NOT create untracked-validation-failures.log
_mock_ticket_list_empty
_run_sweep_validation
exit_ok="no"
if [[ "$SWEEP_EXIT" -eq 0 ]]; then exit_ok="yes"; fi
assert_eq "test_validation_sweep_missing_log_graceful_exit" "yes" "$exit_ok"
create_calls=$(_count_tk_create_calls)
assert_eq "test_validation_sweep_missing_log_graceful_no_tk" "0" "$create_calls"
assert_pass_if_clean "test_validation_sweep_missing_log_graceful"
trap - EXIT
_teardown_test

# ---------------------------------------------------------------------------
# test_validation_sweep_empty_log_graceful
# Log exists but is empty. Assert exits 0, no ticket calls.
# ---------------------------------------------------------------------------
_snapshot_fail
_setup_test
trap '_teardown_test' EXIT
export ARTIFACTS_DIR="$TEST_HOME/artifacts"
mkdir -p "$ARTIFACTS_DIR"
: > "$ARTIFACTS_DIR/untracked-validation-failures.log"
_mock_ticket_list_empty
_run_sweep_validation
exit_ok="no"
if [[ "$SWEEP_EXIT" -eq 0 ]]; then exit_ok="yes"; fi
assert_eq "test_validation_sweep_empty_log_graceful_exit" "yes" "$exit_ok"
create_calls=$(_count_tk_create_calls)
assert_eq "test_validation_sweep_empty_log_graceful_no_tk" "0" "$create_calls"
assert_pass_if_clean "test_validation_sweep_empty_log_graceful"
trap - EXIT
_teardown_test

# ---------------------------------------------------------------------------
# test_validation_sweep_duplicate_log_entries_creates_one_ticket
# Log has the same category repeated multiple times. Assert only 1 ticket created.
# ---------------------------------------------------------------------------
_snapshot_fail
_setup_test
trap '_teardown_test' EXIT
export ARTIFACTS_DIR="$TEST_HOME/artifacts"
mkdir -p "$ARTIFACTS_DIR"
printf "lint_failure\nlint_failure\nlint_failure\n" > "$ARTIFACTS_DIR/untracked-validation-failures.log"
_mock_ticket_list_empty
_run_sweep_validation
create_calls=$(_count_tk_create_calls)
assert_eq "test_validation_sweep_duplicate_log_entries_creates_one_ticket" "1" "$create_calls"
assert_pass_if_clean "test_validation_sweep_duplicate_log_entries_creates_one_ticket"
trap - EXIT
_teardown_test

# ---------------------------------------------------------------------------
# test_validation_sweep_unrecognized_category
# Log has an unrecognized/arbitrary category name. Assert ticket still created.
# ---------------------------------------------------------------------------
_snapshot_fail
_setup_test
trap '_teardown_test' EXIT
export ARTIFACTS_DIR="$TEST_HOME/artifacts"
mkdir -p "$ARTIFACTS_DIR"
echo "some_unknown_failure_xyz" > "$ARTIFACTS_DIR/untracked-validation-failures.log"
_mock_ticket_list_empty
_run_sweep_validation
create_calls=$(_count_tk_create_calls)
assert_eq "test_validation_sweep_unrecognized_category" "1" "$create_calls"
assert_pass_if_clean "test_validation_sweep_unrecognized_category"
trap - EXIT
_teardown_test

# ---------------------------------------------------------------------------
# test_skill_sweep_before_commit
# Both sweep function invocations (sweep_tool_errors, sweep_validation_failures)
# must appear in SKILL.md before the Commit Local Changes step. This is a
# structural ordering gate — if the sweep is moved post-commit, any tickets
# created by it would not be captured in the same merge.
# ---------------------------------------------------------------------------
_snapshot_fail
SKILL_MD="$DSO_PLUGIN_DIR/skills/end-session/SKILL.md"
# The sweep section must appear before the Commit Local Changes step.
sweep_pre_commit=$(awk '/Sweep Error Counters/,/^### .* Commit Local Changes/' "$SKILL_MD" 2>/dev/null || true)
if grep -q 'sweep_tool_errors' <<< "$sweep_pre_commit"; then
    has_tool_errors="found"
else
    has_tool_errors="missing"
fi
assert_eq "test_skill_sweep_before_commit_tool_errors" "found" "$has_tool_errors"
if grep -q 'sweep_validation_failures' <<< "$sweep_pre_commit"; then
    has_validation_failures="found"
else
    has_validation_failures="missing"
fi
assert_eq "test_skill_sweep_before_commit_validation_failures" "found" "$has_validation_failures"
assert_pass_if_clean "test_skill_sweep_before_commit"

# ---------------------------------------------------------------------------
# test_validation_sweep_ticket_create_failure_graceful
# ticket create exits non-zero. Assert sweep_validation_failures still exits 0.
# ---------------------------------------------------------------------------
_snapshot_fail
_setup_test
trap '_teardown_test' EXIT
export ARTIFACTS_DIR="$TEST_HOME/artifacts"
mkdir -p "$ARTIFACTS_DIR"
echo "some-validation-failure" > "$ARTIFACTS_DIR/untracked-validation-failures.log"
# Mock ticket CLI: list returns empty, create exits non-zero
cat > "$TEST_BIN/ticket" <<'MOCK'
#!/usr/bin/env bash
if [[ "${1:-}" == "list" ]]; then echo "[]"; exit 0; fi
exit 1
MOCK
chmod +x "$TEST_BIN/ticket"
export TICKET_CMD="$TEST_BIN/ticket"
(
    TICKET_CMD="$TEST_BIN/ticket"
    source "$ERROR_SWEEP"
    sweep_validation_failures
)
SWEEP_EXIT=$?
exit_ok="no"
if [[ "$SWEEP_EXIT" -eq 0 ]]; then exit_ok="yes"; fi
assert_eq "test_validation_sweep_ticket_create_failure_graceful" "yes" "$exit_ok"
assert_pass_if_clean "test_validation_sweep_ticket_create_failure_graceful"
trap - EXIT
_teardown_test

# ---------------------------------------------------------------------------
# test_ticket_deduplicates_error_details
# Counter with 50 errors, mostly duplicates. Assert ticket description contains
# deduplicated entries (unique by tool_name + error_message), not raw duplicates.
# ---------------------------------------------------------------------------
_snapshot_fail
_setup_test
trap '_teardown_test' EXIT
# Build counter with 50 permission_denied errors: 45 identical + 3 different + 2 more identical
_DEDUP_ERRORS='[]'
_DEDUP_ERRORS=$(python3 -c "
import json
errors = []
# 45 identical errors
for i in range(45):
    errors.append({'category':'permission_denied','timestamp':f'2026-03-15T10:{i:02d}:00Z','tool_name':'Bash','input_summary':'Bash: rm /protected/file.txt','error_message':'permission denied: /protected/file.txt','session_id':f's{i}'})
# 3 different errors
errors.append({'category':'permission_denied','timestamp':'2026-03-15T11:00:00Z','tool_name':'Read','input_summary':'Read: /etc/shadow','error_message':'permission denied: /etc/shadow','session_id':'s45'})
errors.append({'category':'permission_denied','timestamp':'2026-03-15T11:01:00Z','tool_name':'Bash','input_summary':'Bash: chmod 777 /root','error_message':'permission denied: /root','session_id':'s46'})
errors.append({'category':'permission_denied','timestamp':'2026-03-15T11:02:00Z','tool_name':'Write','input_summary':'Write: /usr/bin/test','error_message':'permission denied: /usr/bin/test','session_id':'s47'})
# 2 more duplicates of the first pattern
for i in range(2):
    errors.append({'category':'permission_denied','timestamp':f'2026-03-15T12:{i:02d}:00Z','tool_name':'Bash','input_summary':'Bash: rm /protected/file.txt','error_message':'permission denied: /protected/file.txt','session_id':f's{48+i}'})
print(json.dumps({'index':{'permission_denied':50},'errors':errors}))
")
_write_counter_with_errors "$_DEDUP_ERRORS"
_mock_ticket_list_empty
_run_sweep
# Ticket should be created
create_calls=$(_count_tk_create_calls)
assert_eq "test_ticket_deduplicates_created" "1" "$create_calls"
# Get the full ticket log to check description content
tk_log_content=$(cat "$TK_LOG" 2>/dev/null || true)
# Should contain all 4 unique error signatures (not 20 raw duplicates)
assert_contains "test_ticket_dedup_has_protected_file" "/protected/file.txt" "$tk_log_content"
assert_contains "test_ticket_dedup_has_etc_shadow" "/etc/shadow" "$tk_log_content"
assert_contains "test_ticket_dedup_has_root" "/root" "$tk_log_content"
assert_contains "test_ticket_dedup_has_usr_bin" "/usr/bin/test" "$tk_log_content"
# Should show occurrence counts — the 47 identical errors should show count
assert_contains "test_ticket_dedup_has_occurrence_count" "47" "$tk_log_content"
# Should NOT have 20 rows of the same error — check that "Bash" tool appears
# a reasonable number of times (deduplicated, not raw). In raw mode, "Bash" would
# appear 20 times in the table. Deduplicated, it should appear much fewer times.
_bash_row_count=$(echo "$tk_log_content" | grep -c "| Bash |" 2>/dev/null || echo "0")
# With dedup: 2 unique Bash signatures. Without dedup: 20 rows showing Bash.
# Assert <= 5 to allow some formatting flexibility but catch raw dump.
if [[ "$_bash_row_count" -le 5 ]]; then
    _dedup_ok="yes"
else
    _dedup_ok="no"
fi
assert_eq "test_ticket_dedup_not_raw_dump" "yes" "$_dedup_ok"
assert_pass_if_clean "test_ticket_deduplicates_error_details"
trap - EXIT
_teardown_test

# ---------------------------------------------------------------------------
# test_validation_sweep_parses_structured_log_format
# check-validation-failures.sh writes structured log lines:
#   "TIMESTAMP | UNTRACKED | CATEGORY | logfile: PATH"
# sweep_validation_failures must extract just CATEGORY for the ticket title.
# RED condition: sweep creates "Untracked validation failure: TIMESTAMP | UNTRACKED | hook-drift | ..."
#               instead of "Untracked validation failure: hook-drift" (bug 7490-9b62)
# ---------------------------------------------------------------------------
_snapshot_fail
_setup_test
trap '_teardown_test' EXIT
export ARTIFACTS_DIR="$TEST_HOME/artifacts"
mkdir -p "$ARTIFACTS_DIR"
# Write structured log line — this is the actual format check-validation-failures.sh uses
echo "2026-04-12T12:00:00Z | UNTRACKED | hook-drift | logfile: /tmp/validate.log" \
    > "$ARTIFACTS_DIR/untracked-validation-failures.log"
_mock_ticket_list_empty
_run_sweep_validation
# Ticket should have been created
create_calls=$(_count_tk_create_calls)
assert_eq "test_validation_sweep_parses_structured_log_format_creates" "1" "$create_calls"
# The ticket title must contain just "hook-drift" — not the timestamp or logfile path
_tk_log_content=$(cat "$TK_LOG" 2>/dev/null || echo "")
_title_has_hook_drift="no"
_title_has_timestamp="no"
if echo "$_tk_log_content" | grep -q "hook-drift"; then
    _title_has_hook_drift="yes"
fi
if echo "$_tk_log_content" | grep -q "2026-04-12T"; then
    _title_has_timestamp="yes"
fi
assert_eq "test_validation_sweep_parses_structured_log_format_title" "yes" "$_title_has_hook_drift"
assert_eq "test_validation_sweep_parses_structured_log_no_timestamp_in_title" "no" "$_title_has_timestamp"
assert_pass_if_clean "test_validation_sweep_parses_structured_log_format"
trap - EXIT
_teardown_test

print_summary
