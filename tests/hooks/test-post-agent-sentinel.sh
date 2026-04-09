#!/usr/bin/env bash
# tests/hooks/test-post-agent-sentinel.sh
# Unit tests for the PostToolUse Agent dispatcher and SUGGESTION: sentinel extraction.
#
# Tests:
#   test_post_agent_dispatcher_exists_and_is_executable
#   test_post_agent_hook_registered_in_plugin_json
#   test_post_agent_dispatcher_exits_0_on_clean_input
#   test_post_agent_dispatcher_calls_suggestion_record_on_suggestion_sentinel
#   test_post_agent_dispatcher_skips_non_agent_tools
#   test_post_agent_dispatcher_handles_missing_suggestion_gracefully
#   test_post_agent_dispatcher_warns_on_malformed_sentinel
#   test_post_agent_dispatcher_extracts_first_suggestion_only
#
# Uses DSO_SUGGESTION_RECORD_CMD env var to inject a mock suggestion-record
# command (same pattern as test-stop-suggestion-hook.sh).
#
# Usage: bash tests/hooks/test-post-agent-sentinel.sh
# Exit code: 0 if all pass, 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DSO_PLUGIN_DIR="$PLUGIN_ROOT/plugins/dso"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

# Override CLAUDE_PLUGIN_ROOT to ensure the dispatcher sources from this worktree's
# post-functions.sh (not the main repo) when run standalone. run-hook-tests.sh does
# the same via run-hook-tests.sh preamble.
export CLAUDE_PLUGIN_ROOT="$DSO_PLUGIN_DIR"

# Temp dir cleanup on exit
_CLEANUP_DIRS=()
_cleanup() {
    for d in "${_CLEANUP_DIRS[@]:-}"; do [[ -n "$d" ]] && rm -rf "$d" 2>/dev/null; done
}
trap _cleanup EXIT

POST_AGENT_DISPATCHER="$DSO_PLUGIN_DIR/hooks/dispatchers/post-agent.sh"
PLUGIN_JSON="$DSO_PLUGIN_DIR/.claude-plugin/plugin.json"

# ============================================================
# test_post_agent_dispatcher_exists_and_is_executable
# ============================================================
echo "--- test_post_agent_dispatcher_exists_and_is_executable ---"
_exists=0; [[ -f "$POST_AGENT_DISPATCHER" ]] && _exists=1
assert_eq "test_post_agent_dispatcher_exists_and_is_executable: file exists" "1" "$_exists"
_exec=0; [[ -x "$POST_AGENT_DISPATCHER" ]] && _exec=1
assert_eq "test_post_agent_dispatcher_exists_and_is_executable: file executable" "1" "$_exec"

# ============================================================
# test_post_agent_hook_registered_in_plugin_json
# The Agent PostToolUse hook must be registered in plugin.json.
# ============================================================
echo "--- test_post_agent_hook_registered_in_plugin_json ---"
if [[ -f "$PLUGIN_JSON" ]]; then
    _registered=$(python3 -c "
import json, sys
with open('$PLUGIN_JSON') as f:
    d = json.load(f)
post = d.get('hooks', {}).get('PostToolUse', [])
found = any(e.get('matcher') == 'Agent' for e in post)
print('registered' if found else 'absent')
" 2>&1)
else
    _registered="missing_file"
fi
assert_eq "test_post_agent_hook_registered_in_plugin_json" "registered" "$_registered"

# ============================================================
# Helper: create a mock suggestion-record command.
# Sets DSO_SUGGESTION_RECORD_CMD and _MOCK_CALL_LOG.
# Follows the pattern in test-stop-suggestion-hook.sh.
# ============================================================
_setup_mock_suggestion_record() {
    local tmpdir
    tmpdir=$(mktemp -d)
    _CLEANUP_DIRS+=("$tmpdir")
    _MOCK_CALL_LOG="$tmpdir/calls.log"
    local mock_cmd="$tmpdir/mock-suggest.sh"
    cat > "$mock_cmd" <<MOCK_EOF
#!/usr/bin/env bash
echo "\$@" >> "$_MOCK_CALL_LOG"
MOCK_EOF
    chmod +x "$mock_cmd"
    export DSO_SUGGESTION_RECORD_CMD="$mock_cmd"
}

# ============================================================
# test_post_agent_dispatcher_calls_suggestion_record_on_suggestion_sentinel
# Given Agent tool return output containing "SUGGESTION: <summary>",
# the hook must call suggestion-record.sh with the summary text.
# ============================================================
echo "--- test_post_agent_dispatcher_calls_suggestion_record_on_suggestion_sentinel ---"
_setup_mock_suggestion_record

# Agent tool PostToolUse JSON — output field contains SUGGESTION: sentinel
_INPUT='{"tool_name":"Agent","tool_input":{"prompt":"do work","subagent_type":"general-purpose"},"tool_response":{"output":"Some output\nSUGGESTION: Use parse_json_field instead of jq for JSON parsing\nMore output"}}'

bash "$POST_AGENT_DISPATCHER" <<< "$_INPUT" >/dev/null 2>/dev/null || true

_recorded=""
[[ -f "$_MOCK_CALL_LOG" ]] && _recorded=$(cat "$_MOCK_CALL_LOG")
assert_contains "test_post_agent_dispatcher_calls_suggestion_record_on_suggestion_sentinel: records suggestion text" \
    "Use parse_json_field instead of jq for JSON parsing" \
    "$_recorded"
# Verify --source="post-agent-hook" flag is passed
_has_source="no"
echo "$_recorded" | grep -q -- '--source=post-agent-hook' && _has_source="yes"
assert_eq "test_post_agent_dispatcher_calls_suggestion_record_on_suggestion_sentinel: --source=post-agent-hook flag present" \
    "yes" "$_has_source"
# Verify --observation= named flag is passed (not positional)
_has_obs="no"
echo "$_recorded" | grep -q -- '--observation=' && _has_obs="yes"
assert_eq "test_post_agent_dispatcher_calls_suggestion_record_on_suggestion_sentinel: --observation= flag present" \
    "yes" "$_has_obs"
unset DSO_SUGGESTION_RECORD_CMD

# ============================================================
# test_post_agent_dispatcher_skips_non_agent_tools
# For non-Agent tools, suggestion-record.sh must NOT be called.
# ============================================================
echo "--- test_post_agent_dispatcher_skips_non_agent_tools ---"
_setup_mock_suggestion_record

_INPUT='{"tool_name":"Bash","tool_input":{"command":"echo SUGGESTION: fake sentinel"},"tool_response":{"stdout":"SUGGESTION: fake sentinel","stderr":"","exit_code":0}}'

bash "$POST_AGENT_DISPATCHER" <<< "$_INPUT" >/dev/null 2>/dev/null || true

_recorded=""
[[ -f "$_MOCK_CALL_LOG" ]] && _recorded=$(cat "$_MOCK_CALL_LOG")
assert_eq "test_post_agent_dispatcher_skips_non_agent_tools: no call for non-Agent tool" \
    "" "$_recorded"
unset DSO_SUGGESTION_RECORD_CMD

# ============================================================
# test_post_agent_dispatcher_handles_missing_suggestion_gracefully
# When Agent output has no SUGGESTION: line, suggestion-record.sh must
# NOT be called — and the dispatcher must exit 0.
# ============================================================
echo "--- test_post_agent_dispatcher_handles_missing_suggestion_gracefully ---"
_setup_mock_suggestion_record

_INPUT='{"tool_name":"Agent","tool_input":{"prompt":"do work"},"tool_response":{"output":"Task complete. No suggestions."}}'

_exit_code=0
bash "$POST_AGENT_DISPATCHER" <<< "$_INPUT" >/dev/null 2>/dev/null || _exit_code=$?

assert_eq "test_post_agent_dispatcher_handles_missing_suggestion_gracefully: exits 0" "0" "$_exit_code"

_recorded=""
[[ -f "$_MOCK_CALL_LOG" ]] && _recorded=$(cat "$_MOCK_CALL_LOG")
assert_eq "test_post_agent_dispatcher_handles_missing_suggestion_gracefully: no suggestion-record call" \
    "" "$_recorded"
unset DSO_SUGGESTION_RECORD_CMD

# ============================================================
# test_post_agent_dispatcher_exits_0_on_clean_input
# The dispatcher must always exit 0 (PostToolUse hooks are non-blocking).
# ============================================================
echo "--- test_post_agent_dispatcher_exits_0_on_clean_input ---"
_exit_code=0
_INPUT='{"tool_name":"Agent","tool_input":{"prompt":"do work"},"tool_response":{"output":"Done.\nSUGGESTION: Extract helper to shared lib"}}'
bash "$POST_AGENT_DISPATCHER" <<< "$_INPUT" >/dev/null 2>/dev/null || _exit_code=$?
assert_eq "test_post_agent_dispatcher_exits_0_on_clean_input: exits 0" "0" "$_exit_code"

# ============================================================
# test_post_agent_dispatcher_warns_on_malformed_sentinel
# A SUGGESTION: line with no text after the colon should emit a warning
# to stderr but NOT crash (exit 0).
# ============================================================
echo "--- test_post_agent_dispatcher_warns_on_malformed_sentinel ---"
_setup_mock_suggestion_record

_INPUT='{"tool_name":"Agent","tool_input":{"prompt":"do work"},"tool_response":{"output":"Done.\nSUGGESTION:"}}'

_exit_code=0
_stderr_output=""
_stderr_output=$(bash "$POST_AGENT_DISPATCHER" <<< "$_INPUT" 2>&1 >/dev/null) || _exit_code=$?

assert_eq "test_post_agent_dispatcher_warns_on_malformed_sentinel: exits 0 on malformed" "0" "$_exit_code"
assert_contains "test_post_agent_dispatcher_warns_on_malformed_sentinel: warns to stderr" \
    "malformed" "$_stderr_output"

# No suggestion should be recorded for empty text
_recorded=""
[[ -f "$_MOCK_CALL_LOG" ]] && _recorded=$(cat "$_MOCK_CALL_LOG")
assert_eq "test_post_agent_dispatcher_warns_on_malformed_sentinel: no call for empty text" \
    "" "$_recorded"
unset DSO_SUGGESTION_RECORD_CMD

# ============================================================
# test_post_agent_dispatcher_extracts_first_suggestion_only
# When multiple SUGGESTION: lines appear, only the first is recorded.
# ============================================================
echo "--- test_post_agent_dispatcher_extracts_first_suggestion_only ---"
_setup_mock_suggestion_record

_INPUT='{"tool_name":"Agent","tool_input":{"prompt":"do work"},"tool_response":{"output":"Done.\nSUGGESTION: First suggestion text\nSUGGESTION: Second suggestion text"}}'

bash "$POST_AGENT_DISPATCHER" <<< "$_INPUT" >/dev/null 2>/dev/null || true

_recorded=""
[[ -f "$_MOCK_CALL_LOG" ]] && _recorded=$(cat "$_MOCK_CALL_LOG")
assert_contains "test_post_agent_dispatcher_extracts_first_suggestion_only: first suggestion recorded" \
    "First suggestion text" "$_recorded"
# Second suggestion should NOT appear in the call log (only 1 call recorded)
_line_count=0
[[ -f "$_MOCK_CALL_LOG" ]] && _line_count=$(wc -l < "$_MOCK_CALL_LOG" | tr -d ' ')
assert_eq "test_post_agent_dispatcher_extracts_first_suggestion_only: only one call made" \
    "1" "$_line_count"
unset DSO_SUGGESTION_RECORD_CMD

# ============================================================
# test_post_agent_dispatcher_exits_0_when_record_command_fails
# Fail-open: even if DSO_SUGGESTION_RECORD_CMD exits non-zero, dispatcher must exit 0.
# PostToolUse hooks are non-blocking — they must never stall or crash the agent.
# ============================================================
echo "--- test_post_agent_dispatcher_exits_0_when_record_command_fails ---"
_tmpfail=$(mktemp -d)
_CLEANUP_DIRS+=("$_tmpfail")
_fail_cmd="$_tmpfail/fail-suggest.sh"
cat > "$_fail_cmd" <<'FAIL_EOF'
#!/usr/bin/env bash
exit 1
FAIL_EOF
chmod +x "$_fail_cmd"
export DSO_SUGGESTION_RECORD_CMD="$_fail_cmd"

_INPUT='{"tool_name":"Agent","tool_input":{"prompt":"do work"},"tool_response":{"output":"Done.\nSUGGESTION: Some suggestion to record"}}'
_exit_code=0
bash "$POST_AGENT_DISPATCHER" <<< "$_INPUT" >/dev/null 2>/dev/null || _exit_code=$?
assert_eq "test_post_agent_dispatcher_exits_0_when_record_command_fails: exits 0 even when record fails" \
    "0" "$_exit_code"
unset DSO_SUGGESTION_RECORD_CMD

# ============================================================
# Summary
# ============================================================
print_summary
