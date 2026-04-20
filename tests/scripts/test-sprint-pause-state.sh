#!/usr/bin/env bash
# tests/scripts/test-sprint-pause-state.sh
# Behavioral tests for sprint-pause-state.sh (SIGURG recovery pause-state mechanism).
#
# Usage: bash tests/scripts/test-sprint-pause-state.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SCRIPT="$PLUGIN_ROOT/plugins/dso/scripts/sprint-pause-state.sh"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

echo "=== test-sprint-pause-state.sh ==="

# Shared temp dir — each test can set SPRINT_PAUSE_STATE_DIR to override /tmp
SPRINT_PAUSE_STATE_DIR=$(mktemp -d)
export SPRINT_PAUSE_STATE_DIR

# Cleanup on exit
trap 'rm -rf "$SPRINT_PAUSE_STATE_DIR"' EXIT

# ── test_spause_script_exists_and_executable ─────────────────────────────────
_snapshot_fail
_exists=0
_executable=0
if test -f "$SCRIPT"; then _exists=1; fi
if test -x "$SCRIPT"; then _executable=1; fi
assert_eq "test_spause_script_exists_and_executable: script must exist" "1" "$_exists"
assert_eq "test_spause_script_exists_and_executable: script must be executable" "1" "$_executable"
assert_pass_if_clean "test_spause_script_exists_and_executable"

# ── test_spause_init_creates_state_file ──────────────────────────────────────
_snapshot_fail
_state_file="$SPRINT_PAUSE_STATE_DIR/sprint-pause-state-test-epic-42.json"
rm -f "$_state_file"
bash "$SCRIPT" init test-epic-42 2>/dev/null
_file_exists=0
_has_epic_id=0
_has_stories=0
_has_story_answers=0
_has_in_progress=0
_has_created_at=0
if test -f "$_state_file"; then
    _file_exists=1
    if command -v jq >/dev/null 2>&1; then
        jq -e '.epic_id'          "$_state_file" >/dev/null 2>&1 && _has_epic_id=1
        jq -e '.stories'          "$_state_file" >/dev/null 2>&1 && _has_stories=1
        jq -e '.story_answers'    "$_state_file" >/dev/null 2>&1 && _has_story_answers=1
        jq -e 'has("in_progress_marker")' "$_state_file" >/dev/null 2>&1 && _has_in_progress=1
        jq -e '.created_at'       "$_state_file" >/dev/null 2>&1 && _has_created_at=1
    fi
fi
assert_eq "test_spause_init_creates_state_file: state file must exist after init" "1" "$_file_exists"
assert_eq "test_spause_init_creates_state_file: epic_id field must be present" "1" "$_has_epic_id"
assert_eq "test_spause_init_creates_state_file: stories field must be present" "1" "$_has_stories"
assert_eq "test_spause_init_creates_state_file: story_answers field must be present" "1" "$_has_story_answers"
assert_eq "test_spause_init_creates_state_file: in_progress_marker field must be present" "1" "$_has_in_progress"
assert_eq "test_spause_init_creates_state_file: created_at field must be present" "1" "$_has_created_at"
assert_pass_if_clean "test_spause_init_creates_state_file"

# ── test_spause_write_updates_story_answers ───────────────────────────────────
_snapshot_fail
_state_file="$SPRINT_PAUSE_STATE_DIR/sprint-pause-state-test-epic-42.json"
rm -f "$_state_file"
bash "$SCRIPT" init test-epic-42 2>/dev/null
bash "$SCRIPT" write test-epic-42 st-001 "done" 2>/dev/null
_answer=""
if test -f "$_state_file" && command -v jq >/dev/null 2>&1; then
    _answer=$(jq -r '.story_answers["st-001"] // ""' "$_state_file" 2>/dev/null)
fi
assert_eq "test_spause_write_updates_story_answers: story_answers.st-001 must equal 'done'" "done" "$_answer"
assert_pass_if_clean "test_spause_write_updates_story_answers"

# ── test_spause_read_returns_json ─────────────────────────────────────────────
_snapshot_fail
_state_file="$SPRINT_PAUSE_STATE_DIR/sprint-pause-state-test-epic-42.json"
rm -f "$_state_file"
bash "$SCRIPT" init test-epic-42 2>/dev/null
_read_exit=0
_output=$(bash "$SCRIPT" read test-epic-42 2>/dev/null) || _read_exit=$?
_is_json=0
# Script must exist AND run successfully AND produce parseable JSON with an epic_id field
if [[ "$_read_exit" -eq 0 && -n "$_output" ]] && command -v jq >/dev/null 2>&1 && echo "$_output" | jq -e '.epic_id' >/dev/null 2>&1; then
    _is_json=1
fi
assert_eq "test_spause_read_returns_json: output of 'read' must be parseable JSON with epic_id" "1" "$_is_json"
assert_pass_if_clean "test_spause_read_returns_json"

# ── test_spause_is_fresh_absent_returns_nonzero ───────────────────────────────
_snapshot_fail
_state_file="$SPRINT_PAUSE_STATE_DIR/sprint-pause-state-test-epic-42.json"
rm -f "$_state_file"
# The script must exist for is-fresh to be meaningful.  Assert script presence first.
_script_present=0
if test -f "$SCRIPT"; then _script_present=1; fi
assert_eq "test_spause_is_fresh_absent_returns_nonzero: script must exist before is-fresh can be tested" "1" "$_script_present"
if [[ "$_script_present" -eq 1 ]]; then
    bash "$SCRIPT" is-fresh test-epic-42 2>/dev/null
    _exit_code=$?
    _is_nonzero=0
    if [[ "$_exit_code" -ne 0 ]]; then _is_nonzero=1; fi
    assert_eq "test_spause_is_fresh_absent_returns_nonzero: is-fresh with no state file must exit non-zero" "1" "$_is_nonzero"
fi
assert_pass_if_clean "test_spause_is_fresh_absent_returns_nonzero"

# ── test_spause_is_fresh_fresh_returns_zero ───────────────────────────────────
_snapshot_fail
_state_file="$SPRINT_PAUSE_STATE_DIR/sprint-pause-state-test-epic-42.json"
rm -f "$_state_file"
bash "$SCRIPT" init test-epic-42 2>/dev/null
bash "$SCRIPT" is-fresh test-epic-42 2>/dev/null
_exit_code=$?
_is_zero=0
if [[ "$_exit_code" -eq 0 ]]; then _is_zero=1; fi
assert_eq "test_spause_is_fresh_fresh_returns_zero: is-fresh after init must exit 0" "1" "$_is_zero"
assert_pass_if_clean "test_spause_is_fresh_fresh_returns_zero"

# ── test_spause_is_fresh_stale_returns_nonzero ────────────────────────────────
_snapshot_fail
_state_file="$SPRINT_PAUSE_STATE_DIR/sprint-pause-state-test-epic-42.json"
rm -f "$_state_file"
bash "$SCRIPT" init test-epic-42 2>/dev/null
# Set mtime to 5 hours ago (older than 240-min TTL) using Python for portability
python3 -c "import os,time; t=time.time()-5*3600; os.utime('$_state_file',(t,t))" 2>/dev/null || true
bash "$SCRIPT" is-fresh test-epic-42 2>/dev/null
_exit_code=$?
_is_nonzero=0
if [[ "$_exit_code" -ne 0 ]]; then _is_nonzero=1; fi
assert_eq "test_spause_is_fresh_stale_returns_nonzero: is-fresh on 5h-old file must exit non-zero" "1" "$_is_nonzero"
assert_pass_if_clean "test_spause_is_fresh_stale_returns_nonzero"

# ── test_spause_cleanup_removes_file ─────────────────────────────────────────
_snapshot_fail
_state_file="$SPRINT_PAUSE_STATE_DIR/sprint-pause-state-test-epic-42.json"
rm -f "$_state_file"
bash "$SCRIPT" init test-epic-42 2>/dev/null
bash "$SCRIPT" cleanup test-epic-42 2>/dev/null
_cleanup_exit=$?
_file_gone=0
if ! test -f "$_state_file"; then _file_gone=1; fi
assert_eq "test_spause_cleanup_removes_file: cleanup must exit 0" "0" "$_cleanup_exit"
assert_eq "test_spause_cleanup_removes_file: state file must be removed after cleanup" "1" "$_file_gone"
assert_pass_if_clean "test_spause_cleanup_removes_file"

# ── test_spause_stale_cleanup_removes_old_files ───────────────────────────────
_snapshot_fail
# Create a fake state file with mtime >4h ago (4h = 240 minutes)
_stale_file="$SPRINT_PAUSE_STATE_DIR/sprint-pause-state-stale-epic-99.json"
echo '{"epic_id":"stale-epic-99","stories":[],"story_answers":{},"in_progress_marker":false,"created_at":"old"}' > "$_stale_file"
# Set mtime to 5 hours ago using Python for cross-platform portability
python3 -c "import os,time; t=time.time()-5*3600; os.utime('$_stale_file',(t,t))" 2>/dev/null || true
bash "$SCRIPT" stale-cleanup 2>/dev/null
_stale_gone=0
if ! test -f "$_stale_file"; then _stale_gone=1; fi
assert_eq "test_spause_stale_cleanup_removes_old_files: stale state file must be removed by stale-cleanup" "1" "$_stale_gone"
assert_pass_if_clean "test_spause_stale_cleanup_removes_old_files"

# ── test_spause_sigurg_handler_sets_recoverable_state ────────────────────────
_snapshot_fail
_state_file="$SPRINT_PAUSE_STATE_DIR/sprint-pause-state-test-epic-42.json"
rm -f "$_state_file"
# Source the script to get access to internal function _spause_sigurg_handler
# (will fail if script does not exist)
bash "$SCRIPT" init test-epic-42 2>/dev/null
# Use a subshell to source and call the handler
_handler_result=$(
    # shellcheck source=/dev/null
    source "$SCRIPT" 2>/dev/null
    _spause_sigurg_handler "test-epic-42" 2>/dev/null
    echo "sourced_ok"
)
_sourced=0
if [[ "$_handler_result" == *"sourced_ok"* ]]; then _sourced=1; fi
_in_progress_false=0
if test -f "$_state_file" && command -v jq >/dev/null 2>&1; then
    _val=$(jq -r '.in_progress_marker' "$_state_file" 2>/dev/null)
    if [[ "$_val" == "false" ]]; then _in_progress_false=1; fi
fi
assert_eq "test_spause_sigurg_handler_sets_recoverable_state: script must be sourceable and handler callable" "1" "$_sourced"
assert_eq "test_spause_sigurg_handler_sets_recoverable_state: in_progress_marker must be false after SIGURG" "1" "$_in_progress_false"
assert_pass_if_clean "test_spause_sigurg_handler_sets_recoverable_state"

# ── test_spause_resume_context_outputs_unanswered_story ──────────────────────
_snapshot_fail
_state_file="$SPRINT_PAUSE_STATE_DIR/sprint-pause-state-test-epic-42.json"
rm -f "$_state_file"
bash "$SCRIPT" init test-epic-42 2>/dev/null
bash "$SCRIPT" write test-epic-42 st-001 "done" 2>/dev/null
# st-002 intentionally NOT written
# Manually inject st-002 into stories array if init supports it, otherwise patch JSON directly
if test -f "$_state_file" && command -v jq >/dev/null 2>&1; then
    _patched=$(jq '.stories = ["st-001","st-002"]' "$_state_file" 2>/dev/null)
    echo "$_patched" > "$_state_file"
fi
_resume_output=$(bash "$SCRIPT" resume-context test-epic-42 2>/dev/null)
_has_st002=0
if [[ "$_resume_output" == *"st-002"* ]]; then _has_st002=1; fi
assert_eq "test_spause_resume_context_outputs_unanswered_story: resume-context must output st-002 (unanswered)" "1" "$_has_st002"
assert_pass_if_clean "test_spause_resume_context_outputs_unanswered_story"

# ── test_spause_flag_off_noop ─────────────────────────────────────────────────
_snapshot_fail
_state_file="$SPRINT_PAUSE_STATE_DIR/sprint-pause-state-test-epic-42.json"
rm -f "$_state_file"
SPRINT_PAUSE_ENABLED=false bash "$SCRIPT" init test-epic-42 2>/dev/null
_noop_exit=$?
_no_file=0
if ! test -f "$_state_file"; then _no_file=1; fi
assert_eq "test_spause_flag_off_noop: init with SPRINT_PAUSE_ENABLED=false must exit 0" "0" "$_noop_exit"
assert_eq "test_spause_flag_off_noop: init with SPRINT_PAUSE_ENABLED=false must not create state file" "1" "$_no_file"
assert_pass_if_clean "test_spause_flag_off_noop"

print_summary
