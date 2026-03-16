#!/usr/bin/env bash
# tests/test-process-cleanup.sh
# TDD tests for session-safe process cleanup in run-all.sh.
#
# Tests:
#   1. test_cleanup_creates_and_removes_pidfile
#   2. test_cleanup_targets_only_own_session
#   3. test_cleanup_ignores_other_session_pidfiles
#   4. test_pidfile_uses_session_id

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null)"

source "$SCRIPT_DIR/lib/assert.sh"

WORK_DIR=$(mktemp -d)
trap 'rm -rf "$WORK_DIR"' EXIT

# --- Test 1: cleanup helper creates and removes pidfile ---
test_cleanup_creates_and_removes_pidfile() {
    _snapshot_fail

    source "$SCRIPT_DIR/lib/process-cleanup.sh"

    local pidfile="$WORK_DIR/test1.pid"
    _write_pidfile "$pidfile" "12345" "test-session-1"

    assert_eq "pidfile: created" "true" "$([ -f "$pidfile" ] && echo true || echo false)"

    local content
    content=$(cat "$pidfile")
    assert_contains "pidfile: has PID" "12345" "$content"
    assert_contains "pidfile: has session" "test-session-1" "$content"

    _remove_pidfile "$pidfile"
    assert_eq "pidfile: removed" "false" "$([ -f "$pidfile" ] && echo true || echo false)"

    assert_pass_if_clean "test_cleanup_creates_and_removes_pidfile"
}

# --- Test 2: cleanup targets only own session's stale pids ---
test_cleanup_targets_only_own_session() {
    _snapshot_fail

    source "$SCRIPT_DIR/lib/process-cleanup.sh"

    local piddir="$WORK_DIR/pids-test2"
    mkdir -p "$piddir"

    # Create pidfiles for our session and another session
    _write_pidfile "$piddir/runner-1.pid" "99991" "my-session"
    _write_pidfile "$piddir/runner-2.pid" "99992" "my-session"
    _write_pidfile "$piddir/runner-3.pid" "99993" "other-session"

    # Collect PIDs that would be cleaned for "my-session"
    local pids_to_clean
    pids_to_clean=$(_get_stale_pids_for_session "$piddir" "my-session" "$$")

    assert_contains "cleanup: includes 99991" "99991" "$pids_to_clean"
    assert_contains "cleanup: includes 99992" "99992" "$pids_to_clean"

    # Should NOT include other-session's PID
    if echo "$pids_to_clean" | grep -q "99993"; then
        (( ++FAIL ))
        echo "FAIL: cleanup: should not include other-session PID 99993" >&2
    else
        (( ++PASS ))
    fi

    assert_pass_if_clean "test_cleanup_targets_only_own_session"
}

# --- Test 3: cleanup ignores other session pidfiles entirely ---
test_cleanup_ignores_other_session_pidfiles() {
    _snapshot_fail

    source "$SCRIPT_DIR/lib/process-cleanup.sh"

    local piddir="$WORK_DIR/pids-test3"
    mkdir -p "$piddir"

    # Only other-session pidfiles
    _write_pidfile "$piddir/runner-1.pid" "88881" "other-session-a"
    _write_pidfile "$piddir/runner-2.pid" "88882" "other-session-b"

    local pids_to_clean
    pids_to_clean=$(_get_stale_pids_for_session "$piddir" "my-session" "$$")

    assert_eq "no-match: empty result" "" "$pids_to_clean"
    assert_pass_if_clean "test_cleanup_ignores_other_session_pidfiles"
}

# --- Test 4: pidfile format uses session ID ---
test_pidfile_uses_session_id() {
    _snapshot_fail

    source "$SCRIPT_DIR/lib/process-cleanup.sh"

    local pidfile="$WORK_DIR/test4.pid"
    local session_id="worktree-20260313-141738"
    _write_pidfile "$pidfile" "54321" "$session_id"

    local stored_session
    stored_session=$(_read_session_from_pidfile "$pidfile")

    assert_eq "session-id: matches" "$session_id" "$stored_session"
    assert_pass_if_clean "test_pidfile_uses_session_id"
}

# --- Run all tests ---
test_cleanup_creates_and_removes_pidfile
test_cleanup_targets_only_own_session
test_cleanup_ignores_other_session_pidfiles
test_pidfile_uses_session_id

print_summary
