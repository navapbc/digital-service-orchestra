#!/usr/bin/env bash
# lockpick-workflow/tests/hooks/test-session-safety.sh
# Tests for .claude/hooks/session-safety-check.sh
#
# session-safety-check.sh is a SessionStart hook that analyzes the
# hook error log and creates bugs for recurring errors. Always exits 0.

REPO_ROOT="$(git rev-parse --show-toplevel)"
HOOK="$REPO_ROOT/lockpick-workflow/hooks/session-safety-check.sh"

source "$REPO_ROOT/lockpick-workflow/tests/lib/assert.sh"

HOOK_ERROR_LOG="$HOME/.claude/hook-error-log.jsonl"

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
# Back up and clear the real error log so accumulated errors don't
# produce output that contaminates the exit-code capture.
_ORIG_LOG_1=""
if [[ -f "$HOOK_ERROR_LOG" ]]; then
    _ORIG_LOG_1="$HOOK_ERROR_LOG.bak.test1.$$"
    mv "$HOOK_ERROR_LOG" "$_ORIG_LOG_1"
fi
EXIT_CODE=$(run_hook_exit)
assert_eq "test_session_safety_exits_zero_on_safe_command" "0" "$EXIT_CODE"
# Restore
if [[ -n "$_ORIG_LOG_1" && -f "$_ORIG_LOG_1" ]]; then
    mv "$_ORIG_LOG_1" "$HOOK_ERROR_LOG"
fi

# test_session_safety_exits_zero_when_no_error_log
# With no hook error log, should exit 0 silently
ORIG_LOG=""
if [[ -f "$HOOK_ERROR_LOG" ]]; then
    ORIG_LOG="$HOOK_ERROR_LOG.bak.$$"
    mv "$HOOK_ERROR_LOG" "$ORIG_LOG"
fi

EXIT_CODE=$(run_hook_exit)
assert_eq "test_session_safety_exits_zero_when_no_error_log" "0" "$EXIT_CODE"

# Restore log
if [[ -n "$ORIG_LOG" && -f "$ORIG_LOG" ]]; then
    mv "$ORIG_LOG" "$HOOK_ERROR_LOG"
fi

# test_session_safety_exits_zero_with_error_log_below_threshold
# Error log exists but errors are below threshold (< 10 in 24h) → exit 0 silently
ORIG_LOG=""
if [[ -f "$HOOK_ERROR_LOG" ]]; then
    ORIG_LOG="$HOOK_ERROR_LOG.bak.$$"
    cp "$HOOK_ERROR_LOG" "$ORIG_LOG"
fi

# Write a few error entries below threshold (only 3, threshold is 10)
NOW=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
mkdir -p "$(dirname "$HOOK_ERROR_LOG")"
printf '{"ts":"%s","hook":"test-hook.sh","line":42}\n' "$NOW" > "$HOOK_ERROR_LOG"
printf '{"ts":"%s","hook":"test-hook.sh","line":42}\n' "$NOW" >> "$HOOK_ERROR_LOG"
printf '{"ts":"%s","hook":"test-hook.sh","line":42}\n' "$NOW" >> "$HOOK_ERROR_LOG"

EXIT_CODE=$(run_hook_exit)
assert_eq "test_session_safety_exits_zero_with_error_log_below_threshold" "0" "$EXIT_CODE"

# test_session_safety_output_empty_below_threshold
# No output when below threshold
OUTPUT=$(run_hook_output)
assert_eq "test_session_safety_output_empty_below_threshold" "" "$OUTPUT"

# Restore original log
if [[ -n "$ORIG_LOG" && -f "$ORIG_LOG" ]]; then
    mv "$ORIG_LOG" "$HOOK_ERROR_LOG"
elif [[ -z "$ORIG_LOG" ]]; then
    rm -f "$HOOK_ERROR_LOG"
fi

# ============================================================
# Group: bd → tk migration (RED phase)
# ============================================================
# These tests verify that session-safety-check.sh has been migrated
# away from bd. They MUST FAIL against the current bd-based implementation.

# test_session_safety_no_bd_calls_remain
# grep the hook source for 'bd ' — must return zero occurrences once migrated.
# MUST FAIL in red phase: hook calls 'bd create' when threshold is exceeded.
_SS_BD_COUNT=$(grep -c 'bd ' "$HOOK" 2>/dev/null; true)
assert_eq "test_session_safety_no_bd_calls_remain" "0" "$_SS_BD_COUNT"

# test_session_safety_creates_tk_issue
# Stub tk in PATH. Create a hook-error-log.jsonl with 11 entries for one hook.
# Assert tk create is called when threshold exceeded (>= 10 errors in 24h).
# MUST FAIL in red phase because the hook calls bd create, not tk create.
_SS_FAKE_BIN=$(mktemp -d)
_SS_TK_LOG="$_SS_FAKE_BIN/tk.log"

cat > "$_SS_FAKE_BIN/tk" << 'MOCK_EOF'
#!/usr/bin/env bash
echo "$@" >> "$TK_LOG"
echo "Created issue: tk-003"
MOCK_EOF
chmod +x "$_SS_FAKE_BIN/tk"

# Suppress bd so it doesn't call real bd
cat > "$_SS_FAKE_BIN/bd" << 'MOCK_EOF'
#!/usr/bin/env bash
exit 0
MOCK_EOF
chmod +x "$_SS_FAKE_BIN/bd"

# Back up real error log and create a synthetic one with 11 entries exceeding threshold
_SS_ORIG_LOG=""
if [[ -f "$HOOK_ERROR_LOG" ]]; then
    _SS_ORIG_LOG="$HOOK_ERROR_LOG.bak.ss.$$"
    mv "$HOOK_ERROR_LOG" "$_SS_ORIG_LOG"
fi

mkdir -p "$(dirname "$HOOK_ERROR_LOG")"
NOW=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
for _i in $(seq 1 11); do
    printf '{"ts":"%s","hook":"auto-format.sh","line":42}\n' "$NOW" >> "$HOOK_ERROR_LOG"
done

# Also clear the bugs_dir marker so bug creation is attempted
_SS_BUGS_DIR="$HOME/.claude/hook-error-bugs"
_SS_MARKER="$_SS_BUGS_DIR/auto-format.sh.bug"
_SS_MARKER_SAVED=""
if [[ -f "$_SS_MARKER" ]]; then
    _SS_MARKER_SAVED=$(cat "$_SS_MARKER")
    rm -f "$_SS_MARKER"
fi

TK_LOG="$_SS_TK_LOG" PATH="$_SS_FAKE_BIN:$PATH" bash "$HOOK" >/dev/null 2>/dev/null || true

# Check that tk create was called
_SS_TK_CALLED="no"
if [[ -f "$_SS_TK_LOG" ]] && grep -q "create" "$_SS_TK_LOG" 2>/dev/null; then
    _SS_TK_CALLED="yes"
fi
assert_eq "test_session_safety_creates_tk_issue" "yes" "$_SS_TK_CALLED"

# Restore error log
rm -f "$HOOK_ERROR_LOG"
if [[ -n "$_SS_ORIG_LOG" && -f "$_SS_ORIG_LOG" ]]; then
    mv "$_SS_ORIG_LOG" "$HOOK_ERROR_LOG"
fi

# Restore marker
if [[ -n "$_SS_MARKER_SAVED" ]]; then
    mkdir -p "$_SS_BUGS_DIR"
    echo "$_SS_MARKER_SAVED" > "$_SS_MARKER"
else
    rm -f "$_SS_MARKER"
fi

rm -rf "$_SS_FAKE_BIN"

# test_session_safety_marker_written_before_tk_create
# Even if tk create fails/times out, the marker file must exist to prevent
# duplicate ticket creation on subsequent sessions. This was the root cause
# of y86r: tk create timeout → no marker → duplicates every session.
_SS_FAKE_BIN2=$(mktemp -d)
_SS_TK_LOG2="$_SS_FAKE_BIN2/tk.log"

# Mock tk that FAILS (simulates timeout / exit 144)
cat > "$_SS_FAKE_BIN2/tk" << 'MOCK_EOF'
#!/usr/bin/env bash
echo "$@" >> "$TK_LOG"
exit 1
MOCK_EOF
chmod +x "$_SS_FAKE_BIN2/tk"

cat > "$_SS_FAKE_BIN2/bd" << 'MOCK_EOF'
#!/usr/bin/env bash
exit 0
MOCK_EOF
chmod +x "$_SS_FAKE_BIN2/bd"

_SS_ORIG_LOG_MK=""
if [[ -f "$HOOK_ERROR_LOG" ]]; then
    _SS_ORIG_LOG_MK="$HOOK_ERROR_LOG.bak.mk.$$"
    mv "$HOOK_ERROR_LOG" "$_SS_ORIG_LOG_MK"
fi

mkdir -p "$(dirname "$HOOK_ERROR_LOG")"
NOW=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
for _i in $(seq 1 11); do
    printf '{"ts":"%s","hook":"auto-format.sh","line":42}\n' "$NOW" >> "$HOOK_ERROR_LOG"
done

_SS_BUGS_DIR_MK="$HOME/.claude/hook-error-bugs"
_SS_MARKER_MK="$_SS_BUGS_DIR_MK/auto-format.sh.bug"
_SS_MARKER_MK_SAVED=""
if [[ -f "$_SS_MARKER_MK" ]]; then
    _SS_MARKER_MK_SAVED=$(cat "$_SS_MARKER_MK")
    rm -f "$_SS_MARKER_MK"
fi

TK_LOG="$_SS_TK_LOG2" PATH="$_SS_FAKE_BIN2:$PATH" bash "$HOOK" >/dev/null 2>/dev/null || true

# Marker must exist even though tk create failed
_SS_MARKER_EXISTS="no"
if [[ -f "$_SS_MARKER_MK" ]]; then
    _SS_MARKER_EXISTS="yes"
fi
assert_eq "test_session_safety_marker_written_before_tk_create" "yes" "$_SS_MARKER_EXISTS"

# Restore
rm -f "$HOOK_ERROR_LOG"
if [[ -n "$_SS_ORIG_LOG_MK" && -f "$_SS_ORIG_LOG_MK" ]]; then
    mv "$_SS_ORIG_LOG_MK" "$HOOK_ERROR_LOG"
fi
if [[ -n "$_SS_MARKER_MK_SAVED" ]]; then
    mkdir -p "$_SS_BUGS_DIR_MK"
    echo "$_SS_MARKER_MK_SAVED" > "$_SS_MARKER_MK"
else
    rm -f "$_SS_MARKER_MK"
fi
rm -rf "$_SS_FAKE_BIN2"

# ============================================================
# Group: jq removal — python3/bash replacement
# ============================================================

# test_session_safety_no_jq_calls_remain
# The hook must not contain any jq calls after migration
_SS_JQ_COUNT=$(grep -cE '(command -v jq|jq -|jq ")' "$HOOK" 2>/dev/null; true)
assert_eq "test_session_safety_no_jq_calls_remain" "0" "$_SS_JQ_COUNT"

# test_session_safety_rotation_removes_old_entries
# Create a JSONL with old (>7 days) and recent entries, run hook, verify old removed
_SS_ORIG_LOG_ROT=""
if [[ -f "$HOOK_ERROR_LOG" ]]; then
    _SS_ORIG_LOG_ROT="$HOOK_ERROR_LOG.bak.rot.$$"
    mv "$HOOK_ERROR_LOG" "$_SS_ORIG_LOG_ROT"
fi

mkdir -p "$(dirname "$HOOK_ERROR_LOG")"
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

# Restore
rm -f "$HOOK_ERROR_LOG"
if [[ -n "$_SS_ORIG_LOG_ROT" && -f "$_SS_ORIG_LOG_ROT" ]]; then
    mv "$_SS_ORIG_LOG_ROT" "$HOOK_ERROR_LOG"
fi

# test_session_safety_counting_matches_expected
# Create exactly 11 entries for "count-test-hook.sh" — should exceed threshold
_SS_ORIG_LOG_CNT=""
if [[ -f "$HOOK_ERROR_LOG" ]]; then
    _SS_ORIG_LOG_CNT="$HOOK_ERROR_LOG.bak.cnt.$$"
    mv "$HOOK_ERROR_LOG" "$_SS_ORIG_LOG_CNT"
fi

mkdir -p "$(dirname "$HOOK_ERROR_LOG")"
NOW=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
for _i in $(seq 1 11); do
    printf '{"ts":"%s","hook":"auto-format.sh","line":42}\n' "$NOW" >> "$HOOK_ERROR_LOG"
done

# Also clear bug marker
_SS_BUGS_DIR2="$HOME/.claude/hook-error-bugs"
_SS_MARKER2="$_SS_BUGS_DIR2/auto-format.sh.bug"
_SS_MARKER2_SAVED=""
if [[ -f "$_SS_MARKER2" ]]; then
    _SS_MARKER2_SAVED=$(cat "$_SS_MARKER2")
    rm -f "$_SS_MARKER2"
fi

OUTPUT=$(bash "$HOOK" 2>/dev/null < /dev/null || true)
_SS_WARNS_PRESENT="no"
if echo "$OUTPUT" | grep -q "auto-format.sh" 2>/dev/null; then
    _SS_WARNS_PRESENT="yes"
fi
assert_eq "test_session_safety_counting_matches_expected" "yes" "$_SS_WARNS_PRESENT"

# Restore
rm -f "$HOOK_ERROR_LOG"
if [[ -n "$_SS_ORIG_LOG_CNT" && -f "$_SS_ORIG_LOG_CNT" ]]; then
    mv "$_SS_ORIG_LOG_CNT" "$HOOK_ERROR_LOG"
fi
if [[ -n "$_SS_MARKER2_SAVED" ]]; then
    mkdir -p "$_SS_BUGS_DIR2"
    echo "$_SS_MARKER2_SAVED" > "$_SS_MARKER2"
else
    rm -f "$_SS_MARKER2"
fi

print_summary
