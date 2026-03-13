#!/usr/bin/env bash
# lockpick-workflow/tests/hooks/test-pre-edit-write-dispatcher.sh
# Unit tests for the pre-edit and pre-write dispatchers and the functions they source.
#
# Tests:
#   test_pre_edit_dispatcher_exits_2_when_cascade_breaker_triggers
#   test_pre_edit_dispatcher_title_length_blocks_over_255_chars
#   test_pre_write_dispatcher_sources_same_functions_as_edit
#   test_pre_edit_dispatcher_exits_0_for_allowed_edit
#   test_pre_write_dispatcher_exits_0_for_allowed_write
#   test_pre_edit_dispatcher_exits_2_worktree_edit_guard_blocks_main_repo
#   test_pre_edit_write_functions_loaded_via_lib_file
#
# Usage: bash lockpick-workflow/tests/hooks/test-pre-edit-write-dispatcher.sh
# Exit code: 0 if all pass, 1 if any fail

set -uo pipefail
# Note: set -e omitted intentionally — tests call functions that return non-zero
# and we handle failures via assert_eq/assert_contains, not exit-on-error.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

source "$REPO_ROOT/lockpick-workflow/tests/lib/assert.sh"

PRE_EDIT_DISPATCHER="$REPO_ROOT/lockpick-workflow/hooks/dispatchers/pre-edit.sh"
PRE_WRITE_DISPATCHER="$REPO_ROOT/lockpick-workflow/hooks/dispatchers/pre-write.sh"
FUNCTIONS_LIB="$REPO_ROOT/lockpick-workflow/hooks/lib/pre-edit-write-functions.sh"

# ============================================================
# Helper: compute cascade state dir (same hash logic as cascade-circuit-breaker)
# ============================================================
if command -v md5 &>/dev/null; then
    _WT_HASH=$(echo -n "$REPO_ROOT" | md5)
elif command -v md5sum &>/dev/null; then
    _WT_HASH=$(echo -n "$REPO_ROOT" | md5sum | cut -d' ' -f1)
else
    _WT_HASH=$(echo -n "$REPO_ROOT" | tr '/' '_')
fi
_CASCADE_STATE_DIR="/tmp/claude-cascade-${_WT_HASH}"
_CASCADE_COUNTER_FILE="$_CASCADE_STATE_DIR/counter"

# ============================================================
# test_pre_edit_dispatcher_exits_2_when_cascade_breaker_triggers
# When the cascade counter reaches >= 5 and a non-exempt file is edited,
# the pre-edit dispatcher must exit 2 (blocked by cascade-circuit-breaker).
# ============================================================
echo "--- test_pre_edit_dispatcher_exits_2_when_cascade_breaker_triggers ---"

# Set cascade counter to 5 (threshold)
mkdir -p "$_CASCADE_STATE_DIR"
echo "5" > "$_CASCADE_COUNTER_FILE"

_INPUT='{"tool_name":"Edit","tool_input":{"file_path":"'"$REPO_ROOT"'/app/src/some_module.py","old_string":"old","new_string":"new"}}'
_exit_code=0
_output=""
_output=$(printf '%s' "$_INPUT" | bash "$PRE_EDIT_DISPATCHER" 2>&1) || _exit_code=$?
assert_eq "test_pre_edit_dispatcher_exits_2_when_cascade_breaker_triggers: exit 2" "2" "$_exit_code"
assert_contains "test_pre_edit_dispatcher_exits_2_when_cascade_breaker_triggers: BLOCKED in output" \
    "BLOCKED" "$_output"

# Cleanup cascade counter
rm -f "$_CASCADE_COUNTER_FILE" 2>/dev/null || true

# ============================================================
# test_pre_edit_dispatcher_title_length_blocks_over_255_chars
# When editing a .tickets/ file with a title > 255 chars, the dispatcher
# must exit 2 (blocked by title-length-validator).
# ============================================================
echo "--- test_pre_edit_dispatcher_title_length_blocks_over_255_chars ---"

# Generate a title exactly 256 characters long (1 over the 255 limit)
_long_title=$(printf '%-256s' 'A' | tr ' ' 'A')
_tickets_path="$REPO_ROOT/.tickets/test-ticket-123.md"
_INPUT='{"tool_name":"Edit","tool_input":{"file_path":"'"$_tickets_path"'","old_string":"# Short title","new_string":"# '"$_long_title"'"}}'
_exit_code=0
_output=""
_output=$(printf '%s' "$_INPUT" | bash "$PRE_EDIT_DISPATCHER" 2>&1) || _exit_code=$?
assert_eq "test_pre_edit_dispatcher_title_length_blocks_over_255_chars: exit 2" "2" "$_exit_code"
assert_contains "test_pre_edit_dispatcher_title_length_blocks_over_255_chars: BLOCKED in output" \
    "BLOCKED" "$_output"

# ============================================================
# test_pre_write_dispatcher_sources_same_functions_as_edit
# The pre-write dispatcher must source the same function library as pre-edit.
# Both dispatchers should block the same conditions (e.g., title length).
# ============================================================
echo "--- test_pre_write_dispatcher_sources_same_functions_as_edit ---"

# Test that pre-write also blocks title > 255 chars on .tickets/ write
_long_title2=$(printf '%-256s' 'B' | tr ' ' 'B')
_tickets_path2="$REPO_ROOT/.tickets/test-write-ticket.md"
_write_content="# ${_long_title2}

Some content."
_INPUT='{"tool_name":"Write","tool_input":{"file_path":"'"$_tickets_path2"'","content":"# '"$_long_title2"'\n\nSome content."}}'
_exit_code=0
_output=""
_output=$(printf '%s' "$_INPUT" | bash "$PRE_WRITE_DISPATCHER" 2>&1) || _exit_code=$?
assert_eq "test_pre_write_dispatcher_sources_same_functions_as_edit: exit 2" "2" "$_exit_code"
assert_contains "test_pre_write_dispatcher_sources_same_functions_as_edit: BLOCKED in output" \
    "BLOCKED" "$_output"

# ============================================================
# test_pre_edit_dispatcher_exits_0_for_allowed_edit
# A normal Edit to a non-ticket, non-cascade-blocked file must exit 0.
# ============================================================
echo "--- test_pre_edit_dispatcher_exits_0_for_allowed_edit ---"

# Ensure cascade counter is below threshold (or absent)
rm -f "$_CASCADE_COUNTER_FILE" 2>/dev/null || true

_INPUT='{"tool_name":"Edit","tool_input":{"file_path":"'"$REPO_ROOT"'/app/src/some_module.py","old_string":"old","new_string":"new"}}'
_exit_code=0
printf '%s' "$_INPUT" | bash "$PRE_EDIT_DISPATCHER" 2>/dev/null || _exit_code=$?
assert_eq "test_pre_edit_dispatcher_exits_0_for_allowed_edit" "0" "$_exit_code"

# ============================================================
# test_pre_write_dispatcher_exits_0_for_allowed_write
# A normal Write to a non-ticket file must exit 0.
# ============================================================
echo "--- test_pre_write_dispatcher_exits_0_for_allowed_write ---"

_INPUT='{"tool_name":"Write","tool_input":{"file_path":"'"$REPO_ROOT"'/app/src/output.py","content":"print(\"hello\")"}}'
_exit_code=0
printf '%s' "$_INPUT" | bash "$PRE_WRITE_DISPATCHER" 2>/dev/null || _exit_code=$?
assert_eq "test_pre_write_dispatcher_exits_0_for_allowed_write" "0" "$_exit_code"

# ============================================================
# test_pre_edit_dispatcher_exits_2_worktree_edit_guard_blocks_main_repo
# When editing via the hook functions, validation_gate and worktree_edit_guard
# are sourced from the same library. Verify the functions file is sourceable
# and that both hook_cascade_circuit_breaker and hook_title_length_validator
# are defined after sourcing.
# ============================================================
echo "--- test_pre_edit_write_functions_loaded_via_lib_file ---"

_fns_loaded=0
(
    source "$FUNCTIONS_LIB"
    type hook_cascade_circuit_breaker &>/dev/null && \
    type hook_title_length_validator &>/dev/null && \
    type hook_validation_gate &>/dev/null && \
    type hook_worktree_edit_guard &>/dev/null
) 2>/dev/null && _fns_loaded=1
assert_eq "test_pre_edit_write_functions_loaded_via_lib_file: all 4 functions defined" "1" "$_fns_loaded"

# ============================================================
# test_pre_edit_dispatcher_cascade_exempt_allows_tickets
# Even at cascade threshold, editing .tickets/ files is allowed.
# ============================================================
echo "--- test_pre_edit_dispatcher_cascade_exempt_allows_tickets ---"

# Set cascade counter to 10 (well above threshold)
mkdir -p "$_CASCADE_STATE_DIR"
echo "10" > "$_CASCADE_COUNTER_FILE"

_INPUT='{"tool_name":"Edit","tool_input":{"file_path":"'"$REPO_ROOT"'/.tickets/some-ticket.md","old_string":"old","new_string":"new"}}'
_exit_code=0
printf '%s' "$_INPUT" | bash "$PRE_EDIT_DISPATCHER" 2>/dev/null || _exit_code=$?
assert_eq "test_pre_edit_dispatcher_cascade_exempt_allows_tickets" "0" "$_exit_code"

# Cleanup cascade counter
rm -f "$_CASCADE_COUNTER_FILE" 2>/dev/null || true

# ============================================================
# test_pre_write_dispatcher_cascade_blocks_non_exempt_at_threshold
# The pre-write dispatcher also enforces cascade circuit breaker.
# ============================================================
echo "--- test_pre_write_dispatcher_cascade_blocks_non_exempt_at_threshold ---"

mkdir -p "$_CASCADE_STATE_DIR"
echo "5" > "$_CASCADE_COUNTER_FILE"

_INPUT='{"tool_name":"Write","tool_input":{"file_path":"'"$REPO_ROOT"'/app/src/some_new_file.py","content":"print(\"hello\")"}}'
_exit_code=0
_output=""
_output=$(printf '%s' "$_INPUT" | bash "$PRE_WRITE_DISPATCHER" 2>&1) || _exit_code=$?
assert_eq "test_pre_write_dispatcher_cascade_blocks_non_exempt_at_threshold: exit 2" "2" "$_exit_code"
assert_contains "test_pre_write_dispatcher_cascade_blocks_non_exempt_at_threshold: BLOCKED in output" \
    "BLOCKED" "$_output"

# Final cleanup
rm -f "$_CASCADE_COUNTER_FILE" 2>/dev/null || true

# ============================================================
# test_pre_edit_calls_tool_logging_pre
# The pre-edit dispatcher must source post-functions.sh and call
# hook_tool_logging_pre before the guard hooks.
# ============================================================
echo "--- test_pre_edit_calls_tool_logging_pre ---"

# Verify the dispatcher file contains the hook_tool_logging_pre call
_has_logging=0
grep -q 'hook_tool_logging_pre' "$PRE_EDIT_DISPATCHER" && _has_logging=1
assert_eq "test_pre_edit_calls_tool_logging_pre: grep finds hook_tool_logging_pre" "1" "$_has_logging"

# Verify the dispatcher sources post-functions.sh (which defines hook_tool_logging_pre)
_has_source=0
grep -q 'post-functions.sh' "$PRE_EDIT_DISPATCHER" && _has_source=1
assert_eq "test_pre_edit_calls_tool_logging_pre: sources post-functions.sh" "1" "$_has_source"

# Verify dispatcher still exits 0 for a normal edit (tool logging is non-blocking)
rm -f "$_CASCADE_COUNTER_FILE" 2>/dev/null || true
_INPUT='{"tool_name":"Edit","tool_input":{"file_path":"'"$REPO_ROOT"'/app/src/some_module.py","old_string":"old","new_string":"new"}}'
_exit_code=0
printf '%s' "$_INPUT" | bash "$PRE_EDIT_DISPATCHER" 2>/dev/null || _exit_code=$?
assert_eq "test_pre_edit_calls_tool_logging_pre: exits 0 (non-blocking)" "0" "$_exit_code"

# ============================================================
# test_pre_write_calls_tool_logging_pre
# The pre-write dispatcher must source post-functions.sh and call
# hook_tool_logging_pre before the guard hooks.
# ============================================================
echo "--- test_pre_write_calls_tool_logging_pre ---"

_has_logging=0
grep -q 'hook_tool_logging_pre' "$PRE_WRITE_DISPATCHER" && _has_logging=1
assert_eq "test_pre_write_calls_tool_logging_pre: grep finds hook_tool_logging_pre" "1" "$_has_logging"

_has_source=0
grep -q 'post-functions.sh' "$PRE_WRITE_DISPATCHER" && _has_source=1
assert_eq "test_pre_write_calls_tool_logging_pre: sources post-functions.sh" "1" "$_has_source"

# Verify dispatcher still exits 0 for a normal write
_INPUT='{"tool_name":"Write","tool_input":{"file_path":"'"$REPO_ROOT"'/app/src/output.py","content":"print(\"hello\")"}}'
_exit_code=0
printf '%s' "$_INPUT" | bash "$PRE_WRITE_DISPATCHER" 2>/dev/null || _exit_code=$?
assert_eq "test_pre_write_calls_tool_logging_pre: exits 0 (non-blocking)" "0" "$_exit_code"

# ============================================================
# test_post_edit_calls_tool_logging_post
# The post-edit dispatcher must call hook_tool_logging_post.
# ============================================================
echo "--- test_post_edit_calls_tool_logging_post ---"

POST_EDIT_DISPATCHER="$REPO_ROOT/lockpick-workflow/hooks/dispatchers/post-edit.sh"
_has_logging=0
grep -q 'hook_tool_logging_post' "$POST_EDIT_DISPATCHER" && _has_logging=1
assert_eq "test_post_edit_calls_tool_logging_post: grep finds hook_tool_logging_post" "1" "$_has_logging"

# Verify exits 0 (non-blocking)
_INPUT='{"tool_name":"Edit","tool_input":{"file_path":"/tmp/test.txt","old_string":"old","new_string":"new"},"tool_response":{"success":true}}'
_exit_code=0
printf '%s' "$_INPUT" | bash "$POST_EDIT_DISPATCHER" >/dev/null 2>/dev/null || _exit_code=$?
assert_eq "test_post_edit_calls_tool_logging_post: exits 0" "0" "$_exit_code"

# ============================================================
# test_post_write_calls_tool_logging_post
# The post-write dispatcher must call hook_tool_logging_post.
# ============================================================
echo "--- test_post_write_calls_tool_logging_post ---"

POST_WRITE_DISPATCHER="$REPO_ROOT/lockpick-workflow/hooks/dispatchers/post-write.sh"
_has_logging=0
grep -q 'hook_tool_logging_post' "$POST_WRITE_DISPATCHER" && _has_logging=1
assert_eq "test_post_write_calls_tool_logging_post: grep finds hook_tool_logging_post" "1" "$_has_logging"

# Verify exits 0 (non-blocking)
_INPUT='{"tool_name":"Write","tool_input":{"file_path":"/tmp/test.txt","content":"hello"},"tool_response":{"success":true}}'
_exit_code=0
printf '%s' "$_INPUT" | bash "$POST_WRITE_DISPATCHER" >/dev/null 2>/dev/null || _exit_code=$?
assert_eq "test_post_write_calls_tool_logging_post: exits 0" "0" "$_exit_code"

# ============================================================
# Summary
# ============================================================
print_summary
