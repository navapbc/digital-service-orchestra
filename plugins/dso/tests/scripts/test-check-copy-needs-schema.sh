#!/usr/bin/env bash
# test-check-copy-needs-schema.sh
# Unit tests for check-copy-needs-schema.sh
#
# Covers story b6cd-8443-b458-4c50 (Copy Needs schema), task 7bb1-524b-fc4f-4b63.
# DDs tested:
#   dd-6: unit tests written and passing for all new or modified logic
#
# RED markers: test_copy_needs_pass, test_copy_needs_fail_missing_field, test_copy_needs_fail_unknown_page
# These tests are RED on first run because check-copy-needs-schema.sh (task ba23) is not yet implemented.
set -euo pipefail

_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_PLUGIN_ROOT="$(cd "$_SCRIPT_DIR/../.." && pwd)"

VALIDATOR="$_PLUGIN_ROOT/scripts/check-copy-needs-schema.sh"
FIXTURE_DIR="$_SCRIPT_DIR/fixtures"

PASS=0
FAIL=0

pass() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

echo "=== copy-needs schema validator tests ==="

# Prerequisite: validator script must exist and be executable
echo ""
echo "--- prerequisite: validator exists and is executable ---"
if [[ -x "$VALIDATOR" ]]; then
  pass "validator script exists and is executable"
else
  fail "validator not found or not executable at: $VALIDATOR"
  echo "TOTAL: $PASS passed, $FAIL failed"
  exit 1
fi

# [test_copy_needs_pass] — passing fixture validates (exit 0)
echo ""
echo "--- test: passing fixture (test_copy_needs_pass) ---"
if "$VALIDATOR" "$FIXTURE_DIR/copy-needs-pass.md" >/dev/null 2>&1; then
  pass "passing fixture exits 0"
else
  fail "passing fixture unexpectedly rejected (exit non-zero)"
fi

# [test_copy_needs_fail_missing_field] — missing required field is rejected (exit non-zero)
echo ""
echo "--- test: missing required field fixture (test_copy_needs_fail_missing_field) ---"
if "$VALIDATOR" "$FIXTURE_DIR/copy-needs-fail-missing-field.md" >/dev/null 2>&1; then
  fail "missing-field fixture unexpectedly accepted (should be rejected)"
else
  pass "missing-field fixture correctly rejected"
fi

# [test_copy_needs_fail_unknown_page] — unknown page identifier is rejected (exit non-zero)
echo ""
echo "--- test: unknown page identifier fixture (test_copy_needs_fail_unknown_page) ---"
if "$VALIDATOR" "$FIXTURE_DIR/copy-needs-fail-unknown-page.md" >/dev/null 2>&1; then
  fail "unknown-page fixture unexpectedly accepted (should be rejected)"
else
  pass "unknown-page fixture correctly rejected"
fi

echo ""
echo "TOTAL: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
