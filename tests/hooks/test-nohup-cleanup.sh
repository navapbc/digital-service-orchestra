#!/usr/bin/env bash
# lockpick-workflow/tests/hooks/test-nohup-cleanup.sh
# Tests for hook_cleanup_stale_nohup in session-misc-functions.sh
#
# The cleanup function scans /tmp/workflow-nohup-pids/*.entry files at session
# start, kills registered PIDs that are stale or running >1h, and removes
# entry files. It verifies process command matches entry before killing
# (PID recycling protection).
#
# All tests use an isolated temp directory for the registry so no real
# processes or registry files are affected.

REPO_ROOT="$(git rev-parse --show-toplevel)"
source "$REPO_ROOT/lockpick-workflow/tests/lib/assert.sh"

# Source the function library (sets up deps.sh etc.)
export CLAUDE_PLUGIN_ROOT="$REPO_ROOT/lockpick-workflow"
source "$REPO_ROOT/lockpick-workflow/hooks/lib/session-misc-functions.sh"

# --- Test isolation: use a temp directory as the nohup PID registry ---
TEST_REGISTRY=$(mktemp -d)
trap 'rm -rf "$TEST_REGISTRY"' EXIT

# ============================================================
# Test: function exists
# ============================================================
_FN_EXISTS="no"
if declare -f hook_cleanup_stale_nohup >/dev/null 2>&1; then
    _FN_EXISTS="yes"
fi
assert_eq "test_cleanup_stale_nohup_function_exists" "yes" "$_FN_EXISTS"

# ============================================================
# Test: no entry files — exits cleanly with no errors
# ============================================================
rm -rf "$TEST_REGISTRY"/*
OUTPUT=$(NOHUP_PID_REGISTRY="$TEST_REGISTRY" hook_cleanup_stale_nohup 2>&1)
EXIT_CODE=$?
assert_eq "test_no_entry_files_exits_zero" "0" "$EXIT_CODE"

# ============================================================
# Test: entry file for a dead process is removed
# ============================================================
# Use a PID that definitely doesn't exist (very high number)
DEAD_PID=9999999
ENTRY_FILE="$TEST_REGISTRY/${DEAD_PID}.entry"
cat > "$ENTRY_FILE" << EOF
pid=$DEAD_PID
command=timeout 300 make test-unit-only
started=$(date +%s)
EOF

OUTPUT=$(NOHUP_PID_REGISTRY="$TEST_REGISTRY" hook_cleanup_stale_nohup 2>&1)
_ENTRY_REMOVED="no"
if [[ ! -f "$ENTRY_FILE" ]]; then
    _ENTRY_REMOVED="yes"
fi
assert_eq "test_dead_process_entry_removed" "yes" "$_ENTRY_REMOVED"
assert_contains "test_dead_process_cleanup_reported" "Cleaned up" "$OUTPUT"

# ============================================================
# Test: entry file for a live process with matching command is NOT killed
#       if it's under 1 hour old
# ============================================================
# Start a real background process that we control
sleep 3600 &
LIVE_PID=$!
LIVE_CMD=$(ps -o command= -p "$LIVE_PID" 2>/dev/null | head -1)

ENTRY_FILE="$TEST_REGISTRY/${LIVE_PID}.entry"
cat > "$ENTRY_FILE" << EOF
pid=$LIVE_PID
command=$LIVE_CMD
started=$(date +%s)
EOF

OUTPUT=$(NOHUP_PID_REGISTRY="$TEST_REGISTRY" hook_cleanup_stale_nohup 2>&1)
_PROCESS_ALIVE="no"
if kill -0 "$LIVE_PID" 2>/dev/null; then
    _PROCESS_ALIVE="yes"
fi
_ENTRY_EXISTS="no"
if [[ -f "$ENTRY_FILE" ]]; then
    _ENTRY_EXISTS="yes"
fi
assert_eq "test_young_live_process_not_killed" "yes" "$_PROCESS_ALIVE"
assert_eq "test_young_live_process_entry_kept" "yes" "$_ENTRY_EXISTS"

# Clean up test process
kill "$LIVE_PID" 2>/dev/null; wait "$LIVE_PID" 2>/dev/null || true
rm -f "$ENTRY_FILE"

# ============================================================
# Test: entry file for a live process with OLD start time IS killed
# ============================================================
sleep 3600 &
OLD_PID=$!
OLD_CMD=$(ps -o command= -p "$OLD_PID" 2>/dev/null | head -1)

ENTRY_FILE="$TEST_REGISTRY/${OLD_PID}.entry"
# started 2 hours ago
OLD_START=$(( $(date +%s) - 7200 ))
cat > "$ENTRY_FILE" << EOF
pid=$OLD_PID
command=$OLD_CMD
started=$OLD_START
EOF

OUTPUT=$(NOHUP_PID_REGISTRY="$TEST_REGISTRY" hook_cleanup_stale_nohup 2>&1)
# Wait up to 2s for process to die (avoids race on loaded systems)
_WAITED=0
while kill -0 "$OLD_PID" 2>/dev/null && [[ "$_WAITED" -lt 20 ]]; do
    sleep 0.1; _WAITED=$((_WAITED + 1))
done
_PROCESS_KILLED="no"
if ! kill -0 "$OLD_PID" 2>/dev/null; then
    _PROCESS_KILLED="yes"
fi
_ENTRY_REMOVED="no"
if [[ ! -f "$ENTRY_FILE" ]]; then
    _ENTRY_REMOVED="yes"
fi
assert_eq "test_old_live_process_killed" "yes" "$_PROCESS_KILLED"
assert_eq "test_old_live_process_entry_removed" "yes" "$_ENTRY_REMOVED"
assert_contains "test_old_process_cleanup_reported" "Cleaned up" "$OUTPUT"

# Clean up just in case
kill "$OLD_PID" 2>/dev/null; wait "$OLD_PID" 2>/dev/null || true

# ============================================================
# Test: PID recycling protection — command mismatch prevents kill
# ============================================================
sleep 3600 &
RECYCLED_PID=$!

ENTRY_FILE="$TEST_REGISTRY/${RECYCLED_PID}.entry"
# Entry says the command was something totally different
OLD_START=$(( $(date +%s) - 7200 ))
cat > "$ENTRY_FILE" << EOF
pid=$RECYCLED_PID
command=totally_different_process_that_never_existed_xyz
started=$OLD_START
EOF

OUTPUT=$(NOHUP_PID_REGISTRY="$TEST_REGISTRY" hook_cleanup_stale_nohup 2>&1)
_PROCESS_ALIVE="no"
if kill -0 "$RECYCLED_PID" 2>/dev/null; then
    _PROCESS_ALIVE="yes"
fi
_ENTRY_REMOVED="no"
if [[ ! -f "$ENTRY_FILE" ]]; then
    _ENTRY_REMOVED="yes"
fi
assert_eq "test_pid_recycling_protection_process_not_killed" "yes" "$_PROCESS_ALIVE"
# Entry should still be removed (stale entry for recycled PID)
assert_eq "test_pid_recycling_protection_entry_removed" "yes" "$_ENTRY_REMOVED"

# Clean up test process
kill "$RECYCLED_PID" 2>/dev/null; wait "$RECYCLED_PID" 2>/dev/null || true

# ============================================================
# Test: multiple entry files — mixed cleanup
# ============================================================
# Entry 1: dead process
DEAD_PID2=9999998
ENTRY1="$TEST_REGISTRY/${DEAD_PID2}.entry"
cat > "$ENTRY1" << EOF
pid=$DEAD_PID2
command=timeout 300 make test-plugin
started=$(date +%s)
EOF

# Entry 2: dead process
DEAD_PID3=9999997
ENTRY2="$TEST_REGISTRY/${DEAD_PID3}.entry"
cat > "$ENTRY2" << EOF
pid=$DEAD_PID3
command=timeout 300 validate.sh
started=$(date +%s)
EOF

OUTPUT=$(NOHUP_PID_REGISTRY="$TEST_REGISTRY" hook_cleanup_stale_nohup 2>&1)
_BOTH_REMOVED="no"
if [[ ! -f "$ENTRY1" && ! -f "$ENTRY2" ]]; then
    _BOTH_REMOVED="yes"
fi
assert_eq "test_multiple_dead_entries_removed" "yes" "$_BOTH_REMOVED"
assert_contains "test_multiple_cleanup_count" "2" "$OUTPUT"

# ============================================================
# Test: session-start dispatcher calls the cleanup function
# ============================================================
_DISPATCHER_CALLS_CLEANUP="no"
if grep -q 'cleanup_stale_nohup' "$REPO_ROOT/lockpick-workflow/hooks/dispatchers/session-start.sh" 2>/dev/null; then
    _DISPATCHER_CALLS_CLEANUP="yes"
fi
assert_eq "test_session_start_calls_cleanup" "yes" "$_DISPATCHER_CALLS_CLEANUP"

# ============================================================
# Test: function scans workflow-nohup-pids path
# ============================================================
_SCANS_REGISTRY="no"
if grep -q 'workflow-nohup-pids' "$REPO_ROOT/lockpick-workflow/hooks/lib/session-misc-functions.sh" 2>/dev/null; then
    _SCANS_REGISTRY="yes"
fi
assert_eq "test_scans_nohup_pid_registry" "yes" "$_SCANS_REGISTRY"

# ============================================================
# Test: function checks command match (PID recycling protection)
# ============================================================
_CHECKS_CMD="no"
if grep -qE 'command|cmd' "$REPO_ROOT/lockpick-workflow/hooks/lib/session-misc-functions.sh" 2>/dev/null; then
    _CHECKS_CMD="yes"
fi
assert_eq "test_checks_command_match" "yes" "$_CHECKS_CMD"

# ============================================================
# Test: function removes entry files
# ============================================================
_REMOVES_ENTRY="no"
if grep -qE 'rm.*entry|remove.*entry' "$REPO_ROOT/lockpick-workflow/hooks/lib/session-misc-functions.sh" 2>/dev/null; then
    _REMOVES_ENTRY="yes"
fi
assert_eq "test_removes_entry_files" "yes" "$_REMOVES_ENTRY"

print_summary
