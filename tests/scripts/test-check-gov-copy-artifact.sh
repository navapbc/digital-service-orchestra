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
_PLUGIN_ROOT="$(cd "$_SCRIPT_DIR/../../plugins/dso" && pwd)"

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
_EMPTY_TMP="$(mktemp "${TMPDIR:-/tmp}/gov-copy-empty.XXXXXX".yaml)"
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

# Test 6: wrong-source rejection (LLM bypass attempt)
# The validator enforces contract line 85: checks.source must equal the literal
# "deterministic-post-processor". An LLM that bypasses the post-processor and
# emits the checks block itself can satisfy a type-only check by writing any
# string. This fixture exercises that rejection (round-3 verification finding).
echo ""
echo "--- test: wrong checks.source rejected ---"
_WRONG_SRC_OUT=$(mktemp "${TMPDIR:-/tmp}/wrong-src-out.XXXXXX")
if "$VALIDATOR" "$FIXTURE_DIR/gov-copy-fail-wrong-source.yaml" >"$_WRONG_SRC_OUT" 2>&1; then
  fail "validator should reject checks.source != 'deterministic-post-processor'"
else
  pass "validator rejects wrong checks.source value"
  if grep -q 'deterministic-post-processor' "$_WRONG_SRC_OUT"; then
    pass "rejection diagnostic names the required source value"
  else
    fail "rejection diagnostic missing required source value reference; stderr: $(cat "$_WRONG_SRC_OUT")"
  fi
fi
rm -f "$_WRONG_SRC_OUT"

# Test 7: nested-dict errors-value rejection
# values.errors must be mapping of error key → STRING per contract. A nested
# dict value would be str()-coerced by _get_item_text, feeding garbage into
# readability/banned/voice scorers downstream. Validator must reject.
echo ""
echo "--- test: nested-dict errors value rejected ---"
_NESTED_OUT=$(mktemp "${TMPDIR:-/tmp}/nested-out.XXXXXX")
if "$VALIDATOR" "$FIXTURE_DIR/gov-copy-fail-errors-nested-dict.yaml" >"$_NESTED_OUT" 2>&1; then
  fail "validator should reject errors.<key> being a nested dict"
else
  pass "validator rejects nested-dict errors value"
  if grep -q "errors" "$_NESTED_OUT"; then
    pass "rejection diagnostic names the errors path"
  else
    fail "rejection diagnostic missing 'errors' reference; stderr: $(cat "$_NESTED_OUT")"
  fi
fi
rm -f "$_NESTED_OUT"

echo ""
echo "TOTAL: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
