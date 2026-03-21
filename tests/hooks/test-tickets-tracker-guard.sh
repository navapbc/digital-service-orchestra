#!/usr/bin/env bash
# tests/hooks/test-tickets-tracker-guard.sh
# RED tests for hook_tickets_tracker_guard (Edit/Write blocking for .tickets-tracker/).
#
# hook_tickets_tracker_guard does not exist yet — these tests MUST FAIL (RED state).
# Task dso-4cb7 implements the function; tests go GREEN after that task completes.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DSO_PLUGIN_DIR="$PLUGIN_ROOT/plugins/dso"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

# Source pre-edit-write-functions.sh to load all Edit/Write hook functions.
# hook_tickets_tracker_guard is expected there (will fail RED until implemented).
source "$DSO_PLUGIN_DIR/hooks/lib/pre-edit-write-functions.sh"

# Guard: if hook_tickets_tracker_guard is not yet defined, emit a clear RED signal
# and exit non-zero so the test fails visibly rather than aborting silently on
# the first run_guard call with "command not found".
if ! declare -f hook_tickets_tracker_guard >/dev/null 2>&1; then
    echo "FAIL: hook_tickets_tracker_guard not defined in pre-edit-write-functions.sh (expected RED — implement in task dso-4cb7)" >&2
    exit 1
fi

# Helper: invoke hook_tickets_tracker_guard with given JSON input; capture exit code.
run_guard() {
    local input="$1"
    local exit_code=0
    hook_tickets_tracker_guard "$input" 2>/dev/null || exit_code=$?
    echo "$exit_code"
}

# --- test_edit_tickets_tracker_path_blocks ---
# Edit targeting a file inside .tickets-tracker/ must be blocked (exit 2).
INPUT='{"tool_name":"Edit","tool_input":{"file_path":"/repo/.tickets-tracker/event-001.json","old_string":"foo","new_string":"bar"}}'
EXIT_CODE=$(run_guard "$INPUT")
assert_eq "test_edit_tickets_tracker_path_blocks" "2" "$EXIT_CODE"

# --- test_write_tickets_tracker_path_blocks ---
# Write targeting a file inside .tickets-tracker/ must be blocked (exit 2).
INPUT='{"tool_name":"Write","tool_input":{"file_path":"/repo/.tickets-tracker/event-002.json","content":"{}"}}'
EXIT_CODE=$(run_guard "$INPUT")
assert_eq "test_write_tickets_tracker_path_blocks" "2" "$EXIT_CODE"

# --- test_edit_non_tickets_tracker_path_allows ---
# Edit targeting a file outside .tickets-tracker/ must be allowed (exit 0).
INPUT='{"tool_name":"Edit","tool_input":{"file_path":"/repo/app/src/main.py","old_string":"foo","new_string":"bar"}}'
EXIT_CODE=$(run_guard "$INPUT")
assert_eq "test_edit_non_tickets_tracker_path_allows" "0" "$EXIT_CODE"

# --- test_bash_tool_type_allows ---
# Bash tool calls are not handled by the Edit/Write guard — must be allowed (exit 0).
INPUT='{"tool_name":"Bash","tool_input":{"command":"echo hello"}}'
EXIT_CODE=$(run_guard "$INPUT")
assert_eq "test_bash_tool_type_allows" "0" "$EXIT_CODE"

# --- test_empty_input_allows ---
# Empty input must fail-open (exit 0) — guard must not crash or block.
INPUT=''
EXIT_CODE=$(run_guard "$INPUT")
assert_eq "test_empty_input_allows" "0" "$EXIT_CODE"

print_summary
