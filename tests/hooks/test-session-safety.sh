#!/usr/bin/env bash
# tests/hooks/test-session-safety.sh
# Tests for .claude/hooks/session-safety-check.sh
#
# session-safety-check.sh is a SessionStart hook that analyzes the
# hook error log and creates bugs for recurring errors. Always exits 0.
#
# All tests use an isolated $HOME (temp dir) so no real user files are
# touched. Previous versions wrote to the real ~/.claude/ — if cleanup
# failed, stale entries caused phantom bug tickets (see bug 0glp, y86r).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DSO_PLUGIN_DIR="$PLUGIN_ROOT/plugins/dso"
REPO_ROOT="$(git rev-parse --show-toplevel)"
HOOK="$DSO_PLUGIN_DIR/hooks/session-safety-check.sh"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

# --- Test isolation: override HOME to a temp directory ---
_REAL_HOME="$HOME"
TEST_HOME=$(mktemp -d)
export HOME="$TEST_HOME"
mkdir -p "$TEST_HOME/.claude/logs"
mkdir -p "$TEST_HOME/.claude"
trap 'export HOME="$_REAL_HOME"; rm -rf "$TEST_HOME"' EXIT

HOOK_ERROR_LOG="$TEST_HOME/.claude/logs/dso-hook-errors.jsonl"

run_hook_exit() {
    local exit_code=0
    bash "$HOOK" 2>/dev/null < /dev/null || exit_code=$?
    echo "$exit_code"
}

run_hook_output() {
    bash "$HOOK" 2>/dev/null < /dev/null
}

# test_session_safety_exits_zero_on_safe_command
# SessionStart hook always exits 0 regardless of what it finds
EXIT_CODE=$(run_hook_exit)
assert_eq "test_session_safety_exits_zero_on_safe_command" "0" "$EXIT_CODE"

# test_session_safety_exits_zero_when_no_error_log
# With no hook error log, should exit 0 silently
rm -f "$HOOK_ERROR_LOG"
EXIT_CODE=$(run_hook_exit)
assert_eq "test_session_safety_exits_zero_when_no_error_log" "0" "$EXIT_CODE"

# test_session_safety_exits_zero_with_error_log_below_threshold
# Error log exists but errors are below threshold (< 10 in 24h) → exit 0 silently
# Write a few error entries below threshold (only 3, threshold is 10)
NOW=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
printf '{"ts":"%s","hook":"test-hook.sh","line":42}\n' "$NOW" > "$HOOK_ERROR_LOG"
printf '{"ts":"%s","hook":"test-hook.sh","line":42}\n' "$NOW" >> "$HOOK_ERROR_LOG"
printf '{"ts":"%s","hook":"test-hook.sh","line":42}\n' "$NOW" >> "$HOOK_ERROR_LOG"

EXIT_CODE=$(run_hook_exit)
assert_eq "test_session_safety_exits_zero_with_error_log_below_threshold" "0" "$EXIT_CODE"

# test_session_safety_output_empty_below_threshold
# No output when below threshold
OUTPUT=$(run_hook_output)
assert_eq "test_session_safety_output_empty_below_threshold" "" "$OUTPUT"

# Clean up for next test
rm -f "$HOOK_ERROR_LOG"

# test_session_safety_no_auto_ticket_creation
# Point TICKET_CMD at fake-ticket.sh. Create a hook-error-log.jsonl with 11 entries.
# Assert ticket create is NOT called — auto-ticket-creation was removed (july).
_SS_TMPDIR=$(mktemp -d)
_SS_TICKET_LOG="$_SS_TMPDIR/ticket.log"

NOW=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
for _i in $(seq 1 11); do
    printf '{"ts":"%s","hook":"auto-format.sh","line":42}\n' "$NOW" >> "$HOOK_ERROR_LOG"
done

TICKET_CMD="$PLUGIN_ROOT/tests/lib/fake-ticket.sh" TICKET_LOG_FILE="$_SS_TICKET_LOG" bash "$HOOK" >/dev/null 2>/dev/null || true

# Check that ticket create was NOT called
_SS_TICKET_CALLED="no"
if [[ -f "$_SS_TICKET_LOG" ]] && grep -q "^create " "$_SS_TICKET_LOG" 2>/dev/null; then
    _SS_TICKET_CALLED="yes"
fi
assert_eq "test_session_safety_no_auto_ticket_creation" "no" "$_SS_TICKET_CALLED"

# Clean up
rm -f "$HOOK_ERROR_LOG"
rm -rf "$_SS_TMPDIR"

# test_session_safety_no_marker_files
# With auto-ticket-creation removed, no marker files should be written.
NOW=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
for _i in $(seq 1 11); do
    printf '{"ts":"%s","hook":"auto-format.sh","line":42}\n' "$NOW" >> "$HOOK_ERROR_LOG"
done

_SS_BUGS_DIR_MK="$TEST_HOME/.claude/hook-error-bugs"
rm -rf "$_SS_BUGS_DIR_MK"

TICKET_CMD="$PLUGIN_ROOT/tests/lib/fake-ticket.sh" bash "$HOOK" >/dev/null 2>/dev/null || true

# No marker directory or files should be created
_SS_NO_MARKERS="yes"
if [[ -d "$_SS_BUGS_DIR_MK" ]] && [[ -n "$(ls -A "$_SS_BUGS_DIR_MK" 2>/dev/null)" ]]; then
    _SS_NO_MARKERS="no"
fi
assert_eq "test_session_safety_no_marker_files" "yes" "$_SS_NO_MARKERS"

# Clean up
rm -f "$HOOK_ERROR_LOG"

# ============================================================
# Group: jq removal — python3/bash replacement
# ============================================================

# test_session_safety_no_jq_calls_remain
# The hook must not contain any jq calls after migration
_SS_JQ_COUNT=$(grep -cE '(command -v jq|jq -|jq ")' "$HOOK" 2>/dev/null; true)
assert_eq "test_session_safety_no_jq_calls_remain" "0" "$_SS_JQ_COUNT"

# test_session_safety_rotation_removes_old_entries
# Create a JSONL with old (>7 days) and recent entries, run hook, verify old removed
# Old entry (2020) — should be rotated out
printf '{"ts":"2020-01-01T00:00:00Z","hook":"old-hook.sh","line":1}\n' > "$HOOK_ERROR_LOG"
# Recent entry (now) — should be kept
NOW=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
printf '{"ts":"%s","hook":"recent-hook.sh","line":2}\n' "$NOW" >> "$HOOK_ERROR_LOG"

bash "$HOOK" >/dev/null 2>/dev/null || true

# After rotation, old entry should be gone and recent entry kept
_SS_OLD_PRESENT="no"
_SS_RECENT_PRESENT="no"
if grep -q "old-hook.sh" "$HOOK_ERROR_LOG" 2>/dev/null; then
    _SS_OLD_PRESENT="yes"
fi
if grep -q "recent-hook.sh" "$HOOK_ERROR_LOG" 2>/dev/null; then
    _SS_RECENT_PRESENT="yes"
fi
assert_eq "test_session_safety_rotation_removes_old_entries" "no" "$_SS_OLD_PRESENT"
assert_eq "test_session_safety_rotation_keeps_recent_entries" "yes" "$_SS_RECENT_PRESENT"

# Clean up
rm -f "$HOOK_ERROR_LOG"

# test_session_safety_counting_matches_expected
# Create exactly 11 entries for "auto-format.sh" — should exceed threshold
NOW=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
for _i in $(seq 1 11); do
    printf '{"ts":"%s","hook":"auto-format.sh","line":42}\n' "$NOW" >> "$HOOK_ERROR_LOG"
done

# Clear bug marker
_SS_BUGS_DIR2="$TEST_HOME/.claude/hook-error-bugs"
_SS_MARKER2="$_SS_BUGS_DIR2/auto-format.sh.bug"
rm -f "$_SS_MARKER2"

OUTPUT=$(bash "$HOOK" 2>/dev/null < /dev/null || true)
_SS_WARNS_PRESENT="no"
_tmp="$OUTPUT"; if [[ "$_tmp" =~ auto-format\.sh ]] 2>/dev/null; then
    _SS_WARNS_PRESENT="yes"
fi
assert_eq "test_session_safety_counting_matches_expected" "yes" "$_SS_WARNS_PRESENT"

# Clean up
rm -f "$HOOK_ERROR_LOG" "$_SS_MARKER2"

test_session_safety_reads_legacy_path() {
    # Test dual-read: session-safety-check.sh must count errors from BOTH log paths
    # Write 6 entries to legacy path and 6 to new path; combined = 12 >= threshold(10)
    # With single-path read (current), count = 6 < 10 = no warning (test FAILS RED)
    # With dual-read (T4), count = 12 >= 10 = warning appears (test passes GREEN)
    local _DR_TEST_HOME
    _DR_TEST_HOME=$(mktemp -d)
    mkdir -p "$_DR_TEST_HOME/.claude/logs"
    mkdir -p "$_DR_TEST_HOME/.claude"

    local _DR_NOW
    _DR_NOW=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

    # Write 6 recent error entries to LEGACY path
    local _DR_LEGACY="$_DR_TEST_HOME/.claude/hook-error-log.jsonl"
    for _i in $(seq 1 6); do
        printf '{"ts":"%s","hook":"auto-format.sh","line":42}\n' "$_DR_NOW" >> "$_DR_LEGACY"
    done

    # Write 6 recent error entries to NEW path
    local _DR_NEW="$_DR_TEST_HOME/.claude/logs/dso-hook-errors.jsonl"
    for _i in $(seq 1 6); do
        printf '{"ts":"%s","hook":"auto-format.sh","line":42}\n' "$_DR_NOW" >> "$_DR_NEW"
    done

    # Run session-safety-check.sh with isolated HOME
    local _DR_OUTPUT
    _DR_OUTPUT=$(HOME="$_DR_TEST_HOME" bash plugins/dso/hooks/session-safety-check.sh 2>/dev/null || true)

    rm -rf "$_DR_TEST_HOME"

    # After T4 dual-read: combined 12 entries >= threshold(10) → warning includes auto-format.sh
    # Before T4 (current): only legacy 6 entries < threshold(10) → no warning, output empty
    # Assert: output contains "auto-format.sh" (RED now, GREEN after T4)
    local _DR_WARNS="no"
    if [[ "$_DR_OUTPUT" =~ auto-format\.sh ]]; then
        _DR_WARNS="yes"
    fi
    assert_eq "test_session_safety_reads_legacy_path" "yes" "$_DR_WARNS"
}
test_session_safety_reads_legacy_path

print_summary
