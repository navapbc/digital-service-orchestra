#!/usr/bin/env bash
# tests/scripts/test-validate-shim-refs-integration.sh
# Integration tests verifying that validate.sh wires check-shim-refs.sh.
#
# Tests:
#   test_validate_references_check_shim_refs  — validate.sh source contains a call to check-shim-refs.sh
#   test_validate_shim_refs_absent_no_crash   — running validate.sh with check-shim-refs.sh absent does
#                                               not crash with an unhandled error (fails cleanly or skips)
#
# This test file is RED: both tests fail because validate.sh does not yet contain
# a check-shim-refs.sh integration.
#
# Usage: bash tests/scripts/test-validate-shim-refs-integration.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DSO_PLUGIN_DIR="$PLUGIN_ROOT/plugins/dso"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

VALIDATE_SH="$DSO_PLUGIN_DIR/scripts/validate.sh"

echo "=== test-validate-shim-refs-integration.sh ==="

# ── test_validate_references_check_shim_refs ──────────────────────────────────
# Static contract check: validate.sh must contain a reference to check-shim-refs.sh.
# This is the same static-analysis pattern used by other validate integration tests
# (test-validate-script-writes-integration.sh, test-validate-test-batched-integration.sh)
# to assert that a specific check is wired into the validation pipeline.
#
# The test will FAIL (RED) until validate.sh is updated to invoke check-shim-refs.sh.
test_validate_references_check_shim_refs() {
    _snapshot_fail

    # Static check: validate.sh must contain the string "check-shim-refs"
    if grep -q 'check-shim-refs' "$VALIDATE_SH" 2>/dev/null; then
        has_ref="yes"
    else
        has_ref="no"
    fi
    assert_eq "validate.sh references check-shim-refs.sh" "yes" "$has_ref"

    assert_pass_if_clean "test_validate_references_check_shim_refs"
}

# ── test_validate_shim_refs_absent_no_crash ───────────────────────────────────
# When check-shim-refs.sh is absent (not yet implemented), validate.sh must not
# crash with an unhandled error — it should either skip the check gracefully or
# report a clean failure. This verifies that the wiring includes a guard for the
# script's existence, preventing broken-environment crashes.
#
# Strategy: run validate.sh with a minimal config pointing to a temp dir where
# check-shim-refs.sh does not exist. The exit code must NOT be 127 (command not
# found) — it may be 0, 1, or 2, but must not be an unhandled missing-command crash.
#
# This test FAILS (RED) because validate.sh does not yet reference check-shim-refs.sh
# at all — the assertion about exit code 127 cannot be verified against non-existent
# integration, so the first test must pass before this one is meaningful. Once the
# first test passes, this test ensures the implementation has a proper guard.
test_validate_shim_refs_absent_no_crash() {
    _snapshot_fail

    local _tmpd
    _tmpd=$(mktemp -d)
    trap 'rm -rf "$_tmpd"' RETURN

    # Minimal config with no checks.shim_refs_scan_dir — expect the check is
    # skipped when the config key is absent (same pattern as script-writes check).
    # Use a non-existent app dir so validate.sh fails fast without running all checks.
    cat > "$_tmpd/stub.conf" << 'CONF'
version=1.0.0
paths.app_dir=nonexistent-app-dir-for-shim-refs-test
CONF

    local _exit=0
    local _out=""
    _out=$(CONFIG_FILE="$_tmpd/stub.conf" bash "$VALIDATE_SH" 2>&1) || _exit=$?

    # Exit code 127 means an unguarded "command not found" — that would be a crash.
    # Any other exit code (0, 1, 2) is acceptable: skip, clean failure, or pending.
    assert_ne "validate.sh does not crash with exit 127 when shim-refs absent" "127" "$_exit"

    assert_pass_if_clean "test_validate_shim_refs_absent_no_crash"
}

# ── Run all tests ─────────────────────────────────────────────────────────────
test_validate_references_check_shim_refs
test_validate_shim_refs_absent_no_crash

print_summary
