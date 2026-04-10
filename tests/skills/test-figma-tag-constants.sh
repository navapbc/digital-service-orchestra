#!/usr/bin/env bash
# tests/skills/test-figma-tag-constants.sh
# Verifies that the shared Figma tag constants file exists, is sourceable,
# and exports the expected tag values for design collaboration workflow.
#
# Tests:
#   (a) File exists at expected path
#   (b) Contains TAG_AWAITING_IMPORT=design:awaiting_import
#   (c) Contains TAG_AWAITING_REVIEW=design:awaiting_review
#   (d) Contains TAG_APPROVED=design:approved
#   (e) File is sourceable in bash without errors
#   (f) Sourcing sets TAG_AWAITING_IMPORT to expected value
#   (g) Sourcing sets TAG_AWAITING_REVIEW to expected value
#   (h) Sourcing sets TAG_APPROVED to expected value
set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
CONSTANTS_FILE="${REPO_ROOT}/plugins/dso/skills/shared/constants/figma-tags.conf"

PASS=0
FAIL=0

pass() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

# ---------------------------------------------------------------------------
# Test (a): File exists at expected path
# ---------------------------------------------------------------------------
test_file_exists() {
  echo "=== test_file_exists ==="

  if [ -f "$CONSTANTS_FILE" ]; then
    pass "Constants file exists at plugins/dso/skills/shared/constants/figma-tags.conf"
  else
    fail "Constants file missing at plugins/dso/skills/shared/constants/figma-tags.conf"
  fi
}

# ---------------------------------------------------------------------------
# Test (b): Contains TAG_AWAITING_IMPORT=design:awaiting_import
# ---------------------------------------------------------------------------
test_contains_awaiting_import() {
  echo ""
  echo "=== test_contains_awaiting_import ==="

  if [ ! -f "$CONSTANTS_FILE" ]; then
    fail "Constants file missing — cannot check TAG_AWAITING_IMPORT definition"
    return
  fi

  if grep -qF "TAG_AWAITING_IMPORT=design:awaiting_import" "$CONSTANTS_FILE"; then
    pass "Constants file contains TAG_AWAITING_IMPORT=design:awaiting_import"
  else
    fail "Constants file missing TAG_AWAITING_IMPORT=design:awaiting_import"
  fi
}

# ---------------------------------------------------------------------------
# Test (c): Contains TAG_AWAITING_REVIEW=design:awaiting_review
# ---------------------------------------------------------------------------
test_contains_awaiting_review() {
  echo ""
  echo "=== test_contains_awaiting_review ==="

  if [ ! -f "$CONSTANTS_FILE" ]; then
    fail "Constants file missing — cannot check TAG_AWAITING_REVIEW definition"
    return
  fi

  if grep -qF "TAG_AWAITING_REVIEW=design:awaiting_review" "$CONSTANTS_FILE"; then
    pass "Constants file contains TAG_AWAITING_REVIEW=design:awaiting_review"
  else
    fail "Constants file missing TAG_AWAITING_REVIEW=design:awaiting_review"
  fi
}

# ---------------------------------------------------------------------------
# Test (d): Contains TAG_APPROVED=design:approved
# ---------------------------------------------------------------------------
test_contains_approved() {
  echo ""
  echo "=== test_contains_approved ==="

  if [ ! -f "$CONSTANTS_FILE" ]; then
    fail "Constants file missing — cannot check TAG_APPROVED definition"
    return
  fi

  if grep -qF "TAG_APPROVED=design:approved" "$CONSTANTS_FILE"; then
    pass "Constants file contains TAG_APPROVED=design:approved"
  else
    fail "Constants file missing TAG_APPROVED=design:approved"
  fi
}

# ---------------------------------------------------------------------------
# Test (e): File is sourceable in bash without errors
# ---------------------------------------------------------------------------
test_file_sourceable() {
  echo ""
  echo "=== test_file_sourceable ==="

  if [ ! -f "$CONSTANTS_FILE" ]; then
    fail "Constants file missing — cannot test sourcing"
    return
  fi

  if bash -c "source '$CONSTANTS_FILE'" 2>/dev/null; then
    pass "Constants file is sourceable in bash without errors"
  else
    fail "Constants file produced errors when sourced in bash"
  fi
}

# ---------------------------------------------------------------------------
# Test (f): Sourcing sets TAG_AWAITING_IMPORT to expected value
# ---------------------------------------------------------------------------
test_awaiting_import_value() {
  echo ""
  echo "=== test_awaiting_import_value ==="

  if [ ! -f "$CONSTANTS_FILE" ]; then
    fail "Constants file missing — cannot test TAG_AWAITING_IMPORT value"
    return
  fi

  actual=$(bash -c "source '$CONSTANTS_FILE' && printf '%s' \"\$TAG_AWAITING_IMPORT\"" 2>/dev/null)
  if [ "$actual" = "design:awaiting_import" ]; then
    pass "Sourcing sets TAG_AWAITING_IMPORT to 'design:awaiting_import'"
  else
    fail "TAG_AWAITING_IMPORT expected 'design:awaiting_import', got '${actual}'"
  fi
}

# ---------------------------------------------------------------------------
# Test (g): Sourcing sets TAG_AWAITING_REVIEW to expected value
# ---------------------------------------------------------------------------
test_awaiting_review_value() {
  echo ""
  echo "=== test_awaiting_review_value ==="

  if [ ! -f "$CONSTANTS_FILE" ]; then
    fail "Constants file missing — cannot test TAG_AWAITING_REVIEW value"
    return
  fi

  actual=$(bash -c "source '$CONSTANTS_FILE' && printf '%s' \"\$TAG_AWAITING_REVIEW\"" 2>/dev/null)
  if [ "$actual" = "design:awaiting_review" ]; then
    pass "Sourcing sets TAG_AWAITING_REVIEW to 'design:awaiting_review'"
  else
    fail "TAG_AWAITING_REVIEW expected 'design:awaiting_review', got '${actual}'"
  fi
}

# ---------------------------------------------------------------------------
# Test (h): Sourcing sets TAG_APPROVED to expected value
# ---------------------------------------------------------------------------
test_approved_value() {
  echo ""
  echo "=== test_approved_value ==="

  if [ ! -f "$CONSTANTS_FILE" ]; then
    fail "Constants file missing — cannot test TAG_APPROVED value"
    return
  fi

  actual=$(bash -c "source '$CONSTANTS_FILE' && printf '%s' \"\$TAG_APPROVED\"" 2>/dev/null)
  if [ "$actual" = "design:approved" ]; then
    pass "Sourcing sets TAG_APPROVED to 'design:approved'"
  else
    fail "TAG_APPROVED expected 'design:approved', got '${actual}'"
  fi
}

# ---------------------------------------------------------------------------
# Run all tests
# ---------------------------------------------------------------------------
test_file_exists
test_contains_awaiting_import
test_contains_awaiting_review
test_contains_approved
test_file_sourceable
test_awaiting_import_value
test_awaiting_review_value
test_approved_value

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
