#!/usr/bin/env bash
# lockpick-workflow/tests/hooks/test-tool-logging.sh
# Tests for .claude/hooks/tool-logging.sh
#
# tool-logging.sh is a PreToolUse/PostToolUse hook that logs every tool call
# as JSONL. It always exits 0. Only logs if ~/.claude/tool-logging-enabled exists.

REPO_ROOT="$(git rev-parse --show-toplevel)"
HOOK="$REPO_ROOT/lockpick-workflow/hooks/tool-logging.sh"

source "$REPO_ROOT/lockpick-workflow/tests/lib/assert.sh"

LOGGING_FLAG="$HOME/.claude/tool-logging-enabled"

run_hook_exit() {
    local input="$1"
    local mode="${2:-pre}"
    local exit_code=0
    echo "$input" | bash "$HOOK" "$mode" > /dev/null 2>/dev/null || exit_code=$?
    echo "$exit_code"
}

# Ensure logging is disabled for these tests (so we don't create test log entries)
LOGGING_WAS_ENABLED=false
if [[ -f "$LOGGING_FLAG" ]]; then
    LOGGING_WAS_ENABLED=true
    rm -f "$LOGGING_FLAG"
fi

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

# Restore logging state
if [[ "$LOGGING_WAS_ENABLED" == "true" ]]; then
    touch "$LOGGING_FLAG"
fi

print_summary
