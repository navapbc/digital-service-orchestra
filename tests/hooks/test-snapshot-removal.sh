#!/usr/bin/env bash
# tests/hooks/test-snapshot-removal.sh
# TDD tests for removing snapshot references from review-stop-check.sh
# and session-misc-functions.sh (ticket lockpick-doc-to-logic-21d0)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

REVIEW_STOP="$PLUGIN_ROOT/hooks/review-stop-check.sh"
SESSION_MISC="$PLUGIN_ROOT/hooks/lib/session-misc-functions.sh"

# --- test_review_stop_check_no_snapshot_reference ---
# review-stop-check.sh must NOT contain 'untracked-snapshot'
if grep -q 'untracked-snapshot' "$REVIEW_STOP"; then
    assert_eq "test_review_stop_check_no_snapshot_reference" "no_match" "found_match"
else
    assert_eq "test_review_stop_check_no_snapshot_reference" "no_match" "no_match"
fi

# --- test_review_stop_check_no_snapshot_args ---
# review-stop-check.sh must NOT contain '_SNAPSHOT_ARGS'
if grep -q '_SNAPSHOT_ARGS' "$REVIEW_STOP"; then
    assert_eq "test_review_stop_check_no_snapshot_args" "no_match" "found_match"
else
    assert_eq "test_review_stop_check_no_snapshot_args" "no_match" "no_match"
fi

# --- test_session_misc_no_snapshot_reference ---
# session-misc-functions.sh must NOT contain 'untracked-snapshot'
if grep -q 'untracked-snapshot' "$SESSION_MISC"; then
    assert_eq "test_session_misc_no_snapshot_reference" "no_match" "found_match"
else
    assert_eq "test_session_misc_no_snapshot_reference" "no_match" "no_match"
fi

# --- test_session_misc_no_snapshot_args ---
# session-misc-functions.sh must NOT contain '_SNAPSHOT_ARGS'
if grep -q '_SNAPSHOT_ARGS' "$SESSION_MISC"; then
    assert_eq "test_session_misc_no_snapshot_args" "no_match" "found_match"
else
    assert_eq "test_session_misc_no_snapshot_args" "no_match" "no_match"
fi

# --- test_review_stop_check_syntax ---
# review-stop-check.sh must pass bash syntax check
if bash -n "$REVIEW_STOP" 2>/dev/null; then
    assert_eq "test_review_stop_check_syntax" "valid" "valid"
else
    assert_eq "test_review_stop_check_syntax" "valid" "invalid"
fi

# --- test_session_misc_syntax ---
# session-misc-functions.sh must pass bash syntax check
if bash -n "$SESSION_MISC" 2>/dev/null; then
    assert_eq "test_session_misc_syntax" "valid" "valid"
else
    assert_eq "test_session_misc_syntax" "valid" "invalid"
fi

# --- test_review_stop_check_still_calls_compute_diff_hash ---
# review-stop-check.sh must still call compute-diff-hash.sh (without snapshot args)
if grep -q 'compute-diff-hash.sh' "$REVIEW_STOP"; then
    assert_eq "test_review_stop_check_still_calls_compute_diff_hash" "found" "found"
else
    assert_eq "test_review_stop_check_still_calls_compute_diff_hash" "found" "not_found"
fi

# --- test_session_misc_still_calls_compute_diff_hash ---
# session-misc-functions.sh must still call compute-diff-hash.sh (without snapshot args)
if grep -q 'compute-diff-hash.sh' "$SESSION_MISC"; then
    assert_eq "test_session_misc_still_calls_compute_diff_hash" "found" "found"
else
    assert_eq "test_session_misc_still_calls_compute_diff_hash" "found" "not_found"
fi
