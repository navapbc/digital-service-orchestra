#!/usr/bin/env bash
# Structural validation for consumer_completeness dimension in Scope fidelity reviewer.
# Tests: presence of consumer_completeness JSON schema key in scope.md output contract.
# Rule 5 compliant: checks JSON schema key (required field in output contract), not body text.
# RED test — fails until consumer_completeness is added to scope.md JSON schema in task d954-d23a.
set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
SCOPE_MD="${REPO_ROOT}/plugins/dso/skills/shared/docs/reviewers/scope.md"

PASS=0
FAIL=0

pass() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

# ---------------------------------------------------------------------------
# Test 1: scope.md output contract schema defines consumer_completeness dimension key
# (Rule 5 contract schema validation — JSON output contract key, not body text)
# ---------------------------------------------------------------------------
test_scope_reviewer_has_consumer_completeness_dimension() {
  echo "=== test_scope_reviewer_has_consumer_completeness_dimension ==="

  if [ ! -f "$SCOPE_MD" ]; then
    fail "scope.md missing — cannot check for consumer_completeness dimension key"
    return
  fi

  if grep -q '"consumer_completeness":' "$SCOPE_MD"; then
    pass "scope.md JSON schema includes consumer_completeness dimension key"
  else
    fail "scope.md JSON schema missing consumer_completeness dimension key"
  fi
}

# ---------------------------------------------------------------------------
# Run all tests
# ---------------------------------------------------------------------------
test_scope_reviewer_has_consumer_completeness_dimension

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "=== Results ==="
echo "Passed: $PASS"
echo "Failed: $FAIL"

if [ "$FAIL" -gt 0 ]; then
  echo "VALIDATION FAILED"
  exit 1
fi

echo "ALL VALIDATIONS PASSED"
exit 0
