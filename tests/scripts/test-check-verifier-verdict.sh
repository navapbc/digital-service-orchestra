#!/usr/bin/env bash
# tests/scripts/test-check-verifier-verdict.sh
# TDD tests for plugins/dso/scripts/check-verifier-verdict.sh
#
# Tests cover: P1=PASS exits 0, P1=FAIL/BLOCKED/INCONCLUSIVE exit 1,
# missing P1 field exits 2, and malformed JSON exits 2.
#
# Usage: bash tests/scripts/test-check-verifier-verdict.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail
#
# RED STATE: All tests currently fail because check-verifier-verdict.sh does not
# yet exist. They will pass (GREEN) after the script is implemented.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SCRIPT="$PLUGIN_ROOT/plugins/dso/scripts/check-verifier-verdict.sh"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

echo "=== test-check-verifier-verdict.sh ==="

# ── test_p1_pass_exits_0 ───────────────────────────────────────────────────────
# JSON with P1=PASS must exit 0
test_p1_pass_exits_0() {
    _snapshot_fail
    local rc=0
    echo '{"P1": "PASS"}' | bash "$SCRIPT" 2>/dev/null || rc=$?
    assert_eq "test_p1_pass_exits_0: exit code is 0 for P1=PASS" "0" "$rc"
    assert_pass_if_clean "test_p1_pass_exits_0"
}

# ── test_p1_fail_exits_1 ───────────────────────────────────────────────────────
# JSON with P1=FAIL must exit 1
test_p1_fail_exits_1() {
    _snapshot_fail
    local rc=0
    echo '{"P1": "FAIL"}' | bash "$SCRIPT" 2>/dev/null || rc=$?
    assert_eq "test_p1_fail_exits_1: exit code is 1 for P1=FAIL" "1" "$rc"
    assert_pass_if_clean "test_p1_fail_exits_1"
}

# ── test_p1_blocked_exits_1 ───────────────────────────────────────────────────
# JSON with P1=BLOCKED must exit 1
test_p1_blocked_exits_1() {
    _snapshot_fail
    local rc=0
    echo '{"P1": "BLOCKED"}' | bash "$SCRIPT" 2>/dev/null || rc=$?
    assert_eq "test_p1_blocked_exits_1: exit code is 1 for P1=BLOCKED" "1" "$rc"
    assert_pass_if_clean "test_p1_blocked_exits_1"
}

# ── test_p1_inconclusive_exits_1 ──────────────────────────────────────────────
# JSON with P1=INCONCLUSIVE must exit 1
test_p1_inconclusive_exits_1() {
    _snapshot_fail
    local rc=0
    echo '{"P1": "INCONCLUSIVE"}' | bash "$SCRIPT" 2>/dev/null || rc=$?
    assert_eq "test_p1_inconclusive_exits_1: exit code is 1 for P1=INCONCLUSIVE" "1" "$rc"
    assert_pass_if_clean "test_p1_inconclusive_exits_1"
}

# ── test_missing_p1_exits_2 ───────────────────────────────────────────────────
# JSON with no P1 field (only other fields) must exit 2
test_missing_p1_exits_2() {
    _snapshot_fail
    local rc=0
    echo '{"overall_verdict": "PASS"}' | bash "$SCRIPT" 2>/dev/null || rc=$?
    assert_eq "test_missing_p1_exits_2: exit code is 2 for missing P1 field" "2" "$rc"
    assert_pass_if_clean "test_missing_p1_exits_2"
}

# ── test_malformed_json_exits_2 ───────────────────────────────────────────────
# Non-JSON input must exit 2
test_malformed_json_exits_2() {
    _snapshot_fail
    local rc=0
    echo 'not-valid-json' | bash "$SCRIPT" 2>/dev/null || rc=$?
    assert_eq "test_malformed_json_exits_2: exit code is 2 for malformed JSON" "2" "$rc"
    assert_pass_if_clean "test_malformed_json_exits_2"
}

# ── Run all tests ──────────────────────────────────────────────────────────────
test_p1_pass_exits_0
test_p1_fail_exits_1
test_p1_blocked_exits_1
test_p1_inconclusive_exits_1
test_missing_p1_exits_2
test_malformed_json_exits_2

print_summary
