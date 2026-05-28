#!/usr/bin/env bash
# tests/scripts/test-check-story-handoff.sh
# RED test suite for plugins/dso/scripts/check-story-handoff.sh
#
# Tests cover:
#   1. JSON with P1=PASS exits 0 (successor dispatch permitted)
#   2. JSON with P1=FAIL exits 1 with JSON error
#   3. JSON with P1=BLOCKED exits 1
#   4. JSON with P1=INCONCLUSIVE exits 1
#   5. File absent exits 2
#   6. Malformed JSON exits 2
#
# Interface under test:
#   check-story-handoff.sh --predecessor-story-id=<id> [--verifier-json=<path>]
#
# Usage: bash tests/scripts/test-check-story-handoff.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail
#
# testing-mode: RED:17c2-e80f-fe3a-48f8

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SCRIPT="$PLUGIN_ROOT/plugins/dso/scripts/check-story-handoff.sh"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

echo "=== test-check-story-handoff.sh ==="

# ── test_pass_verdict_exits_0 ─────────────────────────────────────────────────
# JSON with schema_version=2, P1=PASS must exit 0 (successor dispatch permitted)
test_pass_verdict_exits_0() {
    _snapshot_fail
    local rc=0
    local tmpfile
    tmpfile=$(mktemp "${TMPDIR:-/tmp}/test-handoff.XXXXXX")
    printf '{"schema_version": 2, "P1": "PASS", "story_id": "test-story-001"}' > "$tmpfile"
    bash "$SCRIPT" --predecessor-story-id=test-story-001 --verifier-json="$tmpfile" 2>/dev/null || rc=$?
    rm -f "$tmpfile"
    assert_eq "test_pass_verdict_exits_0: exit code is 0 for P1=PASS" "0" "$rc"
    assert_pass_if_clean "test_pass_verdict_exits_0"
}

# ── test_fail_verdict_exits_1_with_json_error ─────────────────────────────────
# JSON with P1=FAIL must exit 1 and write JSON error to stderr
test_fail_verdict_exits_1_with_json_error() {
    _snapshot_fail
    local rc=0
    local tmpfile
    tmpfile=$(mktemp "${TMPDIR:-/tmp}/test-handoff.XXXXXX")
    printf '{"schema_version": 2, "P1": "FAIL", "story_id": "test-story-002"}' > "$tmpfile"
    local stderr_out
    stderr_out=$(bash "$SCRIPT" --predecessor-story-id=test-story-002 --verifier-json="$tmpfile" 2>&1) || rc=$?
    rm -f "$tmpfile"
    assert_eq "test_fail_verdict_exits_1_with_json_error: exit code is 1 for P1=FAIL" "1" "$rc"
    assert_contains "test_fail_verdict_exits_1_with_json_error: stderr contains error key" \
        '"error"' "$stderr_out"
    assert_contains "test_fail_verdict_exits_1_with_json_error: stderr contains handoff_blocked" \
        "handoff_blocked" "$stderr_out"
    assert_contains "test_fail_verdict_exits_1_with_json_error: stderr contains predecessor_story" \
        '"predecessor_story"' "$stderr_out"
    assert_contains "test_fail_verdict_exits_1_with_json_error: stderr contains verdict" \
        '"verdict"' "$stderr_out"
    assert_pass_if_clean "test_fail_verdict_exits_1_with_json_error"
}

# ── test_blocked_verdict_exits_1 ──────────────────────────────────────────────
# JSON with P1=BLOCKED must exit 1
test_blocked_verdict_exits_1() {
    _snapshot_fail
    local rc=0
    local tmpfile
    tmpfile=$(mktemp "${TMPDIR:-/tmp}/test-handoff.XXXXXX")
    printf '{"schema_version": 2, "P1": "BLOCKED", "story_id": "test-story-003"}' > "$tmpfile"
    bash "$SCRIPT" --predecessor-story-id=test-story-003 --verifier-json="$tmpfile" 2>/dev/null || rc=$?
    rm -f "$tmpfile"
    assert_eq "test_blocked_verdict_exits_1: exit code is 1 for P1=BLOCKED" "1" "$rc"
    assert_pass_if_clean "test_blocked_verdict_exits_1"
}

# ── test_inconclusive_verdict_exits_1 ────────────────────────────────────────
# JSON with P1=INCONCLUSIVE must exit 1
test_inconclusive_verdict_exits_1() {
    _snapshot_fail
    local rc=0
    local tmpfile
    tmpfile=$(mktemp "${TMPDIR:-/tmp}/test-handoff.XXXXXX")
    printf '{"schema_version": 2, "P1": "INCONCLUSIVE", "story_id": "test-story-004"}' > "$tmpfile"
    bash "$SCRIPT" --predecessor-story-id=test-story-004 --verifier-json="$tmpfile" 2>/dev/null || rc=$?
    rm -f "$tmpfile"
    assert_eq "test_inconclusive_verdict_exits_1: exit code is 1 for P1=INCONCLUSIVE" "1" "$rc"
    assert_pass_if_clean "test_inconclusive_verdict_exits_1"
}

# ── test_file_absent_exits_2 ──────────────────────────────────────────────────
# When --verifier-json points to a non-existent file, must exit 2
test_file_absent_exits_2() {
    _snapshot_fail
    local rc=0
    local nonexistent
    nonexistent=$(mktemp "${TMPDIR:-/tmp}/test-handoff.XXXXXX")
    rm -f "$nonexistent"  # ensure it doesn't exist
    bash "$SCRIPT" --predecessor-story-id=test-story-005 --verifier-json="$nonexistent" 2>/dev/null || rc=$?
    assert_eq "test_file_absent_exits_2: exit code is 2 for absent file" "2" "$rc"
    assert_pass_if_clean "test_file_absent_exits_2"
}

# ── test_malformed_json_exits_2 ───────────────────────────────────────────────
# When --verifier-json contains non-JSON content, must exit 2
test_malformed_json_exits_2() {
    _snapshot_fail
    local rc=0
    local tmpfile
    tmpfile=$(mktemp "${TMPDIR:-/tmp}/test-handoff.XXXXXX")
    printf 'this is not valid json at all' > "$tmpfile"
    bash "$SCRIPT" --predecessor-story-id=test-story-006 --verifier-json="$tmpfile" 2>/dev/null || rc=$?
    rm -f "$tmpfile"
    assert_eq "test_malformed_json_exits_2: exit code is 2 for malformed JSON" "2" "$rc"
    assert_pass_if_clean "test_malformed_json_exits_2"
}

# ── Run all tests ──────────────────────────────────────────────────────────────
test_pass_verdict_exits_0
test_fail_verdict_exits_1_with_json_error
test_blocked_verdict_exits_1
test_inconclusive_verdict_exits_1
test_file_absent_exits_2
test_malformed_json_exits_2

print_summary
