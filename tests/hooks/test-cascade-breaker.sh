#!/usr/bin/env bash
# lockpick-workflow/tests/hooks/test-cascade-breaker.sh
# Tests for .claude/hooks/cascade-circuit-breaker.sh
#
# cascade-circuit-breaker.sh is a PreToolUse hook that blocks Edit/Write
# when the cascade failure counter reaches >= 5.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
REPO_ROOT="$(git rev-parse --show-toplevel)"
HOOK="$PLUGIN_ROOT/hooks/cascade-circuit-breaker.sh"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

# Compute the same hash the hook would compute for this worktree
if command -v md5 &>/dev/null; then
    WT_HASH=$(echo -n "$REPO_ROOT" | md5)
elif command -v md5sum &>/dev/null; then
    WT_HASH=$(echo -n "$REPO_ROOT" | md5sum | cut -d' ' -f1)
else
    WT_HASH=$(echo -n "$REPO_ROOT" | tr '/' '_')
fi
STATE_DIR="/tmp/claude-cascade-${WT_HASH}"
COUNTER_FILE="$STATE_DIR/counter"

# Helper: run hook with given input, return exit code
run_hook() {
    local input="$1"
    local exit_code=0
    echo "$input" | bash "$HOOK" 2>/dev/null || exit_code=$?
    echo "$exit_code"
}

# --- test_cascade_breaker_exits_zero_on_count_below_threshold ---
# No counter file present → no cascade → exit 0
rm -f "$COUNTER_FILE" 2>/dev/null || true
INPUT='{"tool_name":"Edit","tool_input":{"file_path":"'"$REPO_ROOT"'/app/src/test.py"}}'
EXIT_CODE=$(run_hook "$INPUT")
assert_eq "test_cascade_breaker_exits_zero_on_count_below_threshold" "0" "$EXIT_CODE"

# --- test_cascade_breaker_exits_zero_on_non_edit_tool ---
# Bash tool should always pass through (hook only guards Edit/Write)
INPUT='{"tool_name":"Bash","tool_input":{"command":"echo test"}}'
EXIT_CODE=$(run_hook "$INPUT")
assert_eq "test_cascade_breaker_exits_zero_on_non_edit_tool" "0" "$EXIT_CODE"

# --- test_cascade_breaker_exits_zero_on_counter_below_5 ---
# Counter=4 should not block
mkdir -p "$STATE_DIR"
echo "4" > "$COUNTER_FILE"
INPUT='{"tool_name":"Edit","tool_input":{"file_path":"'"$REPO_ROOT"'/app/src/test.py"}}'
EXIT_CODE=$(run_hook "$INPUT")
assert_eq "test_cascade_breaker_exits_zero_on_counter_below_5" "0" "$EXIT_CODE"

# --- test_cascade_breaker_blocks_at_threshold ---
# Counter=5 should block (exit 2)
echo "5" > "$COUNTER_FILE"
INPUT='{"tool_name":"Edit","tool_input":{"file_path":"'"$REPO_ROOT"'/app/src/test.py"}}'
EXIT_CODE=$(run_hook "$INPUT")
assert_eq "test_cascade_breaker_blocks_at_threshold" "2" "$EXIT_CODE"

# --- test_cascade_breaker_blocks_above_threshold ---
# Counter=10 should block (exit 2)
echo "10" > "$COUNTER_FILE"
INPUT='{"tool_name":"Edit","tool_input":{"file_path":"'"$REPO_ROOT"'/app/src/test.py"}}'
EXIT_CODE=$(run_hook "$INPUT")
assert_eq "test_cascade_breaker_blocks_above_threshold" "2" "$EXIT_CODE"

# --- test_cascade_breaker_allows_tickets_edit_at_threshold ---
# .tickets/ files are exempt even at threshold
echo "10" > "$COUNTER_FILE"
INPUT='{"tool_name":"Edit","tool_input":{"file_path":"'"$REPO_ROOT"'/.tickets/test.md"}}'
EXIT_CODE=$(run_hook "$INPUT")
assert_eq "test_cascade_breaker_allows_tickets_edit_at_threshold" "0" "$EXIT_CODE"

# --- test_cascade_breaker_allows_claude_config_at_threshold ---
# .claude/ files are exempt even at threshold
echo "10" > "$COUNTER_FILE"
INPUT='{"tool_name":"Edit","tool_input":{"file_path":"'"$REPO_ROOT"'/.claude/hooks/test.sh"}}'
EXIT_CODE=$(run_hook "$INPUT")
assert_eq "test_cascade_breaker_allows_claude_config_at_threshold" "0" "$EXIT_CODE"

# --- test_cascade_breaker_allows_tmp_files_at_threshold ---
# /tmp/ files are exempt
echo "10" > "$COUNTER_FILE"
INPUT='{"tool_name":"Edit","tool_input":{"file_path":"/tmp/test.py"}}'
EXIT_CODE=$(run_hook "$INPUT")
assert_eq "test_cascade_breaker_allows_tmp_files_at_threshold" "0" "$EXIT_CODE"

# --- Cleanup ---
rm -f "$COUNTER_FILE" 2>/dev/null || true

print_summary
