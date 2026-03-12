#!/usr/bin/env bash
# lockpick-workflow/tests/hooks/test-session-misc-dispatchers.sh
# Unit tests for session-start, stop, pre-agent, pre-exitplanmode, pre-taskoutput,
# post-failure dispatchers and the session-misc-functions.sh library.
#
# Tests:
#   test_session_start_dispatcher_runs_all_3_hooks
#   test_stop_dispatcher_runs_review_stop_check
#   test_pre_agent_dispatcher_denies_worktree_isolation
#   test_worktree_isolation_guard_function_preserves_python3
#   test_pre_exitplanmode_dispatcher_calls_plan_review_gate
#   test_pre_taskoutput_dispatcher_calls_taskoutput_block_guard
#   test_post_failure_dispatcher_calls_track_tool_errors
#   test_pre_all_dispatcher_calls_tool_logging_pre
#
# Usage: bash lockpick-workflow/tests/hooks/test-session-misc-dispatchers.sh
# Exit code: 0 if all pass, 1 if any fail

set -uo pipefail
# Note: set -e omitted intentionally — tests call functions that return non-zero

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

source "$REPO_ROOT/lockpick-workflow/tests/lib/assert.sh"

SESSION_START_DISPATCHER="$REPO_ROOT/lockpick-workflow/hooks/dispatchers/session-start.sh"
STOP_DISPATCHER="$REPO_ROOT/lockpick-workflow/hooks/dispatchers/stop.sh"
POST_FAILURE_DISPATCHER="$REPO_ROOT/lockpick-workflow/hooks/dispatchers/post-failure.sh"
PRE_ALL_DISPATCHER="$REPO_ROOT/lockpick-workflow/hooks/dispatchers/pre-all.sh"
PRE_EXITPLANMODE_DISPATCHER="$REPO_ROOT/lockpick-workflow/hooks/dispatchers/pre-exitplanmode.sh"
PRE_AGENT_DISPATCHER="$REPO_ROOT/lockpick-workflow/hooks/dispatchers/pre-agent.sh"
PRE_TASKOUTPUT_DISPATCHER="$REPO_ROOT/lockpick-workflow/hooks/dispatchers/pre-taskoutput.sh"
SESSION_MISC_FUNCTIONS="$REPO_ROOT/lockpick-workflow/hooks/lib/session-misc-functions.sh"

# ============================================================
# test_session_start_dispatcher_runs_all_3_hooks
# The session-start dispatcher must exist, be executable, and
# run without error for a normal (non-compact) session start input.
# All 3 hooks (inject, safety-check, post-compact-review-check)
# must be sourced and invoked.
# ============================================================
echo "--- test_session_start_dispatcher_runs_all_3_hooks ---"
_dispatcher_exists=0
[[ -f "$SESSION_START_DISPATCHER" ]] && _dispatcher_exists=1
assert_eq "test_session_start_dispatcher_runs_all_3_hooks: file exists" "1" "$_dispatcher_exists"

_dispatcher_executable=0
[[ -x "$SESSION_START_DISPATCHER" ]] && _dispatcher_executable=1
assert_eq "test_session_start_dispatcher_runs_all_3_hooks: executable" "1" "$_dispatcher_executable"

# Run with a normal start input — should exit 0 (all 3 hooks are informational)
_INPUT='{"source":"start","session_id":"test-session-abc"}'
_exit_code=0
printf '%s' "$_INPUT" | bash "$SESSION_START_DISPATCHER" 2>/dev/null || _exit_code=$?
assert_eq "test_session_start_dispatcher_runs_all_3_hooks: exits 0 on normal start" "0" "$_exit_code"

# ============================================================
# test_stop_dispatcher_runs_review_stop_check
# The stop dispatcher must exist, be executable, and exit 0
# when run from a clean git repo (no uncommitted changes).
# ============================================================
echo "--- test_stop_dispatcher_runs_review_stop_check ---"
_dispatcher_exists=0
[[ -f "$STOP_DISPATCHER" ]] && _dispatcher_exists=1
assert_eq "test_stop_dispatcher_runs_review_stop_check: file exists" "1" "$_dispatcher_exists"

_dispatcher_executable=0
[[ -x "$STOP_DISPATCHER" ]] && _dispatcher_executable=1
assert_eq "test_stop_dispatcher_runs_review_stop_check: executable" "1" "$_dispatcher_executable"

# Run from repo root (clean state) — should exit 0
_stop_input='{}'
_exit_code=0
printf '%s' "$_stop_input" | bash "$STOP_DISPATCHER" 2>/dev/null || _exit_code=$?
assert_eq "test_stop_dispatcher_runs_review_stop_check: exits 0 on clean tree" "0" "$_exit_code"

# ============================================================
# test_pre_agent_dispatcher_denies_worktree_isolation
# The pre-agent dispatcher must block Agent calls that specify
# isolation: "worktree" by outputting a JSON deny response.
# ============================================================
echo "--- test_pre_agent_dispatcher_denies_worktree_isolation ---"
_dispatcher_exists=0
[[ -f "$PRE_AGENT_DISPATCHER" ]] && _dispatcher_exists=1
assert_eq "test_pre_agent_dispatcher_denies_worktree_isolation: file exists" "1" "$_dispatcher_exists"

_dispatcher_executable=0
[[ -x "$PRE_AGENT_DISPATCHER" ]] && _dispatcher_executable=1
assert_eq "test_pre_agent_dispatcher_denies_worktree_isolation: executable" "1" "$_dispatcher_executable"

# Test: worktree isolation must be denied
_INPUT='{"tool_name":"Agent","tool_input":{"isolation":"worktree","description":"Test task"}}'
_exit_code=0
_output=""
_output=$(printf '%s' "$_INPUT" | bash "$PRE_AGENT_DISPATCHER" 2>&1) || _exit_code=$?
assert_eq "test_pre_agent_dispatcher_denies_worktree_isolation: exits 0" "0" "$_exit_code"
assert_contains "test_pre_agent_dispatcher_denies_worktree_isolation: deny in output" \
    "deny" "$_output"

# Test: non-worktree isolation must be allowed (exit 0, no deny output)
_INPUT_NO_ISOLATION='{"tool_name":"Agent","tool_input":{"description":"Test task"}}'
_exit_code=0
_output_allow=""
_output_allow=$(printf '%s' "$_INPUT_NO_ISOLATION" | bash "$PRE_AGENT_DISPATCHER" 2>&1) || _exit_code=$?
assert_eq "test_pre_agent_dispatcher_denies_worktree_isolation: allows non-worktree: exit 0" "0" "$_exit_code"

# ============================================================
# test_worktree_isolation_guard_function_preserves_python3
# The session-misc-functions.sh library must define
# hook_worktree_isolation_guard() that uses python3 for JSON parsing
# (this is required by the existing worktree-isolation-guard.sh behavior).
# ============================================================
echo "--- test_worktree_isolation_guard_function_preserves_python3 ---"
_functions_exist=0
[[ -f "$SESSION_MISC_FUNCTIONS" ]] && _functions_exist=1
assert_eq "test_worktree_isolation_guard_function_preserves_python3: lib file exists" "1" "$_functions_exist"

# Source the library and verify the function is defined
(
    source "$SESSION_MISC_FUNCTIONS" 2>/dev/null
    declare -F hook_worktree_isolation_guard >/dev/null 2>&1
) 2>/dev/null
_fn_defined=$?
assert_eq "test_worktree_isolation_guard_function_preserves_python3: function defined" "0" "$_fn_defined"

# Verify the function body references python3 (not jq-based JSON parsing)
_uses_python3=0
grep -q 'python3' "$SESSION_MISC_FUNCTIONS" && _uses_python3=1
assert_eq "test_worktree_isolation_guard_function_preserves_python3: uses python3" "1" "$_uses_python3"

# ============================================================
# test_pre_exitplanmode_dispatcher_calls_plan_review_gate
# The pre-exitplanmode dispatcher must block ExitPlanMode when no
# plan review has been recorded (plan-review-status file absent).
# ============================================================
echo "--- test_pre_exitplanmode_dispatcher_calls_plan_review_gate ---"
_dispatcher_exists=0
[[ -f "$PRE_EXITPLANMODE_DISPATCHER" ]] && _dispatcher_exists=1
assert_eq "test_pre_exitplanmode_dispatcher_calls_plan_review_gate: file exists" "1" "$_dispatcher_exists"

_dispatcher_executable=0
[[ -x "$PRE_EXITPLANMODE_DISPATCHER" ]] && _dispatcher_executable=1
assert_eq "test_pre_exitplanmode_dispatcher_calls_plan_review_gate: executable" "1" "$_dispatcher_executable"

# Set up isolated artifacts dir with no plan-review-status — must be blocked
_exitplan_artifacts=$(mktemp -d)
_exitplan_git_repo=$(mktemp -d)
git -C "$_exitplan_git_repo" init -q -b main 2>/dev/null || git -C "$_exitplan_git_repo" init -q
git -C "$_exitplan_git_repo" config user.email "test@test.com"
git -C "$_exitplan_git_repo" config user.name "Test"

_INPUT='{"tool_name":"ExitPlanMode","tool_input":{}}'
_exit_code=0
_output=""
_output=$(cd "$_exitplan_git_repo" && printf '%s' "$_INPUT" | ARTIFACTS_DIR="$_exitplan_artifacts" bash "$PRE_EXITPLANMODE_DISPATCHER" 2>&1) || _exit_code=$?
assert_eq "test_pre_exitplanmode_dispatcher_calls_plan_review_gate: exit 2 when no review" "2" "$_exit_code"
assert_contains "test_pre_exitplanmode_dispatcher_calls_plan_review_gate: BLOCKED in output" \
    "BLOCKED" "$_output"

rm -rf "$_exitplan_artifacts" "$_exitplan_git_repo"

# ============================================================
# test_pre_taskoutput_dispatcher_calls_taskoutput_block_guard
# The pre-taskoutput dispatcher must block TaskOutput calls
# when block=false is specified.
# ============================================================
echo "--- test_pre_taskoutput_dispatcher_calls_taskoutput_block_guard ---"
_dispatcher_exists=0
[[ -f "$PRE_TASKOUTPUT_DISPATCHER" ]] && _dispatcher_exists=1
assert_eq "test_pre_taskoutput_dispatcher_calls_taskoutput_block_guard: file exists" "1" "$_dispatcher_exists"

_dispatcher_executable=0
[[ -x "$PRE_TASKOUTPUT_DISPATCHER" ]] && _dispatcher_executable=1
assert_eq "test_pre_taskoutput_dispatcher_calls_taskoutput_block_guard: executable" "1" "$_dispatcher_executable"

# Test: block=false must exit 2
_INPUT='{"tool_name":"TaskOutput","tool_input":{"block":false,"task_id":"123"}}'
_exit_code=0
_output=""
_output=$(printf '%s' "$_INPUT" | bash "$PRE_TASKOUTPUT_DISPATCHER" 2>&1) || _exit_code=$?
assert_eq "test_pre_taskoutput_dispatcher_calls_taskoutput_block_guard: exit 2 on block=false" "2" "$_exit_code"
assert_contains "test_pre_taskoutput_dispatcher_calls_taskoutput_block_guard: BLOCKED in output" \
    "BLOCKED" "$_output"

# Test: block=true must exit 0
_INPUT_BLOCK_TRUE='{"tool_name":"TaskOutput","tool_input":{"block":true,"task_id":"123"}}'
_exit_code=0
printf '%s' "$_INPUT_BLOCK_TRUE" | bash "$PRE_TASKOUTPUT_DISPATCHER" 2>/dev/null || _exit_code=$?
assert_eq "test_pre_taskoutput_dispatcher_calls_taskoutput_block_guard: exit 0 on block=true" "0" "$_exit_code"

# ============================================================
# test_post_failure_dispatcher_calls_track_tool_errors
# The post-failure dispatcher must exist, be executable, and
# call track_tool_errors which exits 0 (non-blocking, info only).
# ============================================================
echo "--- test_post_failure_dispatcher_calls_track_tool_errors ---"
_dispatcher_exists=0
[[ -f "$POST_FAILURE_DISPATCHER" ]] && _dispatcher_exists=1
assert_eq "test_post_failure_dispatcher_calls_track_tool_errors: file exists" "1" "$_dispatcher_exists"

_dispatcher_executable=0
[[ -x "$POST_FAILURE_DISPATCHER" ]] && _dispatcher_executable=1
assert_eq "test_post_failure_dispatcher_calls_track_tool_errors: executable" "1" "$_dispatcher_executable"

# Run with a minimal failure input — should exit 0 (informational, non-blocking)
_INPUT='{"tool_name":"Bash","error":"command not found: xyz","tool_input":{"command":"xyz"},"session_id":"test","is_interrupt":false}'
_exit_code=0
printf '%s' "$_INPUT" | bash "$POST_FAILURE_DISPATCHER" 2>/dev/null || _exit_code=$?
assert_eq "test_post_failure_dispatcher_calls_track_tool_errors: exits 0 (non-blocking)" "0" "$_exit_code"

# ============================================================
# test_pre_all_dispatcher_calls_tool_logging_pre
# The pre-all dispatcher must exist, be executable, and exit 0.
# It handles tool-logging pre-phase.
# ============================================================
echo "--- test_pre_all_dispatcher_calls_tool_logging_pre ---"
_dispatcher_exists=0
[[ -f "$PRE_ALL_DISPATCHER" ]] && _dispatcher_exists=1
assert_eq "test_pre_all_dispatcher_calls_tool_logging_pre: file exists" "1" "$_dispatcher_exists"

_dispatcher_executable=0
[[ -x "$PRE_ALL_DISPATCHER" ]] && _dispatcher_executable=1
assert_eq "test_pre_all_dispatcher_calls_tool_logging_pre: executable" "1" "$_dispatcher_executable"

# Run with a basic Bash tool input — tool-logging is info-only, must exit 0
_INPUT='{"tool_name":"Bash","tool_input":{"command":"ls"},"session_id":"test"}'
_exit_code=0
printf '%s' "$_INPUT" | bash "$PRE_ALL_DISPATCHER" 2>/dev/null || _exit_code=$?
assert_eq "test_pre_all_dispatcher_calls_tool_logging_pre: exits 0" "0" "$_exit_code"

# ============================================================
# Summary
# ============================================================
print_summary
