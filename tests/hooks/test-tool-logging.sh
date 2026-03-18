#!/usr/bin/env bash
# tests/hooks/test-tool-logging.sh
# Tests for .claude/hooks/tool-logging.sh
#
# tool-logging.sh is a PreToolUse/PostToolUse hook that logs every tool call
# as JSONL. It always exits 0. Only logs if ~/.claude/tool-logging-enabled exists.
#
# All tests use an isolated $HOME (temp dir) so no real user files are touched.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DSO_PLUGIN_DIR="$PLUGIN_ROOT/plugins/dso"
REPO_ROOT="$(git rev-parse --show-toplevel)"
HOOK="$DSO_PLUGIN_DIR/hooks/tool-logging.sh"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

# --- Test isolation: override HOME to a temp directory ---
_REAL_HOME="$HOME"
TEST_HOME=$(mktemp -d)
export HOME="$TEST_HOME"
mkdir -p "$TEST_HOME/.claude/logs"
trap 'export HOME="$_REAL_HOME"; rm -rf "$TEST_HOME"' EXIT

LOGGING_FLAG="$TEST_HOME/.claude/tool-logging-enabled"

run_hook_exit() {
    local input="$1"
    local mode="${2:-pre}"
    local exit_code=0
    echo "$input" | bash "$HOOK" "$mode" > /dev/null 2>/dev/null || exit_code=$?
    echo "$exit_code"
}

# test_tool_logging_exits_zero_always (pre mode, logging disabled)
INPUT='{"tool_name":"Bash","tool_input":{"command":"echo test"}}'
EXIT_CODE=$(run_hook_exit "$INPUT" "pre")
assert_eq "test_tool_logging_exits_zero_always_pre_disabled" "0" "$EXIT_CODE"

# test_tool_logging_exits_zero_always (post mode, logging disabled)
INPUT='{"tool_name":"Bash","tool_input":{"command":"echo test"},"tool_response":{"exit_code":0}}'
EXIT_CODE=$(run_hook_exit "$INPUT" "post")
assert_eq "test_tool_logging_exits_zero_always_post_disabled" "0" "$EXIT_CODE"

# test_tool_logging_exits_zero_on_empty_input (pre mode)
EXIT_CODE=$(run_hook_exit "" "pre")
assert_eq "test_tool_logging_exits_zero_on_empty_input_pre" "0" "$EXIT_CODE"

# test_tool_logging_exits_zero_on_empty_input (post mode)
EXIT_CODE=$(run_hook_exit "" "post")
assert_eq "test_tool_logging_exits_zero_on_empty_input_post" "0" "$EXIT_CODE"

# test_tool_logging_exits_zero_on_malformed_json
EXIT_CODE=$(run_hook_exit "not json {{" "pre")
assert_eq "test_tool_logging_exits_zero_on_malformed_json" "0" "$EXIT_CODE"

# test_tool_logging_pre_produces_no_stdout
# pre mode must produce zero bytes on stdout (would block tool if it did)
OUTPUT=$(echo '{"tool_name":"Bash","tool_input":{"command":"echo test"}}' | bash "$HOOK" "pre" 2>/dev/null)
assert_eq "test_tool_logging_pre_produces_no_stdout" "" "$OUTPUT"

# test_tool_logging_exits_zero_with_logging_enabled
# Even with logging enabled, should exit 0
touch "$LOGGING_FLAG"
INPUT='{"tool_name":"Bash","tool_input":{"command":"echo test"},"session_id":"test-session"}'
EXIT_CODE=$(run_hook_exit "$INPUT" "pre")
assert_eq "test_tool_logging_exits_zero_with_logging_enabled" "0" "$EXIT_CODE"
rm -f "$LOGGING_FLAG"

# ---- JSONL output schema tests (logging enabled) ----

# Setup: enable logging (already in isolated TEST_HOME)
touch "$LOGGING_FLAG"

# test_jsonl_pre_mode_has_required_fields
INPUT='{"tool_name":"Bash","tool_input":{"command":"ls -la"},"session_id":"test-jsonl-123"}'
echo "$INPUT" | bash "$HOOK" "pre" > /dev/null 2>/dev/null
LOG_FILE="$TEST_HOME/.claude/logs/tool-use-$(date +%Y-%m-%d).jsonl"
if [[ -f "$LOG_FILE" ]]; then
    LAST_LINE=$(tail -1 "$LOG_FILE")
    # Validate all required fields present using python3
    FIELDS_OK=$(echo "$LAST_LINE" | python3 -c "
import json,sys
d=json.load(sys.stdin)
required=['ts','epoch_ms','session_id','tool_name','hook_type','tool_input_summary']
print('yes' if all(k in d for k in required) else 'no')
" 2>/dev/null || echo "no")
    assert_eq "test_jsonl_pre_mode_has_required_fields" "yes" "$FIELDS_OK"

    # Validate field values
    TOOL_NAME_VAL=$(echo "$LAST_LINE" | python3 -c "import json,sys; print(json.load(sys.stdin)['tool_name'])" 2>/dev/null)
    assert_eq "test_jsonl_pre_tool_name" "Bash" "$TOOL_NAME_VAL"

    HOOK_TYPE_VAL=$(echo "$LAST_LINE" | python3 -c "import json,sys; print(json.load(sys.stdin)['hook_type'])" 2>/dev/null)
    assert_eq "test_jsonl_pre_hook_type" "pre" "$HOOK_TYPE_VAL"

    SESSION_VAL=$(echo "$LAST_LINE" | python3 -c "import json,sys; print(json.load(sys.stdin)['session_id'])" 2>/dev/null)
    assert_eq "test_jsonl_pre_session_id" "test-jsonl-123" "$SESSION_VAL"

    # epoch_ms should be numeric
    EPOCH_IS_NUM=$(echo "$LAST_LINE" | python3 -c "import json,sys; d=json.load(sys.stdin); print('yes' if isinstance(d['epoch_ms'],int) else 'no')" 2>/dev/null || echo "no")
    assert_eq "test_jsonl_pre_epoch_ms_numeric" "yes" "$EPOCH_IS_NUM"

    # pre mode should NOT have exit_status
    NO_EXIT=$(echo "$LAST_LINE" | python3 -c "import json,sys; d=json.load(sys.stdin); print('yes' if 'exit_status' not in d else 'no')" 2>/dev/null || echo "no")
    assert_eq "test_jsonl_pre_no_exit_status" "yes" "$NO_EXIT"
else
    assert_eq "test_jsonl_pre_mode_log_file_created" "exists" "missing"
fi

# test_jsonl_post_mode_has_exit_status
INPUT='{"tool_name":"Read","tool_input":{"file_path":"/tmp/test"},"session_id":"test-jsonl-456","tool_response":{"exit_code":0}}'
echo "$INPUT" | bash "$HOOK" "post" > /dev/null 2>/dev/null
LAST_LINE=$(tail -1 "$LOG_FILE")
HAS_EXIT=$(echo "$LAST_LINE" | python3 -c "import json,sys; d=json.load(sys.stdin); print('yes' if 'exit_status' in d and d['exit_status']==0 else 'no')" 2>/dev/null || echo "no")
assert_eq "test_jsonl_post_has_exit_status" "yes" "$HAS_EXIT"

POST_HOOK_TYPE=$(echo "$LAST_LINE" | python3 -c "import json,sys; print(json.load(sys.stdin)['hook_type'])" 2>/dev/null)
assert_eq "test_jsonl_post_hook_type" "post" "$POST_HOOK_TYPE"

# test_jsonl_valid_json_output (every line should be parseable JSON)
VALID_JSON=$(python3 -c "
import json, sys
for line in open('$LOG_FILE'):
    line = line.strip()
    if not line: continue
    json.loads(line)
print('yes')
" 2>/dev/null || echo "no")
assert_eq "test_jsonl_all_lines_valid_json" "yes" "$VALID_JSON"

# test_jsonl_no_jq_calls (tool-logging.sh should not contain jq calls)
JQ_CALLS=$(grep -cE '^\s*(check_tool jq|.*\| jq |jq -)' "$HOOK" 2>/dev/null) || JQ_CALLS="0"
assert_eq "test_no_jq_calls_in_hook" "0" "$JQ_CALLS"

# test_jsonl_sensitive_field_redaction
INPUT='{"tool_name":"Bash","tool_input":{"command":"curl","api_key":"secret123","token":"tok_abc"},"session_id":"test-redact"}'
echo "$INPUT" | bash "$HOOK" "pre" > /dev/null 2>/dev/null
LAST_LINE=$(tail -1 "$LOG_FILE")
# The tool_input_summary should not contain the actual secret values
NO_SECRET=$(echo "$LAST_LINE" | python3 -c "
import json,sys
d=json.load(sys.stdin)
s=d.get('tool_input_summary','')
print('yes' if 'secret123' not in s and 'tok_abc' not in s else 'no')
" 2>/dev/null || echo "no")
assert_eq "test_jsonl_redaction_hides_secrets" "yes" "$NO_SECRET"

# test_jsonl_truncation (tool_input_summary should be <= 500 chars)
SUMMARY_LEN=$(echo "$LAST_LINE" | python3 -c "import json,sys; d=json.load(sys.stdin); print(len(d.get('tool_input_summary','')))" 2>/dev/null || echo "999")
WITHIN_LIMIT=$( (( SUMMARY_LEN <= 500 )) && echo "yes" || echo "no" )
assert_eq "test_jsonl_summary_within_500_chars" "yes" "$WITHIN_LIMIT"

# ---- Dispatcher integration tests ----
# Verify tool logging works when invoked via per-tool dispatchers
# (post-consolidation: dispatchers replaced catch-all empty-matcher hooks)

PRE_BASH_DISPATCHER="$DSO_PLUGIN_DIR/hooks/dispatchers/pre-bash.sh"
POST_BASH_DISPATCHER="$DSO_PLUGIN_DIR/hooks/dispatchers/post-bash.sh"

# Reset log file for dispatcher tests
rm -f "$LOG_FILE"

# test_tool_logging_NOT_in_pre_bash_dispatcher (removed per hook optimization)
INPUT='{"tool_name":"Bash","tool_input":{"command":"echo dispatcher-test"},"session_id":"disp-pre-123"}'
printf '%s' "$INPUT" | bash "$PRE_BASH_DISPATCHER" 2>/dev/null || true
_DISP_LOG="$TEST_HOME/.claude/logs/tool-use-$(date +%Y-%m-%d).jsonl"
_disp_pre_ok="no"
if [[ -f "$_DISP_LOG" ]] && grep -q '"hook_type":"pre"' "$_DISP_LOG" 2>/dev/null; then
    _disp_pre_ok="yes"
fi
assert_eq "test_tool_logging_NOT_in_pre_bash_dispatcher" "no" "$_disp_pre_ok"

# test_tool_logging_NOT_in_post_bash_dispatcher (removed per hook optimization)
INPUT='{"tool_name":"Bash","tool_input":{"command":"echo dispatcher-test"},"tool_response":{"stdout":"ok","exit_code":0},"session_id":"disp-post-456"}'
printf '%s' "$INPUT" | bash "$POST_BASH_DISPATCHER" 2>/dev/null || true
_disp_post_ok="no"
if [[ -f "$_DISP_LOG" ]] && grep -q '"hook_type":"post"' "$_DISP_LOG" 2>/dev/null; then
    _disp_post_ok="yes"
fi
assert_eq "test_tool_logging_NOT_in_post_bash_dispatcher" "no" "$_disp_post_ok"

print_summary
