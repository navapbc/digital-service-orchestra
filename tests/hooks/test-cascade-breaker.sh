#!/usr/bin/env bash
# tests/hooks/test-cascade-breaker.sh
# Tests for .claude/hooks/cascade-circuit-breaker.sh
#
# cascade-circuit-breaker.sh is a PreToolUse hook that blocks Edit/Write
# when the cascade failure counter reaches >= 5.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DSO_PLUGIN_DIR="$PLUGIN_ROOT/plugins/dso"
REPO_ROOT="$(git rev-parse --show-toplevel)"
HOOK="$DSO_PLUGIN_DIR/hooks/cascade-circuit-breaker.sh"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

# --- Test isolation: unique fake git repo root per test run ---
# The hook computes STATE_DIR by hashing `git rev-parse --show-toplevel`.
# Using a unique fake root ensures this test's counter file never collides
# with the real repo's cascade counter or with parallel test runs.
FAKE_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/test-cascade-breaker-XXXXXX")
trap 'rm -rf "$FAKE_ROOT"' EXIT

# Init a minimal git repo in FAKE_ROOT so git rev-parse works inside it
git init -q "$FAKE_ROOT"

# Resolve to real path — on macOS, mktemp returns /var/folders/... but
# git rev-parse --show-toplevel resolves symlinks to /private/var/folders/...
# The hash must be computed from the same path the hook will see.
FAKE_ROOT=$(cd "$FAKE_ROOT" && git rev-parse --show-toplevel)

# Compute the hash the hook will compute for FAKE_ROOT (matches hook logic)
if command -v md5 &>/dev/null; then
    WT_HASH=$(echo -n "$FAKE_ROOT" | md5)
elif command -v md5sum &>/dev/null; then
    WT_HASH=$(echo -n "$FAKE_ROOT" | md5sum | cut -d' ' -f1)
else
    WT_HASH=$(echo -n "$FAKE_ROOT" | tr '/' '_')
fi
STATE_DIR="/tmp/claude-cascade-${WT_HASH}"
COUNTER_FILE="$STATE_DIR/counter"

# Helper: run hook with given input from within FAKE_ROOT so the hook's
# `git rev-parse --show-toplevel` returns FAKE_ROOT → unique STATE_DIR
run_hook() {
    local input="$1"
    local exit_code=0
    (cd "$FAKE_ROOT" && echo "$input" | bash "$HOOK" 2>/dev/null) || exit_code=$?
    echo "$exit_code"
}

# Ensure no leftover counter from a previous (interrupted) run
rm -rf "$STATE_DIR" 2>/dev/null || true

# --- test_cascade_breaker_exits_zero_on_count_below_threshold ---
# No counter file present → no cascade → exit 0
INPUT='{"tool_name":"Edit","tool_input":{"file_path":"'"$FAKE_ROOT"'/app/src/test.py"}}'
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
INPUT='{"tool_name":"Edit","tool_input":{"file_path":"'"$FAKE_ROOT"'/app/src/test.py"}}'
EXIT_CODE=$(run_hook "$INPUT")
assert_eq "test_cascade_breaker_exits_zero_on_counter_below_5" "0" "$EXIT_CODE"

# --- test_cascade_breaker_blocks_at_threshold ---
# Counter=5 should block (exit 2)
echo "5" > "$COUNTER_FILE"
INPUT='{"tool_name":"Edit","tool_input":{"file_path":"'"$FAKE_ROOT"'/app/src/test.py"}}'
EXIT_CODE=$(run_hook "$INPUT")
assert_eq "test_cascade_breaker_blocks_at_threshold" "2" "$EXIT_CODE"

# --- test_cascade_breaker_blocks_above_threshold ---
# Counter=10 should block (exit 2)
echo "10" > "$COUNTER_FILE"
INPUT='{"tool_name":"Edit","tool_input":{"file_path":"'"$FAKE_ROOT"'/app/src/test.py"}}'
EXIT_CODE=$(run_hook "$INPUT")
assert_eq "test_cascade_breaker_blocks_above_threshold" "2" "$EXIT_CODE"

# --- test_cascade_breaker_allows_tickets_edit_at_threshold ---
# .tickets/ files are exempt even at threshold
echo "10" > "$COUNTER_FILE"
INPUT='{"tool_name":"Edit","tool_input":{"file_path":"'"$FAKE_ROOT"'/.tickets/test.md"}}'
EXIT_CODE=$(run_hook "$INPUT")
assert_eq "test_cascade_breaker_allows_tickets_edit_at_threshold" "0" "$EXIT_CODE"

# --- test_cascade_breaker_allows_claude_config_at_threshold ---
# .claude/ files are exempt even at threshold
echo "10" > "$COUNTER_FILE"
INPUT='{"tool_name":"Edit","tool_input":{"file_path":"'"$FAKE_ROOT"'/.claude/hooks/test.sh"}}'
EXIT_CODE=$(run_hook "$INPUT")
assert_eq "test_cascade_breaker_allows_claude_config_at_threshold" "0" "$EXIT_CODE"

# --- test_cascade_breaker_allows_tmp_files_at_threshold ---
# /tmp/ files are exempt
echo "10" > "$COUNTER_FILE"
INPUT='{"tool_name":"Edit","tool_input":{"file_path":"/tmp/test.py"}}'
EXIT_CODE=$(run_hook "$INPUT")
assert_eq "test_cascade_breaker_allows_tmp_files_at_threshold" "0" "$EXIT_CODE"

# --- Dump ERR trap log if any failures occurred ---
_ERR_LOG="/tmp/cascade-circuit-breaker-err.log"
if [[ -f "$_ERR_LOG" ]]; then
    echo "=== ERR trap log (cascade-circuit-breaker.sh) ===" >&2
    cat "$_ERR_LOG" >&2
    echo "=== end ERR trap log ===" >&2
    rm -f "$_ERR_LOG"
fi

# --- Cleanup ---
rm -rf "$STATE_DIR" 2>/dev/null || true
# FAKE_ROOT is removed by the EXIT trap above

print_summary
