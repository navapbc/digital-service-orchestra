#!/usr/bin/env bash
# lockpick-workflow/tests/hooks/test-tool-logging-summary.sh
# Tests for .claude/hooks/tool-logging-summary.sh
#
# tool-logging-summary.sh is a Stop hook that outputs a session summary
# of tool usage. Always exits 0. Only runs if logging is enabled AND
# a session ID file exists AND >= 10 tool calls were made.

REPO_ROOT="$(git rev-parse --show-toplevel)"
HOOK="$REPO_ROOT/lockpick-workflow/hooks/tool-logging-summary.sh"

source "$REPO_ROOT/lockpick-workflow/tests/lib/assert.sh"

LOGGING_FLAG="$HOME/.claude/tool-logging-enabled"
SESSION_FILE="$HOME/.claude/current-session-id"

run_hook_exit() {
    local exit_code=0
    bash "$HOOK" 2>/dev/null < /dev/null || exit_code=$?
    echo "$exit_code"
}

run_hook_output() {
    bash "$HOOK" 2>/dev/null < /dev/null
}

# Save state
LOGGING_WAS_ENABLED=false
ORIG_SESSION=""
if [[ -f "$LOGGING_FLAG" ]]; then
    LOGGING_WAS_ENABLED=true
    rm -f "$LOGGING_FLAG"
fi
if [[ -f "$SESSION_FILE" ]]; then
    ORIG_SESSION=$(cat "$SESSION_FILE")
fi

# test_tool_logging_summary_exits_zero_on_valid_input
# Without logging enabled, should exit 0 immediately
EXIT_CODE=$(run_hook_exit)
assert_eq "test_tool_logging_summary_exits_zero_on_valid_input" "0" "$EXIT_CODE"

# test_tool_logging_summary_exits_zero_without_logging_enabled
# No logging flag → fast path exit 0
EXIT_CODE=$(run_hook_exit)
assert_eq "test_tool_logging_summary_exits_zero_without_logging_enabled" "0" "$EXIT_CODE"

# test_tool_logging_summary_exits_zero_with_logging_but_no_session
# Logging enabled but no session ID file → exit 0
touch "$LOGGING_FLAG"
rm -f "$SESSION_FILE"
EXIT_CODE=$(run_hook_exit)
assert_eq "test_tool_logging_summary_exits_zero_with_logging_but_no_session" "0" "$EXIT_CODE"

# test_tool_logging_summary_exits_zero_with_no_log_file
# Logging enabled, session ID exists, but no today's log file → exit 0
echo "test-session-$$" > "$SESSION_FILE"
LOG_FILE="$HOME/.claude/logs/tool-use-$(date +%Y-%m-%d).jsonl"
ORIG_LOG_CONTENT=""
if [[ -f "$LOG_FILE" ]]; then
    ORIG_LOG_CONTENT=$(cat "$LOG_FILE")
    rm -f "$LOG_FILE"
fi
EXIT_CODE=$(run_hook_exit)
assert_eq "test_tool_logging_summary_exits_zero_with_no_log_file" "0" "$EXIT_CODE"

# test_tool_logging_summary_exits_zero_with_few_calls
# Logging enabled, session ID exists, but < 10 tool calls → exit 0 silently
mkdir -p "$HOME/.claude/logs"
SESSION_ID="test-session-$$"
echo "$SESSION_ID" > "$SESSION_FILE"
NOW=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
# Write only 3 post entries (below 10 threshold)
for i in 1 2 3; do
    printf '{"ts":"%s","epoch_ms":%s,"session_id":"%s","tool_name":"Bash","hook_type":"post","tool_input_summary":"{}"}\n' \
        "$NOW" "$(date +%s)000" "$SESSION_ID" >> "$LOG_FILE"
done

OUTPUT=$(run_hook_output)
EXIT_CODE=$(run_hook_exit)
assert_eq "test_tool_logging_summary_exits_zero_with_few_calls" "0" "$EXIT_CODE"
assert_eq "test_tool_logging_summary_output_empty_with_few_calls" "" "$OUTPUT"

# Restore state
rm -f "$LOGGING_FLAG"
if [[ -n "$ORIG_LOG_CONTENT" ]]; then
    echo "$ORIG_LOG_CONTENT" > "$LOG_FILE"
elif [[ -f "$LOG_FILE" ]]; then
    rm -f "$LOG_FILE"
fi
if [[ -n "$ORIG_SESSION" ]]; then
    echo "$ORIG_SESSION" > "$SESSION_FILE"
else
    rm -f "$SESSION_FILE"
fi
if [[ "$LOGGING_WAS_ENABLED" == "true" ]]; then
    touch "$LOGGING_FLAG"
fi

print_summary
