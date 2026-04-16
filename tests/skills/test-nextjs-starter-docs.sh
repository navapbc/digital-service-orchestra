#!/usr/bin/env bash
# Structural validation for DSO NextJS Starter documentation artifacts.
# Tests: docs/onboarding.md existence + bootstrap section, plugins/dso/README.md existence +
#        NextJS Starter section, CLAUDE.md Bootstrap row presence.
# RED tests — all assertions fail until target documentation files are created.
set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
ONBOARDING_MD="${REPO_ROOT}/docs/onboarding.md"
DSO_README="${REPO_ROOT}/plugins/dso/README.md"
CLAUDE_MD="${REPO_ROOT}/CLAUDE.md"

PASS=0
FAIL=0

pass() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

test_onboarding_doc_exists() {
  echo "=== test_onboarding_doc_exists ==="
  if [ -f "$ONBOARDING_MD" ]; then
    pass "docs/onboarding.md exists"
  else
    fail "docs/onboarding.md not found"
  fi
}

test_onboarding_doc_has_bootstrap_section() {
  echo ""
  echo "=== test_onboarding_doc_has_bootstrap_section ==="
  if [ ! -f "$ONBOARDING_MD" ]; then
    fail "docs/onboarding.md missing — cannot check bootstrap section"
    return
  fi
  if grep -q 'curl -fsSL' "$ONBOARDING_MD"; then
    pass "docs/onboarding.md contains curl -fsSL bootstrap invocation"
  else
    fail "docs/onboarding.md missing curl -fsSL bootstrap invocation"
  fi
}

test_readme_exists() {
  echo ""
  echo "=== test_readme_exists ==="
  if [ -f "$DSO_README" ]; then
    pass "plugins/dso/README.md exists"
  else
    fail "plugins/dso/README.md not found"
  fi
}

test_readme_has_nextjs_starter_section() {
  echo ""
  echo "=== test_readme_has_nextjs_starter_section ==="
  if [ ! -f "$DSO_README" ]; then
    fail "plugins/dso/README.md missing — cannot check NextJS Starter section"
    return
  fi
  if grep -qiE 'nextjs-starter|NextJS Starter' "$DSO_README"; then
    pass "plugins/dso/README.md contains NextJS Starter section reference"
  else
    fail "plugins/dso/README.md missing NextJS Starter section reference"
  fi
}

test_claude_md_has_bootstrap_row() {
  echo ""
  echo "=== test_claude_md_has_bootstrap_row ==="
  # Rule 5 structural check: scope to the Quick Reference section only
  # (table row label, not prose body text) so the assertion is stable
  # under prose edits outside the table.
  if ! grep -q '## Quick Reference' "$CLAUDE_MD"; then
    fail "CLAUDE.md missing ## Quick Reference section"
    return
  fi
  local qr_section
  qr_section=$(awk '/^## Quick Reference/{flag=1; next} flag && /^## /{flag=0} flag' "$CLAUDE_MD")
  if echo "$qr_section" | grep -qi 'bootstrap'; then
    pass "CLAUDE.md Quick Reference table has Bootstrap row"
  else
    fail "CLAUDE.md Quick Reference table missing Bootstrap row"
  fi
}

# Run all tests
test_onboarding_doc_exists
test_onboarding_doc_has_bootstrap_section
test_readme_exists
test_readme_has_nextjs_starter_section
test_claude_md_has_bootstrap_row

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
