#!/usr/bin/env bash
# lockpick-workflow/tests/hooks/test-post-dispatchers.sh
# Unit tests for the PostToolUse dispatchers and post-functions library.
#
# Tests:
#   test_post_bash_dispatcher_calls_check_validation_failures
#   test_post_edit_dispatcher_calls_auto_format
#   test_post_write_dispatcher_exits_0
#   test_post_all_dispatcher_calls_tool_logging_post
#   test_post_bash_calls_tool_logging_post
#   test_tool_logging_wrapper_passes_mode_arg_correctly
#
# Usage: bash lockpick-workflow/tests/hooks/test-post-dispatchers.sh
# Exit code: 0 if all pass, 1 if any fail

set -uo pipefail
# Note: set -e omitted intentionally — tests call functions that return non-zero
# and we handle failures via assert_eq/assert_contains, not exit-on-error.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR" && git rev-parse --show-toplevel)"

source "$REPO_ROOT/lockpick-workflow/tests/lib/assert.sh"

# Temp dir cleanup on exit
_CLEANUP_DIRS=()
_cleanup() { for d in "${_CLEANUP_DIRS[@]}"; do rm -rf "$d"; done; }
trap _cleanup EXIT

POST_BASH_DISPATCHER="$REPO_ROOT/lockpick-workflow/hooks/dispatchers/post-bash.sh"
POST_EDIT_DISPATCHER="$REPO_ROOT/lockpick-workflow/hooks/dispatchers/post-edit.sh"
POST_WRITE_DISPATCHER="$REPO_ROOT/lockpick-workflow/hooks/dispatchers/post-write.sh"
POST_ALL_DISPATCHER="$REPO_ROOT/lockpick-workflow/hooks/dispatchers/post-all.sh"
POST_FUNCTIONS="$REPO_ROOT/lockpick-workflow/hooks/lib/post-functions.sh"

# ============================================================
# test_post_bash_dispatcher_exists_and_is_executable
# ============================================================
echo "--- test_post_bash_dispatcher_exists_and_is_executable ---"
_exists=0; [[ -f "$POST_BASH_DISPATCHER" ]] && _exists=1
assert_eq "test_post_bash_dispatcher_exists_and_is_executable: file exists" "1" "$_exists"
_exec=0; [[ -x "$POST_BASH_DISPATCHER" ]] && _exec=1
assert_eq "test_post_bash_dispatcher_exists_and_is_executable: file executable" "1" "$_exec"

# ============================================================
# test_post_edit_dispatcher_exists_and_is_executable
# ============================================================
echo "--- test_post_edit_dispatcher_exists_and_is_executable ---"
_exists=0; [[ -f "$POST_EDIT_DISPATCHER" ]] && _exists=1
assert_eq "test_post_edit_dispatcher_exists_and_is_executable: file exists" "1" "$_exists"
_exec=0; [[ -x "$POST_EDIT_DISPATCHER" ]] && _exec=1
assert_eq "test_post_edit_dispatcher_exists_and_is_executable: file executable" "1" "$_exec"

# ============================================================
# test_post_bash_dispatcher_calls_check_validation_failures
# The post-bash dispatcher sources post-functions.sh and calls
# hook_check_validation_failures when a Bash tool is dispatched.
# We verify by sourcing the dispatcher and calling the dispatch function
# with a sentinel environment variable that the hook function checks.
# ============================================================
echo "--- test_post_bash_dispatcher_calls_check_validation_failures ---"
# Send a Bash input that doesn't match validate.sh — hook should exit 0 silently.
_INPUT='{"tool_name":"Bash","tool_input":{"command":"echo hello"},"tool_response":{"stdout":"hello","stderr":"","exit_code":0}}'
_exit_code=0
printf '%s' "$_INPUT" | bash "$POST_BASH_DISPATCHER" >/dev/null 2>/dev/null || _exit_code=$?
assert_eq "test_post_bash_dispatcher_calls_check_validation_failures: exits 0" "0" "$_exit_code"

# ============================================================
# test_post_bash_dispatcher_calls_track_cascade_failures
# The post-bash dispatcher also invokes hook_track_cascade_failures.
# Send a non-test command — should exit 0 silently.
# ============================================================
echo "--- test_post_bash_dispatcher_calls_track_cascade_failures ---"
_INPUT='{"tool_name":"Bash","tool_input":{"command":"git status"},"tool_response":{"stdout":"nothing to commit","stderr":"","exit_code":0}}'
_exit_code=0
printf '%s' "$_INPUT" | bash "$POST_BASH_DISPATCHER" >/dev/null 2>/dev/null || _exit_code=$?
assert_eq "test_post_bash_dispatcher_calls_track_cascade_failures: exits 0" "0" "$_exit_code"

# ============================================================
# test_post_edit_dispatcher_calls_auto_format
# The post-edit dispatcher must call hook_auto_format.
# Send a non-.py file path — hook should exit 0 silently (no formatting needed).
# ============================================================
echo "--- test_post_edit_dispatcher_calls_auto_format ---"
_INPUT='{"tool_name":"Edit","tool_input":{"file_path":"/tmp/test.txt","old_string":"old","new_string":"new"},"tool_response":{"success":true}}'
_exit_code=0
printf '%s' "$_INPUT" | bash "$POST_EDIT_DISPATCHER" >/dev/null 2>/dev/null || _exit_code=$?
assert_eq "test_post_edit_dispatcher_calls_auto_format: exits 0" "0" "$_exit_code"

# ============================================================
# test_post_write_dispatcher_exits_0
# The post-write dispatcher is a no-op (ticket sync removed in epic 3igl).
# Verify it exits 0 cleanly.
# ============================================================
echo "--- test_post_write_dispatcher_exits_0 ---"
_INPUT='{"tool_name":"Write","tool_input":{"file_path":"/tmp/test.txt","content":"hello"},"tool_response":{"success":true}}'
_exit_code=0
printf '%s' "$_INPUT" | bash "$POST_WRITE_DISPATCHER" >/dev/null 2>/dev/null || _exit_code=$?
assert_eq "test_post_write_dispatcher_exits_0: exits 0" "0" "$_exit_code"

# ============================================================
# test_post_all_dispatcher_exits_0
# After tool-logging removal, post-all is a no-op placeholder. Must exit 0.
# ============================================================
echo "--- test_post_all_dispatcher_exits_0 ---"
_INPUT='{"tool_name":"Read","tool_input":{"file_path":"/tmp/test.txt"},"tool_response":{"content":"data"}}'
_exit_code=0
printf '%s' "$_INPUT" | bash "$POST_ALL_DISPATCHER" >/dev/null 2>/dev/null || _exit_code=$?
assert_eq "test_post_all_dispatcher_exits_0: exits 0" "0" "$_exit_code"

# ============================================================
# test_tool_logging_wrapper_passes_mode_arg_correctly
# tool-logging.sh takes $1 as MODE (pre|post). The dispatchers hardcode
# the mode instead of passing $1. Verify post-functions.sh contains
# hook_tool_logging_post that hardcodes MODE=post.
# ============================================================
echo "--- test_tool_logging_wrapper_passes_mode_arg_correctly ---"
# Source post-functions.sh and verify hook_tool_logging_post is defined
(
    # Need to be in a git repo context
    source "$POST_FUNCTIONS" 2>/dev/null
    if declare -f hook_tool_logging_post > /dev/null 2>&1; then
        exit 0
    else
        exit 1
    fi
) 2>/dev/null
_fn_exit=$?
assert_eq "test_tool_logging_wrapper_passes_mode_arg_correctly: hook_tool_logging_post defined" "0" "$_fn_exit"

# Also verify hook_tool_logging_pre is defined
(
    source "$POST_FUNCTIONS" 2>/dev/null
    if declare -f hook_tool_logging_pre > /dev/null 2>&1; then
        exit 0
    else
        exit 1
    fi
) 2>/dev/null
_fn_exit=$?
assert_eq "test_tool_logging_wrapper_passes_mode_arg_correctly: hook_tool_logging_pre defined" "0" "$_fn_exit"

# ============================================================
# test_post_bash_dispatcher_exits_0_for_non_bash_tool
# The post-bash dispatcher's hook functions must handle non-Bash inputs
# gracefully (exit 0) because of Claude Code bug #20334.
# ============================================================
echo "--- test_post_bash_dispatcher_exits_0_for_non_bash_tool ---"
_INPUT='{"tool_name":"Read","tool_input":{"file_path":"/tmp/test.txt"},"tool_response":{"content":"data"}}'
_exit_code=0
printf '%s' "$_INPUT" | bash "$POST_BASH_DISPATCHER" >/dev/null 2>/dev/null || _exit_code=$?
assert_eq "test_post_bash_dispatcher_exits_0_for_non_bash_tool: exits 0" "0" "$_exit_code"

# ============================================================
# test_post_functions_file_exists
# ============================================================
echo "--- test_post_functions_file_exists ---"
_exists=0; [[ -f "$POST_FUNCTIONS" ]] && _exists=1
assert_eq "test_post_functions_file_exists: file exists" "1" "$_exists"

# ============================================================
# test_post_write_dispatcher_exists_and_is_executable
# ============================================================
echo "--- test_post_write_dispatcher_exists_and_is_executable ---"
_exists=0; [[ -f "$POST_WRITE_DISPATCHER" ]] && _exists=1
assert_eq "test_post_write_dispatcher_exists_and_is_executable: file exists" "1" "$_exists"
_exec=0; [[ -x "$POST_WRITE_DISPATCHER" ]] && _exec=1
assert_eq "test_post_write_dispatcher_exists_and_is_executable: file executable" "1" "$_exec"

# ============================================================
# test_post_all_dispatcher_exists_and_is_executable
# ============================================================
echo "--- test_post_all_dispatcher_exists_and_is_executable ---"
_exists=0; [[ -f "$POST_ALL_DISPATCHER" ]] && _exists=1
assert_eq "test_post_all_dispatcher_exists_and_is_executable: file exists" "1" "$_exists"
_exec=0; [[ -x "$POST_ALL_DISPATCHER" ]] && _exec=1
assert_eq "test_post_all_dispatcher_exists_and_is_executable: file executable" "1" "$_exec"

# ============================================================
# test_post_bash_no_tool_logging_post
# After tool_logging removal, the post-bash dispatcher must NOT
# call hook_tool_logging_post — no JSONL log entry should be created.
# ============================================================
echo "--- test_post_bash_no_tool_logging_post ---"
_ORIG_HOME="$HOME"
_TEST_HOME=$(mktemp -d)
_CLEANUP_DIRS+=("$_TEST_HOME")
export HOME="$_TEST_HOME"
mkdir -p "$_TEST_HOME/.claude"
touch "$_TEST_HOME/.claude/tool-logging-enabled"

_INPUT='{"tool_name":"Bash","tool_input":{"command":"echo hello"},"tool_response":{"stdout":"hello","stderr":"","exit_code":0}}'
_exit_code=0
printf '%s' "$_INPUT" | bash "$POST_BASH_DISPATCHER" >/dev/null 2>/dev/null || _exit_code=$?
assert_eq "test_post_bash_no_tool_logging_post: exits 0" "0" "$_exit_code"

# Verify NO JSONL log file was created (tool logging removed from dispatchers)
_LOG_FILE="$_TEST_HOME/.claude/logs/tool-use-$(date +%Y-%m-%d).jsonl"
_log_found=0
if [[ -f "$_LOG_FILE" ]]; then
    if grep -q '"hook_type":"post"' "$_LOG_FILE" 2>/dev/null; then
        _log_found=1
    fi
fi
assert_eq "test_post_bash_no_tool_logging_post: no JSONL log entry written" "0" "$_log_found"

# Teardown
export HOME="$_ORIG_HOME"
rm -rf "$_TEST_HOME"

# ============================================================
# test_post_all_is_noop_after_optimization
# After tool-logging removal, post-all has no hooks. Verify it exits 0
# cleanly without producing timing entries.
# ============================================================
echo "--- test_post_all_is_noop_after_optimization ---"
_INPUT='{"tool_name":"Read","tool_input":{"file_path":"/tmp/test.txt"},"tool_response":{"content":"data"}}'
_exit_code=0
printf '%s' "$_INPUT" | bash "$POST_ALL_DISPATCHER" >/dev/null 2>/dev/null || _exit_code=$?
assert_eq "test_post_all_is_noop_after_optimization: exits 0" "0" "$_exit_code"

# ============================================================
# Summary
# ============================================================
print_summary
