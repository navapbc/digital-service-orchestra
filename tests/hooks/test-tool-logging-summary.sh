#!/usr/bin/env bash
# lockpick-workflow/tests/hooks/test-tool-logging-summary.sh
# Tests for .claude/hooks/tool-logging-summary.sh
#
# tool-logging-summary.sh is a Stop hook that outputs a session summary
# of tool usage. Always exits 0. Only runs if logging is enabled AND
# a session ID file exists AND >= 10 tool calls were made.
#
# All tests use an isolated $HOME (temp dir) so no real user files are touched.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
REPO_ROOT="$(git rev-parse --show-toplevel)"
HOOK="$PLUGIN_ROOT/hooks/tool-logging-summary.sh"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

# --- Test isolation: override HOME to a temp directory ---
_REAL_HOME="$HOME"
TEST_HOME=$(mktemp -d)
export HOME="$TEST_HOME"
mkdir -p "$TEST_HOME/.claude/logs"
trap 'export HOME="$_REAL_HOME"; rm -rf "$TEST_HOME"' EXIT

LOGGING_FLAG="$TEST_HOME/.claude/tool-logging-enabled"
SESSION_FILE="$TEST_HOME/.claude/current-session-id"

run_hook_exit() {
    local exit_code=0
    bash "$HOOK" 2>/dev/null < /dev/null >/dev/null || exit_code=$?
    echo "$exit_code"
}

run_hook_output() {
    bash "$HOOK" 2>/dev/null < /dev/null
}

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
LOG_FILE="$TEST_HOME/.claude/logs/tool-use-$(date +%Y-%m-%d).jsonl"
rm -f "$LOG_FILE"
EXIT_CODE=$(run_hook_exit)
assert_eq "test_tool_logging_summary_exits_zero_with_no_log_file" "0" "$EXIT_CODE"

# test_tool_logging_summary_exits_zero_with_few_calls
# Logging enabled, session ID exists, but < 10 tool calls → exit 0 silently
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

# Clean up the partial log
rm -f "$LOG_FILE"

# test_tool_logging_summary_full_output_format
# With >= 10 tool calls, should produce markdown summary
SESSION_ID="test-summary-format-$$"
echo "$SESSION_ID" > "$SESSION_FILE"
# Write 12 post entries with matching pre entries across different tools
# Use specific epoch_ms values for deterministic duration and slow-call ordering
BASE_EPOCH=1710000000000

for i in $(seq 1 12); do
    EPOCH=$((BASE_EPOCH + i * 1000))
    if [[ $i -le 6 ]]; then
        TOOL="Bash"
    elif [[ $i -le 9 ]]; then
        TOOL="Read"
    else
        TOOL="Edit"
    fi
    # Pre entry (100ms before post)
    PRE_EPOCH=$((EPOCH - 100))
    printf '{"ts":"%s","epoch_ms":%d,"session_id":"%s","tool_name":"%s","hook_type":"pre","tool_input_summary":"{}"}\n' \
        "$NOW" "$PRE_EPOCH" "$SESSION_ID" "$TOOL" >> "$LOG_FILE"
    # Post entry
    printf '{"ts":"%s","epoch_ms":%d,"session_id":"%s","tool_name":"%s","hook_type":"post","tool_input_summary":"{}"}\n' \
        "$NOW" "$EPOCH" "$SESSION_ID" "$TOOL" >> "$LOG_FILE"
done

OUTPUT=$(run_hook_output)
EXIT_CODE=$(run_hook_exit)

assert_eq "test_full_output_exits_zero" "0" "$EXIT_CODE"
assert_ne "test_full_output_not_empty" "" "$OUTPUT"

# Verify key sections of output
assert_contains "test_output_has_title" "# Session Tool Usage Summary" "$OUTPUT"
assert_contains "test_output_has_session_id" "$SESSION_ID" "$OUTPUT"
assert_contains "test_output_has_total_calls" "**Total tool calls:** 12" "$OUTPUT"
assert_contains "test_output_has_calls_by_tool" "## Calls by Tool" "$OUTPUT"
assert_contains "test_output_has_bash_count" "Bash: 6" "$OUTPUT"
assert_contains "test_output_has_read_count" "Read: 3" "$OUTPUT"
assert_contains "test_output_has_edit_count" "Edit: 3" "$OUTPUT"

# test_tool_logging_summary_no_jq_calls
# Verify the script itself contains no jq calls
JQ_LINES=$(grep -cE '^\s*(check_tool jq|.*\| jq |jq -)' "$HOOK" 2>/dev/null) || JQ_LINES=0
assert_eq "test_no_jq_calls_in_script" "0" "$JQ_LINES"

print_summary
