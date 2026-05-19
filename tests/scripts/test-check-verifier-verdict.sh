#!/usr/bin/env bash
# tests/scripts/test-check-verifier-verdict.sh
# TDD tests for plugins/dso/scripts/check-verifier-verdict.sh
#
# Tests cover: P1=PASS exits 0, P1=FAIL/BLOCKED/INCONCLUSIVE exit 1,
# legacy payload (no P1, overall_verdict=PASS) exits 0 via backward-compat shim (S1b),
# schema_version=2 payload missing P1 exits 2, and malformed JSON exits 2.
#
# Usage: bash tests/scripts/test-check-verifier-verdict.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail
#
# testing-mode: GREEN

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SCRIPT="$PLUGIN_ROOT/plugins/dso/scripts/check-verifier-verdict.sh"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

echo "=== test-check-verifier-verdict.sh ==="

# ── test_p1_pass_exits_0 ───────────────────────────────────────────────────────
# JSON with schema_version=2 and P1=PASS must exit 0
test_p1_pass_exits_0() {
    _snapshot_fail
    local rc=0
    echo '{"schema_version": 2, "P1": "PASS"}' | bash "$SCRIPT" 2>/dev/null || rc=$?
    assert_eq "test_p1_pass_exits_0: exit code is 0 for schema_version=2 P1=PASS" "0" "$rc"
    assert_pass_if_clean "test_p1_pass_exits_0"
}

# ── test_p1_fail_exits_1 ───────────────────────────────────────────────────────
# JSON with schema_version=2 and P1=FAIL must exit 1
test_p1_fail_exits_1() {
    _snapshot_fail
    local rc=0
    echo '{"schema_version": 2, "P1": "FAIL"}' | bash "$SCRIPT" 2>/dev/null || rc=$?
    assert_eq "test_p1_fail_exits_1: exit code is 1 for schema_version=2 P1=FAIL" "1" "$rc"
    assert_pass_if_clean "test_p1_fail_exits_1"
}

# ── test_p1_blocked_exits_1 ───────────────────────────────────────────────────
# JSON with schema_version=2 and P1=BLOCKED must exit 1
test_p1_blocked_exits_1() {
    _snapshot_fail
    local rc=0
    echo '{"schema_version": 2, "P1": "BLOCKED"}' | bash "$SCRIPT" 2>/dev/null || rc=$?
    assert_eq "test_p1_blocked_exits_1: exit code is 1 for schema_version=2 P1=BLOCKED" "1" "$rc"
    assert_pass_if_clean "test_p1_blocked_exits_1"
}

# ── test_p1_inconclusive_exits_1 ──────────────────────────────────────────────
# JSON with schema_version=2 and P1=INCONCLUSIVE must exit 1
test_p1_inconclusive_exits_1() {
    _snapshot_fail
    local rc=0
    echo '{"schema_version": 2, "P1": "INCONCLUSIVE"}' | bash "$SCRIPT" 2>/dev/null || rc=$?
    assert_eq "test_p1_inconclusive_exits_1: exit code is 1 for schema_version=2 P1=INCONCLUSIVE" "1" "$rc"
    assert_pass_if_clean "test_p1_inconclusive_exits_1"
}

# ── test_missing_p1_legacy_compat_exits_0 ─────────────────────────────────────
# JSON with no P1 field but has overall_verdict=PASS (schema_version absent → legacy)
# must exit 0 via backward-compat shim (S1b).
# Prior to S1b this case exited 2; it now falls back to overall_verdict with a warning.
test_missing_p1_legacy_compat_exits_0() {
    _snapshot_fail
    local rc=0
    echo '{"overall_verdict": "PASS"}' | bash "$SCRIPT" 2>/dev/null || rc=$?
    assert_eq "test_missing_p1_legacy_compat_exits_0: exit code is 0 for legacy payload (no P1, overall_verdict=PASS)" "0" "$rc"
    assert_pass_if_clean "test_missing_p1_legacy_compat_exits_0"
}

# ── test_schema_v2_missing_p1_exits_2 ─────────────────────────────────────────
# JSON with schema_version=2 but no P1 field → non-conformant payload → exit 2
test_schema_v2_missing_p1_exits_2() {
    _snapshot_fail
    local rc=0
    echo '{"schema_version": 2, "overall_verdict": "PASS"}' | bash "$SCRIPT" 2>/dev/null || rc=$?
    assert_eq "test_schema_v2_missing_p1_exits_2: exit code is 2 for schema_version=2 payload missing P1 field" "2" "$rc"
    assert_pass_if_clean "test_schema_v2_missing_p1_exits_2"
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
test_missing_p1_legacy_compat_exits_0
test_schema_v2_missing_p1_exits_2
test_malformed_json_exits_2

print_summary
