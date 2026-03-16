#!/usr/bin/env bash
# lockpick-workflow/tests/hooks/test-track-tool-errors.sh
# Tests for .claude/hooks/track-tool-errors.sh
#
# track-tool-errors.sh is a PostToolUseFailure hook that categorizes and counts
# tool errors, and creates a bug ticket when any category reaches 50 occurrences.
# It always exits 0 (non-blocking).
#
# All tests use an isolated $HOME (temp dir) so no real user files are touched.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
REPO_ROOT="$(git rev-parse --show-toplevel)"
HOOK="$PLUGIN_ROOT/hooks/track-tool-errors.sh"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

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

# test_no_ticket_creation_at_threshold
# Set counter permission_denied=49, mock tk in PATH, trigger error at threshold.
# Assert: count=50, no tk call logged, no bugs_created key, no hook output.
TEST_BIN=$(mktemp -d)
TK_CALL_LOG="$TEST_BIN/tk-calls.log"
cat > "$TEST_BIN/tk" << 'TK_EOF'
#!/usr/bin/env bash
echo "$@" >> "$TK_CALL_LOG"
echo "lockpick-doc-to-logic-mock"
TK_EOF
chmod +x "$TEST_BIN/tk"
# Inject TK_CALL_LOG path into the mock script
sed -i.bak "s|TK_CALL_LOG|$TK_CALL_LOG|g" "$TEST_BIN/tk"

cat > "$COUNTER_FILE" << 'JSON_EOF'
{"index":{"permission_denied":49},"errors":[]}
JSON_EOF

INPUT='{"tool_name":"Read","error":"permission denied: /tmp/trigger.txt","is_interrupt":false}'
_TTE_OUTPUT=$(echo "$INPUT" | PATH="$TEST_BIN:$PATH" TK_CALL_LOG="$TK_CALL_LOG" bash "$HOOK" 2>/dev/null || true)

# Assert count reached 50
_TTE_COUNT=$(python3 -c "import json; d=json.load(open('$COUNTER_FILE')); print(d.get('index',{}).get('permission_denied',0))" 2>/dev/null || echo 0)
assert_eq "test_no_ticket_creation_at_threshold_count" "50" "$_TTE_COUNT"

# Assert tk was NOT called
_TTE_TK_CALLED="no"
if [[ -f "$TK_CALL_LOG" ]]; then _TTE_TK_CALLED="yes"; fi
assert_eq "test_no_ticket_creation_at_threshold_no_tk_call" "no" "$_TTE_TK_CALLED"

# Assert no bugs_created key in counter file
_TTE_BUGS_CREATED=$(python3 -c "import json; d=json.load(open('$COUNTER_FILE')); print('yes' if 'bugs_created' in d else 'no')" 2>/dev/null || echo "no")
assert_eq "test_no_ticket_creation_at_threshold_no_bugs_created" "no" "$_TTE_BUGS_CREATED"

# Assert no hook output (no "Recurring tool error detected")
_TTE_OUTPUT_CLEAN="yes"
if echo "$_TTE_OUTPUT" | grep -q "Recurring tool error detected" 2>/dev/null; then
    _TTE_OUTPUT_CLEAN="no"
fi
assert_eq "test_no_ticket_creation_at_threshold_no_output" "yes" "$_TTE_OUTPUT_CLEAN"

rm -rf "$TEST_BIN"
rm -f "$COUNTER_FILE"

# test_permission_denied_at_50_no_ticket
# Non-noise category at exactly threshold count — no tk call.
TEST_BIN2=$(mktemp -d)
TK_CALL_LOG2="$TEST_BIN2/tk-calls.log"
cat > "$TEST_BIN2/tk" << TK2_EOF
#!/usr/bin/env bash
echo "\$@" >> "$TK_CALL_LOG2"
echo "lockpick-doc-to-logic-mock"
TK2_EOF
chmod +x "$TEST_BIN2/tk"

cat > "$COUNTER_FILE" << 'JSON_EOF'
{"index":{"permission_denied":49},"errors":[]}
JSON_EOF

INPUT='{"tool_name":"Read","error":"permission denied: /tmp/test2.txt","is_interrupt":false}'
PATH="$TEST_BIN2:$PATH" bash "$HOOK" >/dev/null 2>/dev/null || true

_TTE_TK2_CALLED="no"
if [[ -f "$TK_CALL_LOG2" ]]; then _TTE_TK2_CALLED="yes"; fi
assert_eq "test_permission_denied_at_50_no_ticket" "no" "$_TTE_TK2_CALLED"

rm -rf "$TEST_BIN2"
rm -f "$COUNTER_FILE"

# test_noise_category_at_threshold_no_ticket
# Noise category (file_not_found) at threshold — no tk call.
TEST_BIN3=$(mktemp -d)
TK_CALL_LOG3="$TEST_BIN3/tk-calls.log"
cat > "$TEST_BIN3/tk" << TK3_EOF
#!/usr/bin/env bash
echo "\$@" >> "$TK_CALL_LOG3"
echo "lockpick-doc-to-logic-mock"
TK3_EOF
chmod +x "$TEST_BIN3/tk"

cat > "$COUNTER_FILE" << 'JSON_EOF'
{"index":{"file_not_found":49},"errors":[]}
JSON_EOF

INPUT='{"tool_name":"Read","error":"file not found: /tmp/test3.txt","is_interrupt":false}'
PATH="$TEST_BIN3:$PATH" bash "$HOOK" >/dev/null 2>/dev/null || true

_TTE_TK3_CALLED="no"
if [[ -f "$TK_CALL_LOG3" ]]; then _TTE_TK3_CALLED="yes"; fi
assert_eq "test_noise_category_at_threshold_no_ticket" "no" "$_TTE_TK3_CALLED"

rm -rf "$TEST_BIN3"
rm -f "$COUNTER_FILE"

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
# Must have index, errors
assert isinstance(d.get('index'), dict), 'missing index'
assert isinstance(d.get('errors'), list), 'missing errors'
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

rm -f "$COUNTER_FILE"

print_summary
