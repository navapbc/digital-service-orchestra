#!/usr/bin/env bash
# Structural validation for the DSO NextJS Starter plugin install consent design document.
# Tests: existence of plugins/dso/docs/designs/dso-nextjs-starter-plugin-install.md,
#        required section headers, extraKnownMarketplaces reference, 'authoritative' keyword.
# RED test — assertions fail until the design document is created (task 0367-e46f).
set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
DESIGN_DOC="${REPO_ROOT}/plugins/dso/docs/designs/dso-nextjs-starter-plugin-install.md"

PASS=0
FAIL=0

pass() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

test_plugin_consent_doc_has_required_sections() {
  echo "=== test_plugin_consent_doc_has_required_sections ==="

  # Check 1: file exists
  if [ ! -f "$DESIGN_DOC" ]; then
    fail "Design doc not found: plugins/dso/docs/designs/dso-nextjs-starter-plugin-install.md"
    return
  fi
  pass "Design doc exists"

  # Check 2: contains Success Path or Failure Path section header
  if grep -qE '^## Success Path|^## Failure Path' "$DESIGN_DOC"; then
    pass "Design doc contains '## Success Path' or '## Failure Path' section header"
  else
    fail "Design doc missing '## Success Path' or '## Failure Path' section header"
  fi

  # Check 3: references extraKnownMarketplaces
  if grep -q 'extraKnownMarketplaces' "$DESIGN_DOC"; then
    pass "Design doc references 'extraKnownMarketplaces'"
  else
    fail "Design doc missing 'extraKnownMarketplaces' reference"
  fi

  # Check 4: contains word 'authoritative'
  if grep -q 'authoritative' "$DESIGN_DOC"; then
    pass "Design doc contains 'authoritative' (declares which path is authoritative)"
  else
    fail "Design doc missing 'authoritative' keyword"
  fi
}

test_plugin_consent_doc_has_required_sections

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
