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

# Helper: assert_eq with verbose PASS output for per-test pass reporting.
assert_eq_verbose() {
    local label="$1" expected="$2" actual="$3"
    local _fail_before=$FAIL
    assert_eq "$label" "$expected" "$actual"
    if [[ "$FAIL" -eq "$_fail_before" ]]; then
        echo "PASS: $label"
    fi
}

# --- test_edit_tickets_tracker_path_blocks ---
# Edit targeting a file inside .tickets-tracker/ must be blocked (exit 2).
INPUT='{"tool_name":"Edit","tool_input":{"file_path":"/repo/.tickets-tracker/event-001.json","old_string":"foo","new_string":"bar"}}'
EXIT_CODE=$(run_guard "$INPUT")
assert_eq_verbose "test_edit_tickets_tracker_path_blocks" "2" "$EXIT_CODE"

# --- test_write_tickets_tracker_path_blocks ---
# Write targeting a file inside .tickets-tracker/ must be blocked (exit 2).
INPUT='{"tool_name":"Write","tool_input":{"file_path":"/repo/.tickets-tracker/event-002.json","content":"{}"}}'
EXIT_CODE=$(run_guard "$INPUT")
assert_eq_verbose "test_write_tickets_tracker_path_blocks" "2" "$EXIT_CODE"

# --- test_edit_non_tickets_tracker_path_allows ---
# Edit targeting a file outside .tickets-tracker/ must be allowed (exit 0).
INPUT='{"tool_name":"Edit","tool_input":{"file_path":"/repo/app/src/main.py","old_string":"foo","new_string":"bar"}}'
EXIT_CODE=$(run_guard "$INPUT")
assert_eq_verbose "test_edit_non_tickets_tracker_path_allows" "0" "$EXIT_CODE"

# --- test_bash_tool_type_allows ---
# Bash tool calls are not handled by the Edit/Write guard — must be allowed (exit 0).
INPUT='{"tool_name":"Bash","tool_input":{"command":"echo hello"}}'
EXIT_CODE=$(run_guard "$INPUT")
assert_eq_verbose "test_bash_tool_type_allows" "0" "$EXIT_CODE"

# --- test_empty_input_allows ---
# Empty input must fail-open (exit 0) — guard must not crash or block.
INPUT=''
EXIT_CODE=$(run_guard "$INPUT")
assert_eq_verbose "test_empty_input_allows" "0" "$EXIT_CODE"

# =============================================================================
# Bash variant tests for hook_tickets_tracker_bash_guard
# =============================================================================
# These tests cover the Bash command variant guard that blocks direct Bash
# commands targeting .tickets-tracker/ event files.
#
# hook_tickets_tracker_bash_guard does not exist yet — these tests MUST FAIL
# (RED state). Task dso-hzwm implements the function; tests go GREEN after
# that task completes.

# Source pre-bash-functions.sh to load all Bash hook functions.
# hook_tickets_tracker_bash_guard is expected there (will fail RED until implemented).
source "$DSO_PLUGIN_DIR/hooks/lib/pre-bash-functions.sh"

# Guard: if hook_tickets_tracker_bash_guard is not yet defined, emit a clear RED
# signal and exit non-zero so the test fails visibly rather than aborting silently.
# Print partial results first so Edit/Write test PASS lines are already emitted.
if ! declare -f hook_tickets_tracker_bash_guard >/dev/null 2>&1; then
    echo "FAIL: hook_tickets_tracker_bash_guard not defined in pre-bash-functions.sh (expected RED — implement in task dso-hzwm)" >&2
    exit 1
fi

# Helper: invoke hook_tickets_tracker_bash_guard with given JSON input; capture exit code.
run_bash_guard() {
    local input="$1"
    local exit_code=0
    hook_tickets_tracker_bash_guard "$input" 2>/dev/null || exit_code=$?
    echo "$exit_code"
}

# --- test_bash_tickets_tracker_reference_blocks ---
# Bash command writing to .tickets-tracker/ must be blocked (exit 2).
INPUT='{"tool_name":"Bash","tool_input":{"command":"echo foo > /repo/.tickets-tracker/event.json"}}'
EXIT_CODE=$(run_bash_guard "$INPUT")
assert_eq_verbose "test_bash_tickets_tracker_reference_blocks" "2" "$EXIT_CODE"

# --- test_bash_ticket_cli_allowlisted ---
# Bash command that is a bare ticket CLI invocation must be allowed (exit 0).
INPUT='{"tool_name":"Bash","tool_input":{"command":"ticket show dso-1234"}}'
EXIT_CODE=$(run_bash_guard "$INPUT")
assert_eq_verbose "test_bash_ticket_cli_allowlisted" "0" "$EXIT_CODE"

# --- test_bash_dso_shim_ticket_comment_allowlisted ---
# Bash command via DSO shim (.claude/scripts/dso ticket comment) must be allowed (exit 0).
INPUT='{"tool_name":"Bash","tool_input":{"command":".claude/scripts/dso ticket comment 4506-e5da \"## Description\""}}'
EXIT_CODE=$(run_bash_guard "$INPUT")
assert_eq_verbose "test_bash_dso_shim_ticket_comment_allowlisted" "0" "$EXIT_CODE"

# --- test_bash_dso_shim_ticket_create_allowlisted ---
# Bash command via DSO shim (.claude/scripts/dso ticket create) must be allowed (exit 0).
INPUT='{"tool_name":"Bash","tool_input":{"command":".claude/scripts/dso ticket create bug \"some title\""}}'
EXIT_CODE=$(run_bash_guard "$INPUT")
assert_eq_verbose "test_bash_dso_shim_ticket_create_allowlisted" "0" "$EXIT_CODE"

# --- test_bash_dso_shim_ticket_transition_allowlisted ---
# Bash command via DSO shim (.claude/scripts/dso ticket transition) must be allowed (exit 0).
INPUT='{"tool_name":"Bash","tool_input":{"command":".claude/scripts/dso ticket transition w21-u3op open in_progress"}}'
EXIT_CODE=$(run_bash_guard "$INPUT")
assert_eq_verbose "test_bash_dso_shim_ticket_transition_allowlisted" "0" "$EXIT_CODE"

# --- test_bash_dso_shim_ticket_list_allowlisted ---
# Bash command via DSO shim (.claude/scripts/dso ticket list) must be allowed (exit 0).
INPUT='{"tool_name":"Bash","tool_input":{"command":".claude/scripts/dso ticket list 2>/dev/null | python3 -c \"...\""}}'
EXIT_CODE=$(run_bash_guard "$INPUT")
assert_eq_verbose "test_bash_dso_shim_ticket_list_allowlisted" "0" "$EXIT_CODE"

# --- test_bash_dso_shim_via_bash_allowlisted ---
# Bash command via "bash .claude/scripts/dso ticket ..." must be allowed (exit 0).
INPUT='{"tool_name":"Bash","tool_input":{"command":"bash .claude/scripts/dso ticket show w21-1234"}}'
EXIT_CODE=$(run_bash_guard "$INPUT")
assert_eq_verbose "test_bash_dso_shim_via_bash_allowlisted" "0" "$EXIT_CODE"

# --- test_bash_embedded_dso_ticket_in_echo_blocks ---
# A command that embeds "/dso ticket" as a string argument (not a real invocation)
# while also referencing .tickets-tracker/ must still be blocked (exit 2).
INPUT='{"tool_name":"Bash","tool_input":{"command":"echo \"/dso ticket\" > /repo/.tickets-tracker/event.json"}}'
EXIT_CODE=$(run_bash_guard "$INPUT")
assert_eq_verbose "test_bash_embedded_dso_ticket_in_echo_blocks" "2" "$EXIT_CODE"

# --- test_bash_no_tickets_tracker_ref_allows ---
# Bash command with no .tickets-tracker/ reference must be allowed (exit 0).
INPUT='{"tool_name":"Bash","tool_input":{"command":"echo hello world"}}'
EXIT_CODE=$(run_bash_guard "$INPUT")
assert_eq_verbose "test_bash_no_tickets_tracker_ref_allows" "0" "$EXIT_CODE"

# --- test_non_bash_tool_type_allows ---
# Non-Bash tool type (Edit) is not handled by the Bash guard — must be allowed (exit 0).
INPUT='{"tool_name":"Edit","tool_input":{"file_path":"/repo/app/src/main.py","old_string":"foo","new_string":"bar"}}'
EXIT_CODE=$(run_bash_guard "$INPUT")
assert_eq_verbose "test_non_bash_tool_type_allows" "0" "$EXIT_CODE"

# --- test_bash_guard_empty_command_allows ---
# Empty command must fail-open (exit 0) — guard must not crash or block.
INPUT='{"tool_name":"Bash","tool_input":{"command":""}}'
EXIT_CODE=$(run_bash_guard "$INPUT")
assert_eq_verbose "test_bash_guard_empty_command_allows" "0" "$EXIT_CODE"

# --- test_bash_echo_tickets_tracker_string_allows ---
# echo with .tickets-tracker/ as string content (no redirect) must be allowed (exit 0).
INPUT='{"tool_name":"Bash","tool_input":{"command":"echo \".tickets-tracker/ is the event log\""}}'
EXIT_CODE=$(run_bash_guard "$INPUT")
assert_eq_verbose "test_bash_echo_tickets_tracker_string_allows" "0" "$EXIT_CODE"

# --- test_bash_heredoc_tickets_tracker_allows ---
# Heredoc containing .tickets-tracker/ in content must be allowed (exit 0).
INPUT='{"tool_name":"Bash","tool_input":{"command":"cat <<'\''EOF'\''\n.tickets-tracker/ docs\nEOF"}}'
EXIT_CODE=$(run_bash_guard "$INPUT")
assert_eq_verbose "test_bash_heredoc_tickets_tracker_allows" "0" "$EXIT_CODE"

# --- test_bash_grep_tickets_tracker_allows ---
# grep command reading from .tickets-tracker/ must be allowed (exit 0).
INPUT='{"tool_name":"Bash","tool_input":{"command":"grep pattern .tickets-tracker/events/"}}'
EXIT_CODE=$(run_bash_guard "$INPUT")
assert_eq_verbose "test_bash_grep_tickets_tracker_allows" "0" "$EXIT_CODE"

# --- test_bash_heredoc_with_redirect_blocks ---
# Heredoc with redirect targeting .tickets-tracker/ must be blocked (exit 2).
# This catches the case where << is present but a redirect also targets the path.
INPUT='{"tool_name":"Bash","tool_input":{"command":"cat << EOF > /repo/.tickets-tracker/event.json\ncontent\nEOF"}}'
EXIT_CODE=$(run_bash_guard "$INPUT")
assert_eq_verbose "test_bash_heredoc_with_redirect_blocks" "2" "$EXIT_CODE"

print_summary
