#!/usr/bin/env bash
# tests/hooks/test-snapshot-removal-record-verify.sh
# TDD tests for removing snapshot references from record-review.sh
# and verify-review-diff.sh (ticket lockpick-doc-to-logic-4za8)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

RECORD_REVIEW="$PLUGIN_ROOT/hooks/record-review.sh"
VERIFY_DIFF="$PLUGIN_ROOT/scripts/verify-review-diff.sh"

# --- test_record_review_no_snapshot_reference ---
# record-review.sh must NOT contain 'untracked-snapshot'
if grep -q 'untracked-snapshot' "$RECORD_REVIEW"; then
    assert_eq "test_record_review_no_snapshot_reference" "no_match" "found_match"
else
    assert_eq "test_record_review_no_snapshot_reference" "no_match" "no_match"
fi

# --- test_record_review_no_snapshot_args ---
# record-review.sh must NOT contain '_SNAPSHOT_ARGS'
if grep -q '_SNAPSHOT_ARGS' "$RECORD_REVIEW"; then
    assert_eq "test_record_review_no_snapshot_args" "no_match" "found_match"
else
    assert_eq "test_record_review_no_snapshot_args" "no_match" "no_match"
fi

# --- test_record_review_no_snapshot_exists_diagnostic ---
# record-review.sh must NOT contain 'snapshot_exists' or 'snapshot_used'
if grep -q 'snapshot_exists\|snapshot_used' "$RECORD_REVIEW"; then
    assert_eq "test_record_review_no_snapshot_diagnostics" "no_match" "found_match"
else
    assert_eq "test_record_review_no_snapshot_diagnostics" "no_match" "no_match"
fi

# --- test_verify_review_diff_no_snapshot_reference ---
# verify-review-diff.sh must NOT contain 'untracked-snapshot'
if grep -q 'untracked-snapshot' "$VERIFY_DIFF"; then
    assert_eq "test_verify_review_diff_no_snapshot_reference" "no_match" "found_match"
else
    assert_eq "test_verify_review_diff_no_snapshot_reference" "no_match" "no_match"
fi

# --- test_verify_review_diff_no_snapshot_args ---
# verify-review-diff.sh must NOT contain 'SNAPSHOT_ARGS'
if grep -q 'SNAPSHOT_ARGS' "$VERIFY_DIFF"; then
    assert_eq "test_verify_review_diff_no_snapshot_args" "no_match" "found_match"
else
    assert_eq "test_verify_review_diff_no_snapshot_args" "no_match" "no_match"
fi

# --- test_record_review_syntax ---
# record-review.sh must pass bash syntax check
if bash -n "$RECORD_REVIEW" 2>/dev/null; then
    assert_eq "test_record_review_syntax" "valid" "valid"
else
    assert_eq "test_record_review_syntax" "valid" "invalid"
fi

# --- test_verify_review_diff_syntax ---
# verify-review-diff.sh must pass bash syntax check
if bash -n "$VERIFY_DIFF" 2>/dev/null; then
    assert_eq "test_verify_review_diff_syntax" "valid" "valid"
else
    assert_eq "test_verify_review_diff_syntax" "valid" "invalid"
fi

# --- test_record_review_still_calls_compute_diff_hash ---
# record-review.sh must still call compute-diff-hash.sh (without snapshot args)
if grep -q 'compute-diff-hash.sh' "$RECORD_REVIEW"; then
    assert_eq "test_record_review_still_calls_compute_diff_hash" "found" "found"
else
    assert_eq "test_record_review_still_calls_compute_diff_hash" "found" "not_found"
fi

# --- test_verify_review_diff_still_calls_compute_diff_hash ---
# verify-review-diff.sh must still call compute-diff-hash.sh (without snapshot args)
if grep -q 'compute-diff-hash.sh' "$VERIFY_DIFF"; then
    assert_eq "test_verify_review_diff_still_calls_compute_diff_hash" "found" "found"
else
    assert_eq "test_verify_review_diff_still_calls_compute_diff_hash" "found" "not_found"
fi
