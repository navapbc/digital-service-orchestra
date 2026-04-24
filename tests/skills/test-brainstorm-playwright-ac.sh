#!/usr/bin/env bash
# Structural boundary test for brainstorm SKILL.md Playwright AC injection in Step 2.26.
# Tests: SKILL.md exists, Step 2.26 references Playwright, URL pattern detection,
# Playwright assertion stub format, and Cross-Epic Interactions section presence.
# testing_mode=RED
set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
SKILL_MD="${REPO_ROOT}/plugins/dso/skills/brainstorm/SKILL.md"

# skill-refactor: brainstorm phases extracted. Rebind SKILL_MD to the aggregated
# corpus so content moved to phases/*.md remains reachable by content-presence greps.
# Tests that assert SKILL.md-specific structure should use "$_origSKILL_MD" instead.
_origSKILL_MD="$SKILL_MD"
source "$(git rev-parse --show-toplevel)/tests/skills/lib/brainstorm-skill-aggregate.sh"
SKILL_MD=$(brainstorm_aggregate_path)
trap brainstorm_aggregate_cleanup EXIT


PASS=0
FAIL=0
SECTION="unknown"

pass() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
# fail() prints a machine-readable "FAIL: section_name" line (required by parse_failing_tests_from_output
# in red-zone.sh, which uses pattern '^FAIL: [a-zA-Z_][a-zA-Z0-9_-]*') followed by the human-readable
# message. The section name is set by each "=== section_name ===" block below.
fail() { echo "FAIL: ${SECTION}"; echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

echo "=== test_skill_md_exists ==="
SECTION="test_skill_md_exists"

if [ -f "$SKILL_MD" ]; then
  pass "plugins/dso/skills/brainstorm/SKILL.md exists"
else
  fail "plugins/dso/skills/brainstorm/SKILL.md does not exist at $SKILL_MD"
fi

echo ""
echo "=== test_step_2_26_playwright_reference ==="
SECTION="test_step_2_26_playwright_reference"

# Step 2.26 must reference Playwright assertion for URL-type consideration ACs
if grep -q "Playwright" "$SKILL_MD"; then
  pass "SKILL.md references Playwright assertion (Step 2.26 AC injection)"
else
  fail "SKILL.md missing Playwright reference — Step 2.26 must document Playwright assertion stub for navigable URL ACs"
fi

echo ""
echo "=== test_url_pattern_detection ==="
SECTION="test_url_pattern_detection"

# SKILL.md must document URL pattern detection for shared_resource classification
if grep -qE "navigable URL|URL pattern|shared_resource.*http|http.*shared_resource|starts with .?/" "$SKILL_MD"; then
  pass "SKILL.md contains URL pattern detection logic (navigable URL classification)"
else
  fail "SKILL.md missing URL pattern detection — Step 2.26 must classify shared_resource URLs as navigable"
fi

echo ""
echo "=== test_playwright_assertion_stub_format ==="
SECTION="test_playwright_assertion_stub_format"

# SKILL.md must contain the Playwright assertion stub with page.goto or expect(page)
if grep -qE "page\.goto|expect\(page\)" "$SKILL_MD"; then
  pass "SKILL.md contains Playwright assertion stub format (page.goto or expect(page))"
else
  fail "SKILL.md missing Playwright assertion stub format — expected 'page.goto' or 'expect(page)' in Step 2.26"
fi

echo ""
echo "=== test_cross_epic_interactions_section ==="
SECTION="test_cross_epic_interactions_section"

# SKILL.md must reference the Cross-Epic Interactions section that Step 2.26 populates
if grep -q "Cross-Epic Interactions" "$SKILL_MD"; then
  pass "SKILL.md references '## Cross-Epic Interactions' section (Step 2.26 AC target)"
else
  fail "SKILL.md missing '## Cross-Epic Interactions' section reference — Step 2.26 must document this AC section"
fi

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
