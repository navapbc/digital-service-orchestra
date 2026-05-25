#!/usr/bin/env bash
# test-check-gov-copy-artifact.sh
# Unit tests for check-gov-copy-artifact.sh
#
# Covers story 26a7-830c-77a2-479a (gov-copy artifact schema).
# DDs tested:
#   dd-4: validator accepts conforming artifact (exit 0)
#   dd-5: validator rejects missing required field (exit non-zero)
#   dd-5: validator rejects wrong type (exit non-zero)
#   dd-5: validator accepts empty items[] (degenerate but valid)
set -euo pipefail

_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_PLUGIN_ROOT="$(cd "$_SCRIPT_DIR/../.." && pwd)"

VALIDATOR="$_PLUGIN_ROOT/scripts/check-gov-copy-artifact.sh"
FIXTURE_DIR="$_SCRIPT_DIR/fixtures"

PASS=0
FAIL=0

pass() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

echo "=== gov-copy artifact validator tests ==="

# Test: validator script exists and is executable
echo ""
echo "--- prerequisite: validator exists and is executable ---"
if [[ -x "$VALIDATOR" ]]; then
  pass "validator script exists and is executable"
else
  fail "validator not found or not executable at: $VALIDATOR"
  echo "TOTAL: $PASS passed, $FAIL failed"
  exit 1
fi

# Test 1: passing fixture validates (exit 0)
echo ""
echo "--- test: passing fixture ---"
if "$VALIDATOR" "$FIXTURE_DIR/gov-copy-pass.yaml" >/dev/null 2>&1; then
  pass "passing fixture exits 0"
else
  fail "passing fixture unexpectedly rejected (exit non-zero)"
fi

# Test 2: fail-missing-field fixture is rejected (exit non-zero)
echo ""
echo "--- test: missing required field fixture ---"
if "$VALIDATOR" "$FIXTURE_DIR/gov-copy-fail-missing-field.yaml" >/dev/null 2>&1; then
  fail "missing-field fixture unexpectedly accepted (should be rejected)"
else
  pass "missing-field fixture correctly rejected"
fi

# Test 3: fail-bad-type fixture is rejected (exit non-zero)
echo ""
echo "--- test: bad type fixture ---"
if "$VALIDATOR" "$FIXTURE_DIR/gov-copy-fail-bad-type.yaml" >/dev/null 2>&1; then
  fail "bad-type fixture unexpectedly accepted (should be rejected)"
else
  pass "bad-type fixture correctly rejected"
fi

# Test 4: empty items[] is valid (degenerate case)
echo ""
echo "--- test: empty items[] fixture ---"
_EMPTY_TMP="$(mktemp /tmp/gov-copy-empty.XXXXXX.yaml)"
cat > "$_EMPTY_TMP" <<'YAML'
schema_version: 1
items: []
YAML
if "$VALIDATOR" "$_EMPTY_TMP" >/dev/null 2>&1; then
  pass "empty items[] fixture exits 0 (degenerate valid)"
else
  fail "empty items[] fixture unexpectedly rejected"
fi
rm -f "$_EMPTY_TMP"

# Test 5: missing file argument exits non-zero with error message
echo ""
echo "--- test: missing file argument ---"
if "$VALIDATOR" >/dev/null 2>&1; then
  fail "no-argument invocation should exit non-zero"
else
  pass "no-argument invocation exits non-zero"
fi

echo ""
echo "TOTAL: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
