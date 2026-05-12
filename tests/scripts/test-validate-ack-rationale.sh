#!/usr/bin/env bash
# tests/scripts/test-validate-ack-rationale.sh
# Behavioral tests for validate-ack-rationale.sh — validates that an
# acknowledgement rationale is substantive and matches the precondition text
# via a 3-word sliding window.
#
# Tests:
#  1. test_empty_string_rejected               — rationale="" → exit 1
#  2. test_whitespace_only_rejected            — rationale="   " → exit 1
#  3. test_under_10_chars_rejected             — rationale="short" (5 chars) → exit 1
#  4. test_exactly_9_chars_rejected            — rationale="123456789" → exit 1
#  5. test_valid_3_word_window_match_accepted  — 3 consecutive words from precondition → exit 0
#  6. test_no_3_word_window_match_rejected     — >=10 chars but no 3-word overlap → exit 1
#  7. test_non_latin_precondition_triggers_manual_review — non-ASCII precondition → exit 2
#  8. test_near_miss_2_word_window_rejected    — only 2 consecutive words shared → exit 1
#
# Usage: bash tests/scripts/test-validate-ack-rationale.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

# non-zero exit codes from script invocations via || assignment. With '-e',
# expected non-zero exits would abort the script before assertions run.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SCRIPT="$PLUGIN_ROOT/plugins/dso/scripts/validate-ack-rationale.sh"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

echo "=== test-validate-ack-rationale.sh ==="

# ── test_empty_string_rejected ─────────────────────────────────────────────────
# An empty rationale string must be rejected with exit 1.
test_empty_string_rejected() {
    _snapshot_fail
    local _exit _out
    local _precondition="the precondition text here"
    _exit=0
    _out=$(bash "$SCRIPT" "" "$_precondition" 2>&1) || _exit=$?
    assert_eq "test_empty_string_rejected: exit 1" "1" "$_exit"
    assert_pass_if_clean "test_empty_string_rejected"
}

# ── test_whitespace_only_rejected ──────────────────────────────────────────────
# A rationale consisting only of whitespace must be rejected with exit 1.
test_whitespace_only_rejected() {
    _snapshot_fail
    local _exit _out
    local _precondition="the precondition text here"
    _exit=0
    _out=$(bash "$SCRIPT" "   " "$_precondition" 2>&1) || _exit=$?
    assert_eq "test_whitespace_only_rejected: exit 1" "1" "$_exit"
    assert_pass_if_clean "test_whitespace_only_rejected"
}

# ── test_under_10_chars_rejected ───────────────────────────────────────────────
# A rationale shorter than 10 characters ("short" = 5 chars) must be rejected.
test_under_10_chars_rejected() {
    _snapshot_fail
    local _exit _out
    local _precondition="the precondition text here"
    _exit=0
    _out=$(bash "$SCRIPT" "short" "$_precondition" 2>&1) || _exit=$?
    assert_eq "test_under_10_chars_rejected: exit 1" "1" "$_exit"
    assert_pass_if_clean "test_under_10_chars_rejected"
}

# ── test_exactly_9_chars_rejected ─────────────────────────────────────────────
# A rationale of exactly 9 characters must be rejected (minimum is 10).
test_exactly_9_chars_rejected() {
    _snapshot_fail
    local _exit _out
    local _precondition="the precondition text here"
    _exit=0
    _out=$(bash "$SCRIPT" "123456789" "$_precondition" 2>&1) || _exit=$?
    assert_eq "test_exactly_9_chars_rejected: exit 1" "1" "$_exit"
    assert_pass_if_clean "test_exactly_9_chars_rejected"
}

# ── test_valid_3_word_window_match_accepted ────────────────────────────────────
# When the rationale contains 3 consecutive words from the precondition
# (after normalization), the script must accept it with exit 0.
# precondition="implementation plan must be complete"
# rationale="checked that implementation plan must pass all gates"
# Normalized 3-word window "implementationplanmust" appears in both.
test_valid_3_word_window_match_accepted() {
    _snapshot_fail
    local _exit _out
    local _precondition="implementation plan must be complete"
    local _rationale="checked that implementation plan must pass all gates"
    _exit=0
    _out=$(bash "$SCRIPT" "$_rationale" "$_precondition" 2>&1) || _exit=$?
    assert_eq "test_valid_3_word_window_match_accepted: exit 0" "0" "$_exit"
    assert_pass_if_clean "test_valid_3_word_window_match_accepted"
}

# ── test_no_3_word_window_match_rejected ──────────────────────────────────────
# A rationale that is >=10 chars but shares no 3-word sliding window with the
# precondition must be rejected with exit 1.
test_no_3_word_window_match_rejected() {
    _snapshot_fail
    local _exit _out
    local _precondition="implementation plan must be complete"
    local _rationale="this is a completely different sentence with unrelated words"
    _exit=0
    _out=$(bash "$SCRIPT" "$_rationale" "$_precondition" 2>&1) || _exit=$?
    assert_eq "test_no_3_word_window_match_rejected: exit 1" "1" "$_exit"
    assert_pass_if_clean "test_no_3_word_window_match_rejected"
}

# ── test_non_latin_precondition_triggers_manual_review ────────────────────────
# A precondition containing non-Latin characters (e.g., Japanese) must cause
# the script to exit 2, signalling that manual review is required.
test_non_latin_precondition_triggers_manual_review() {
    _snapshot_fail
    local _exit _out
    local _precondition="日本語テスト precondition"
    local _rationale="checked that implementation plan must pass all gates"
    _exit=0
    _out=$(bash "$SCRIPT" "$_rationale" "$_precondition" 2>&1) || _exit=$?
    assert_eq "test_non_latin_precondition_triggers_manual_review: exit 2" "2" "$_exit"
    assert_pass_if_clean "test_non_latin_precondition_triggers_manual_review"
}

# ── test_near_miss_2_word_window_rejected ─────────────────────────────────────
# A rationale that shares exactly 2 consecutive normalized words with the
# precondition (but not 3) must be rejected with exit 1.
# precondition="implementation plan must be complete"
# rationale="checked that implementation plan can succeed in the end"
# 2-word windows: "implementationplan" appears, but no 3-word match.
test_near_miss_2_word_window_rejected() {
    _snapshot_fail
    local _exit _out
    local _precondition="implementation plan must be complete"
    local _rationale="checked that implementation plan can succeed in the end"
    _exit=0
    _out=$(bash "$SCRIPT" "$_rationale" "$_precondition" 2>&1) || _exit=$?
    assert_eq "test_near_miss_2_word_window_rejected: exit 1" "1" "$_exit"
    assert_pass_if_clean "test_near_miss_2_word_window_rejected"
}

# ── Run all tests ──────────────────────────────────────────────────────────────
test_empty_string_rejected
test_whitespace_only_rejected
test_under_10_chars_rejected
test_exactly_9_chars_rejected
test_valid_3_word_window_match_accepted
test_no_3_word_window_match_rejected
test_non_latin_precondition_triggers_manual_review
test_near_miss_2_word_window_rejected

print_summary
