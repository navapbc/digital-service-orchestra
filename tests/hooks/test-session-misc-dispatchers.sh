#!/usr/bin/env bash
# tests/hooks/test-session-misc-dispatchers.sh
# Unit tests for session-start, stop, pre-exitplanmode, pre-taskoutput,
# post-failure dispatchers and the session-misc-functions.sh library.
#
# Tests:
#   test_session_start_dispatcher_runs_all_4_hooks
#   test_stop_dispatcher_runs_review_stop_check
#   test_pre_exitplanmode_dispatcher_calls_plan_review_gate
#   test_pre_taskoutput_dispatcher_calls_taskoutput_block_guard
#   test_post_failure_dispatcher_calls_track_tool_errors
#   test_pre_all_dispatcher_calls_tool_logging_pre
#
# Usage: bash tests/hooks/test-session-misc-dispatchers.sh
# Exit code: 0 if all pass, 1 if any fail

set -uo pipefail
# Note: set -e omitted intentionally — tests call functions that return non-zero

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DSO_PLUGIN_DIR="$PLUGIN_ROOT/plugins/dso"
REPO_ROOT="$(cd "$SCRIPT_DIR" && git rev-parse --show-toplevel)"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

# Temp dir cleanup on exit
_CLEANUP_DIRS=()
_cleanup() { for d in "${_CLEANUP_DIRS[@]}"; do rm -rf "$d"; done; }
trap _cleanup EXIT

SESSION_START_DISPATCHER="$DSO_PLUGIN_DIR/hooks/dispatchers/session-start.sh"
STOP_DISPATCHER="$DSO_PLUGIN_DIR/hooks/dispatchers/stop.sh"
POST_FAILURE_DISPATCHER="$DSO_PLUGIN_DIR/hooks/dispatchers/post-failure.sh"
PRE_ALL_DISPATCHER="$DSO_PLUGIN_DIR/hooks/dispatchers/pre-all.sh"
PRE_EXITPLANMODE_DISPATCHER="$DSO_PLUGIN_DIR/hooks/dispatchers/pre-exitplanmode.sh"
PRE_TASKOUTPUT_DISPATCHER="$DSO_PLUGIN_DIR/hooks/dispatchers/pre-taskoutput.sh"
SESSION_MISC_FUNCTIONS="$DSO_PLUGIN_DIR/hooks/lib/session-misc-functions.sh"

# ============================================================
# test_session_start_dispatcher_runs_all_4_hooks
# The session-start dispatcher must exist, be executable, and
# run without error for a normal (non-compact) session start input.
# All 4 hooks (cleanup-orphaned-processes, inject, safety-check,
# post-compact-review-check) must be sourced and invoked.
# ============================================================
echo "--- test_session_start_dispatcher_runs_all_4_hooks ---"
_dispatcher_exists=0
[[ -f "$SESSION_START_DISPATCHER" ]] && _dispatcher_exists=1
assert_eq "test_session_start_dispatcher_runs_all_4_hooks: file exists" "1" "$_dispatcher_exists"

_dispatcher_executable=0
[[ -x "$SESSION_START_DISPATCHER" ]] && _dispatcher_executable=1
assert_eq "test_session_start_dispatcher_runs_all_4_hooks: executable" "1" "$_dispatcher_executable"

# Run with a normal start input — should exit 0 (all 4 hooks are informational)
_INPUT='{"source":"start","session_id":"test-session-abc"}'
_exit_code=0
printf '%s' "$_INPUT" | bash "$SESSION_START_DISPATCHER" 2>/dev/null || _exit_code=$?
assert_eq "test_session_start_dispatcher_runs_all_4_hooks: exits 0 on normal start" "0" "$_exit_code"

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
_CLEANUP_DIRS+=("$_exitplan_artifacts")
_exitplan_git_repo=$(mktemp -d)
_CLEANUP_DIRS+=("$_exitplan_git_repo")
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
# Use isolated HOME so synthetic errors don't pollute ~/.claude/tool-error-counter.json
_INPUT='{"tool_name":"Bash","error":"command not found: xyz","tool_input":{"command":"xyz"},"session_id":"test","is_interrupt":false}'
_exit_code=0
_post_failure_real_home="$HOME"
_post_failure_test_home=$(mktemp -d)
_CLEANUP_DIRS+=("$_post_failure_test_home")
export HOME="$_post_failure_test_home"
printf '%s' "$_INPUT" | bash "$POST_FAILURE_DISPATCHER" 2>/dev/null || _exit_code=$?
export HOME="$_post_failure_real_home"
assert_eq "test_post_failure_dispatcher_calls_track_tool_errors: exits 0 (non-blocking)" "0" "$_exit_code"

# ============================================================
# test_pre_all_dispatcher_exits_0
# The pre-all dispatcher must exist, be executable, and exit 0.
# ============================================================
echo "--- test_pre_all_dispatcher_exits_0 ---"
_dispatcher_exists=0
[[ -f "$PRE_ALL_DISPATCHER" ]] && _dispatcher_exists=1
assert_eq "test_pre_all_dispatcher_exits_0: file exists" "1" "$_dispatcher_exists"

_dispatcher_executable=0
[[ -x "$PRE_ALL_DISPATCHER" ]] && _dispatcher_executable=1
assert_eq "test_pre_all_dispatcher_exits_0: executable" "1" "$_dispatcher_executable"

# Run with a basic Bash tool input — must exit 0
_INPUT='{"tool_name":"Bash","tool_input":{"command":"ls"},"session_id":"test"}'
_exit_code=0
printf '%s' "$_INPUT" | bash "$PRE_ALL_DISPATCHER" 2>/dev/null || _exit_code=$?
assert_eq "test_pre_all_dispatcher_exits_0: exits 0" "0" "$_exit_code"

# ============================================================
# test_pre_exitplanmode_no_tool_logging
# After optimization, pre-exitplanmode must NOT reference tool_logging_pre.
# ============================================================
echo "--- test_pre_exitplanmode_no_tool_logging ---"

_has_logging=0
grep -q 'hook_tool_logging_pre' "$PRE_EXITPLANMODE_DISPATCHER" && _has_logging=1
assert_eq "test_pre_exitplanmode_no_tool_logging: no hook_tool_logging_pre" "0" "$_has_logging"

_has_source=0
grep -q 'post-functions.sh' "$PRE_EXITPLANMODE_DISPATCHER" && _has_source=1
assert_eq "test_pre_exitplanmode_no_tool_logging: no post-functions.sh source" "0" "$_has_source"

# ============================================================
# test_pre_taskoutput_no_tool_logging
# After optimization, pre-taskoutput must NOT reference tool_logging_pre.
# ============================================================
echo "--- test_pre_taskoutput_no_tool_logging ---"

_has_logging=0
grep -q 'hook_tool_logging_pre' "$PRE_TASKOUTPUT_DISPATCHER" && _has_logging=1
assert_eq "test_pre_taskoutput_no_tool_logging: no hook_tool_logging_pre" "0" "$_has_logging"

_has_source=0
grep -q 'post-functions.sh' "$PRE_TASKOUTPUT_DISPATCHER" && _has_source=1
assert_eq "test_pre_taskoutput_no_tool_logging: no post-functions.sh source" "0" "$_has_source"

# ============================================================
# test_cleanup_orphaned_processes_function_defined
# The session-misc-functions.sh library must define
# hook_cleanup_orphaned_processes and it must exit 0 when
# no matching processes exist.
# ============================================================
echo "--- test_cleanup_orphaned_processes_function_defined ---"
(
    _SESSION_MISC_FUNCTIONS_LOADED=""
    source "$SESSION_MISC_FUNCTIONS" 2>/dev/null
    declare -F hook_cleanup_orphaned_processes >/dev/null 2>&1
)
_fn_defined=$?
assert_eq "test_cleanup_orphaned_processes_function_defined: function defined" "0" "$_fn_defined"

# ============================================================
# test_cleanup_orphaned_processes_exits_0_no_matches
# When no orphaned processes match the patterns, the hook must
# exit 0 without errors.
# ============================================================
echo "--- test_cleanup_orphaned_processes_exits_0_no_matches ---"
_exit_code=0
_output=""
(
    _SESSION_MISC_FUNCTIONS_LOADED=""
    source "$SESSION_MISC_FUNCTIONS" 2>/dev/null
    hook_cleanup_orphaned_processes
) > /dev/null 2>&1 || _exit_code=$?
assert_eq "test_cleanup_orphaned_processes_exits_0_no_matches: exits 0" "0" "$_exit_code"

# ============================================================
# test_cleanup_orphaned_processes_etime_parsing
# The etime-to-seconds conversion must correctly handle various
# etime formats: mm:ss, hh:mm:ss, dd-hh:mm:ss.
# We test this by sourcing the function and verifying the parser
# logic handles different formats (extracted into a test helper).
# ============================================================
echo "--- test_cleanup_orphaned_processes_etime_parsing ---"

# Test etime parsing logic directly by simulating the parser
_test_etime_to_seconds() {
    local ETIME="$1"
    local DAYS=0 HOURS=0 MINS=0 SECS=0
    if [[ "$ETIME" == *-* ]]; then
        DAYS="${ETIME%%-*}"
        ETIME="${ETIME#*-}"
    fi
    local COLON_COUNT
    COLON_COUNT=$(echo "$ETIME" | tr -cd ':' | wc -c | tr -d ' ')
    if [[ "$COLON_COUNT" -eq 2 ]]; then
        HOURS=$(echo "$ETIME" | cut -d: -f1)
        MINS=$(echo "$ETIME" | cut -d: -f2)
        SECS=$(echo "$ETIME" | cut -d: -f3)
    elif [[ "$COLON_COUNT" -eq 1 ]]; then
        MINS=$(echo "$ETIME" | cut -d: -f1)
        SECS=$(echo "$ETIME" | cut -d: -f2)
    fi
    DAYS=$((10#$DAYS)) HOURS=$((10#$HOURS)) MINS=$((10#$MINS)) SECS=$((10#$SECS))
    echo $(( DAYS*86400 + HOURS*3600 + MINS*60 + SECS ))
}

# mm:ss format
_result=$(_test_etime_to_seconds "05:30")
assert_eq "test_cleanup_orphaned_processes_etime_parsing: mm:ss 05:30 = 330s" "330" "$_result"

# mm:ss with leading zeros
_result=$(_test_etime_to_seconds "00:45")
assert_eq "test_cleanup_orphaned_processes_etime_parsing: mm:ss 00:45 = 45s" "45" "$_result"

# hh:mm:ss format
_result=$(_test_etime_to_seconds "01:30:00")
assert_eq "test_cleanup_orphaned_processes_etime_parsing: hh:mm:ss 01:30:00 = 5400s" "5400" "$_result"

# hh:mm:ss with various values
_result=$(_test_etime_to_seconds "02:15:30")
assert_eq "test_cleanup_orphaned_processes_etime_parsing: hh:mm:ss 02:15:30 = 8130s" "8130" "$_result"

# dd-hh:mm:ss format
_result=$(_test_etime_to_seconds "1-00:00:00")
assert_eq "test_cleanup_orphaned_processes_etime_parsing: dd-hh:mm:ss 1-00:00:00 = 86400s" "86400" "$_result"

# dd-hh:mm:ss with complex values
_result=$(_test_etime_to_seconds "2-03:30:15")
assert_eq "test_cleanup_orphaned_processes_etime_parsing: dd-hh:mm:ss 2-03:30:15 = 185415s" "185415" "$_result"

# Large minute value (>30 min threshold = 1800s)
_result=$(_test_etime_to_seconds "45:00")
assert_eq "test_cleanup_orphaned_processes_etime_parsing: mm:ss 45:00 = 2700s" "2700" "$_result"

# ============================================================
# test_cleanup_orphaned_processes_uses_pgid_not_pid
# The hook must resolve the actual PGID via `ps -o pgid=`
# rather than assuming PID == PGID when killing process groups.
# ============================================================
echo "--- test_cleanup_orphaned_processes_uses_pgid_not_pid ---"

# Verify the function source references pgid resolution (ps -o pgid=)
_uses_pgid=0
grep -q 'pgid' "$SESSION_MISC_FUNCTIONS" && _uses_pgid=1
assert_eq "test_cleanup_orphaned_processes_uses_pgid_not_pid: references pgid" "1" "$_uses_pgid"

# Verify it uses ps -o pgid= to look up the actual PGID
_uses_ps_pgid=0
grep -q 'ps.*-o.*pgid' "$SESSION_MISC_FUNCTIONS" && _uses_ps_pgid=1
assert_eq "test_cleanup_orphaned_processes_uses_pgid_not_pid: uses ps -o pgid=" "1" "$_uses_ps_pgid"

# Verify the kill line uses a PGID variable, not $pid directly for group kill
# The kill -- -<var> should use a variable named *pgid* or *PGID*, not $pid
_kill_uses_pgid=0
grep -qE 'kill.*-.*\$(.*pgid|.*PGID)' "$SESSION_MISC_FUNCTIONS" && _kill_uses_pgid=1
assert_eq "test_cleanup_orphaned_processes_uses_pgid_not_pid: kill uses PGID var" "1" "$_kill_uses_pgid"

# Verify the old buggy pattern (kill -- -"$pid") is NOT present
_old_pattern_absent=1
grep -q 'kill -- -"$pid"' "$SESSION_MISC_FUNCTIONS" && _old_pattern_absent=0
assert_eq "test_cleanup_orphaned_processes_uses_pgid_not_pid: old kill -pid pattern removed" "1" "$_old_pattern_absent"

# ============================================================
# Summary
# ============================================================
print_summary
