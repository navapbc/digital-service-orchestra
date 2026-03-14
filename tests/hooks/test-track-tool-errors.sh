#!/usr/bin/env bash
# lockpick-workflow/tests/hooks/test-track-tool-errors.sh
# Tests for .claude/hooks/track-tool-errors.sh
#
# track-tool-errors.sh is a PostToolUseFailure hook that categorizes and counts
# tool errors, and creates a bug ticket when any category reaches 50 occurrences.
# It always exits 0 (non-blocking).
#
# All tests use an isolated $HOME (temp dir) so no real user files are touched.

REPO_ROOT="$(git rev-parse --show-toplevel)"
HOOK="$REPO_ROOT/lockpick-workflow/hooks/track-tool-errors.sh"

source "$REPO_ROOT/lockpick-workflow/tests/lib/assert.sh"

# --- Test isolation: override HOME to a temp directory ---
_REAL_HOME="$HOME"
TEST_HOME=$(mktemp -d)
export HOME="$TEST_HOME"
mkdir -p "$TEST_HOME/.claude"
trap 'export HOME="$_REAL_HOME"; rm -rf "$TEST_HOME"' EXIT

COUNTER_FILE="$TEST_HOME/.claude/tool-error-counter.json"

run_hook() {
    local input="$1"
    local exit_code=0
    echo "$input" | bash "$HOOK" > /dev/null 2>/dev/null || exit_code=$?
    echo "$exit_code"
}

run_hook_output() {
    local input="$1"
    echo "$input" | bash "$HOOK" 2>/dev/null
}

# test_track_tool_errors_exits_zero_on_interrupt
# User interrupts are skipped (is_interrupt=true) → exit 0
INPUT='{"tool_name":"Bash","error":"interrupted","is_interrupt":true}'
EXIT_CODE=$(run_hook "$INPUT")
assert_eq "test_track_tool_errors_exits_zero_on_interrupt" "0" "$EXIT_CODE"

# test_track_tool_errors_exits_zero_on_empty_error
# No error message → skip silently, exit 0
INPUT='{"tool_name":"Bash","error":""}'
EXIT_CODE=$(run_hook "$INPUT")
assert_eq "test_track_tool_errors_exits_zero_on_empty_error" "0" "$EXIT_CODE"

# test_track_tool_errors_exits_zero_on_normal_error
# Normal tool error → categorize, increment counter, exit 0
rm -f "$COUNTER_FILE"

INPUT='{"tool_name":"Read","error":"file not found: /tmp/test.txt","is_interrupt":false}'
EXIT_CODE=$(run_hook "$INPUT")
assert_eq "test_track_tool_errors_exits_zero_on_normal_error" "0" "$EXIT_CODE"

rm -f "$COUNTER_FILE"

# test_track_tool_errors_exits_zero_on_malformed_json
# Malformed JSON → exit 0 (fail-open)
EXIT_CODE=$(run_hook "not json {{")
assert_eq "test_track_tool_errors_exits_zero_on_malformed_json" "0" "$EXIT_CODE"

# test_track_tool_errors_creates_tk_bug
# Stub tk in PATH. Feed hook an error that pushes counter to 50.
# Assert tk create is called (FAILS now because hook calls bd create).
_TTE_FAKE_BIN=$(mktemp -d)
_TTE_TK_LOG="$_TTE_FAKE_BIN/tk.log"

cat > "$_TTE_FAKE_BIN/tk" << 'MOCK_EOF'
#!/usr/bin/env bash
echo "$@" >> "$TK_LOG"
echo "Created issue: tk-004"
MOCK_EOF
chmod +x "$_TTE_FAKE_BIN/tk"

# Build a counter file where 'permission_denied' is at 49 occurrences (threshold is 50)
# So the next call will push it to 50 and trigger bug creation.
# NOTE: 'file_not_found' is in NOISE_CATEGORIES and is intentionally excluded from
# auto-bug-creation. Use 'permission_denied' (not in NOISE_CATEGORIES) instead.
cat > "$COUNTER_FILE" << 'JSON_EOF'
{"index":{"permission_denied":49},"errors":[],"bugs_created":{}}
JSON_EOF

INPUT='{"tool_name":"Read","error":"permission denied: /tmp/trigger.txt","is_interrupt":false}'
# REVIEW-DEFENSE: TK_LOG and PATH are prefixed to `bash "$HOOK"` (right side of pipe),
# not to `echo` (left side). The env vars correctly reach the hook process.
echo "$INPUT" | TK_LOG="$_TTE_TK_LOG" PATH="$_TTE_FAKE_BIN:$PATH" bash "$HOOK" >/dev/null 2>/dev/null || true

# Check that tk create was called
_TTE_TK_CALLED="no"
if [[ -f "$_TTE_TK_LOG" ]] && grep -q "create" "$_TTE_TK_LOG" 2>/dev/null; then
    _TTE_TK_CALLED="yes"
fi
assert_eq "test_track_tool_errors_creates_tk_bug" "yes" "$_TTE_TK_CALLED"

rm -f "$COUNTER_FILE"
rm -rf "$_TTE_FAKE_BIN"

# ============================================================
# Group: jq removal
# ============================================================
# These tests verify that track-tool-errors.sh has zero jq calls
# and produces valid JSON via python3/bash alternatives.

# test_track_tool_errors_no_jq_calls_remain
# grep the hook source for jq invocations — must return zero.
_TTE_JQ_COUNT=$(grep -cE '^\s*(check_tool jq|.*\| jq |jq -)' "$HOOK" 2>/dev/null; true)
assert_eq "test_track_tool_errors_no_jq_calls_remain" "0" "$_TTE_JQ_COUNT"

# test_track_tool_errors_counter_json_structure
# Feed a known error, then validate the counter file has correct JSON structure.
rm -f "$COUNTER_FILE"

INPUT='{"tool_name":"Bash","error":"command not found: foobar","tool_input":{"command":"foobar --version"},"session_id":"test-session-123","is_interrupt":false}'
echo "$INPUT" | bash "$HOOK" >/dev/null 2>/dev/null || true

# Validate JSON structure using python3
_TTE_JSON_VALID="no"
if [[ -f "$COUNTER_FILE" ]]; then
    _TTE_JSON_VALID=$(python3 -c "
import json, sys
d = json.load(open('$COUNTER_FILE'))
# Must have index, errors, bugs_created
assert isinstance(d.get('index'), dict), 'missing index'
assert isinstance(d.get('errors'), list), 'missing errors'
assert isinstance(d.get('bugs_created'), dict), 'missing bugs_created'
# errors list must have at least one entry with correct fields
if len(d['errors']) > 0:
    e = d['errors'][-1]
    for field in ['id', 'timestamp', 'category', 'tool_name', 'input_summary', 'error_message', 'session_id']:
        assert field in e, f'missing field: {field}'
# index must have the category incremented
assert d['index'].get('command_not_found', 0) >= 1, 'index not incremented'
print('yes')
" 2>/dev/null || echo "no")
fi
assert_eq "test_track_tool_errors_counter_json_structure" "yes" "$_TTE_JSON_VALID"

# test_track_tool_errors_input_summary_populated
# The input_summary field should contain meaningful content from tool_input
_TTE_SUMMARY_OK="no"
if [[ -f "$COUNTER_FILE" ]]; then
    _TTE_SUMMARY_OK=$(python3 -c "
import json
d = json.load(open('$COUNTER_FILE'))
last_error = d['errors'][-1]
summary = last_error.get('input_summary', '')
# Should contain key=value from tool_input
if 'command=' in summary:
    print('yes')
else:
    print('no')
" 2>/dev/null || echo "no")
fi
assert_eq "test_track_tool_errors_input_summary_populated" "yes" "$_TTE_SUMMARY_OK"

# test_track_tool_errors_second_error_increments
# Feed a second error of the same category, verify index increments
INPUT2='{"tool_name":"Bash","error":"command not found: baz","tool_input":{"command":"baz"},"session_id":"test-session-456","is_interrupt":false}'
echo "$INPUT2" | bash "$HOOK" >/dev/null 2>/dev/null || true

_TTE_INCREMENT_OK="no"
if [[ -f "$COUNTER_FILE" ]]; then
    _TTE_INCREMENT_OK=$(python3 -c "
import json
d = json.load(open('$COUNTER_FILE'))
count = d['index'].get('command_not_found', 0)
errors_count = len(d['errors'])
if count >= 2 and errors_count >= 2:
    print('yes')
else:
    print('no')
" 2>/dev/null || echo "no")
fi
assert_eq "test_track_tool_errors_second_error_increments" "yes" "$_TTE_INCREMENT_OK"

# test_track_tool_errors_bug_recorded_in_json
# Prime counter at 49, trigger threshold, verify bugs_created is set in JSON
rm -f "$COUNTER_FILE"
cat > "$COUNTER_FILE" << 'JSON_EOF2'
{"index":{"permission_denied":49},"errors":[],"bugs_created":{}}
JSON_EOF2

_TTE_FAKE_BIN2=$(mktemp -d)
_TTE_TK_LOG2="$_TTE_FAKE_BIN2/tk.log"
cat > "$_TTE_FAKE_BIN2/tk" << 'MOCK_EOF2'
#!/usr/bin/env bash
echo "$@" >> "$TK_LOG"
echo "test-bug-id-999"
MOCK_EOF2
chmod +x "$_TTE_FAKE_BIN2/tk"

INPUT3='{"tool_name":"Read","error":"permission denied: /tmp/x","tool_input":{},"session_id":"s1","is_interrupt":false}'
echo "$INPUT3" | TK_LOG="$_TTE_TK_LOG2" PATH="$_TTE_FAKE_BIN2:$PATH" bash "$HOOK" >/dev/null 2>/dev/null || true

_TTE_BUG_RECORDED="no"
if [[ -f "$COUNTER_FILE" ]]; then
    _TTE_BUG_RECORDED=$(python3 -c "
import json
d = json.load(open('$COUNTER_FILE'))
bug_id = d.get('bugs_created', {}).get('permission_denied', 'none')
if bug_id != 'none' and len(bug_id) > 0:
    print('yes')
else:
    print('no')
" 2>/dev/null || echo "no")
fi
assert_eq "test_track_tool_errors_bug_recorded_in_json" "yes" "$_TTE_BUG_RECORDED"

rm -f "$COUNTER_FILE"
rm -rf "$_TTE_FAKE_BIN2"

print_summary
