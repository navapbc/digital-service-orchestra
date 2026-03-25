#!/usr/bin/env bash
# tests/hooks/test-title-length-validator.sh
# Tests for .claude/hooks/title-length-validator.sh — specifically the v2
# .tickets/-only targeting that should be removed.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DSO_PLUGIN_DIR="$PLUGIN_ROOT/plugins/dso"
HOOK="$DSO_PLUGIN_DIR/hooks/title-length-validator.sh"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

# Helper: run hook with given JSON input, return exit code
run_hook() {
    local input="$1"
    local exit_code=0
    echo "$input" | bash "$HOOK" 2>/dev/null || exit_code=$?
    echo "$exit_code"
}

# Build a title string longer than 255 characters
LONG_TITLE=$(python3 -c "print('A' * 256)")

# --- Baseline: .tickets/ path with long title is BLOCKED (exit 2) ---
# Verify the hook works as expected for the existing .tickets/ targeting.
INPUT_TICKETS_LONG=$(printf '{"tool_name":"Write","tool_input":{"file_path":"/repo/.tickets/abc-0001/ticket.md","content":"# %s\nsome content"}}' "$LONG_TITLE")
EXIT_CODE=$(run_hook "$INPUT_TICKETS_LONG")
assert_eq "test_title_validator_blocks_tickets_long_title" "2" "$EXIT_CODE"

# --- Baseline: .tickets/ path with short title exits 0 ---
INPUT_TICKETS_SHORT='{"tool_name":"Write","tool_input":{"file_path":"/repo/.tickets/abc-0001/ticket.md","content":"# Short title\nsome content"}}'
EXIT_CODE=$(run_hook "$INPUT_TICKETS_SHORT")
assert_eq "test_title_validator_allows_tickets_short_title" "0" "$EXIT_CODE"

# --- test_title_validator_no_tickets_v2_skip ---
# RED: a non-.tickets/ file with a long title should ALSO be blocked once the
# v2 .tickets/-only targeting is removed.
#
# Currently, title-length-validator.sh exits 0 immediately for any file path
# that does NOT contain '/.tickets/' (line: if [[ "$FILE_PATH" != *"/.tickets/"* ]]; then exit 0; fi).
# This v2-specific filter means only the old .tickets/ directory is validated.
#
# After removing the v2 path guard, the hook should validate title length in
# any file that contains a markdown H1 title (# ...) — including non-.tickets/
# paths. A Write to a non-.tickets/ file with a 256-char title should BLOCK
# (exit 2). Currently it exits 0, so this test FAILS.
INPUT_OTHER_LONG=$(printf '{"tool_name":"Write","tool_input":{"file_path":"/repo/.tickets-tracker/abc-0001/ticket.md","content":"# %s\nsome content"}}' "$LONG_TITLE")
EXIT_CODE=$(run_hook "$INPUT_OTHER_LONG")
assert_eq "test_title_validator_no_tickets_v2_skip" "2" "$EXIT_CODE"

print_summary
