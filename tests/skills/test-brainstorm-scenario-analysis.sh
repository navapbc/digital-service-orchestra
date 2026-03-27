#!/usr/bin/env bash
# Structural validation for brainstorm scenario analysis prompt templates and SKILL.md consistency.
# Tests: prompt file existence, placeholder consistency, output schema chain consistency,
# SKILL.md scenario analysis phase documentation, and differentiation from preplanning adversarial review.
set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
SKILL_DIR="${REPO_ROOT}/plugins/dso/skills/brainstorm"
RED_TEAM="$SKILL_DIR/prompts/scenario-red-team.md"
BLUE_TEAM="$SKILL_DIR/prompts/scenario-blue-team.md"
SKILL_MD="$SKILL_DIR/SKILL.md"

PASS=0
FAIL=0
SECTION="unknown"

pass() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
# fail() prints a machine-readable "FAIL: section_name" line (required by parse_failing_tests_from_output
# in red-zone.sh, which uses pattern '^FAIL: [a-zA-Z_][a-zA-Z0-9_-]*') followed by the human-readable
# message. The section name is set by each "=== section_name ===" block below.
fail() { echo "FAIL: ${SECTION}"; echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

echo "=== test_red_team_prompt_structure ==="
SECTION="test_red_team_prompt_structure"

# Verify prompt files exist
if [ -f "$RED_TEAM" ]; then
  pass "scenario-red-team.md prompt file exists"
else
  fail "scenario-red-team.md prompt file missing at $RED_TEAM"
fi

# Verify red team placeholders
for placeholder in epic-title epic-description approach; do
  if grep -q "{$placeholder}" "$RED_TEAM" 2>/dev/null; then
    pass "red team placeholder {$placeholder} present in prompt"
  else
    fail "red team placeholder {$placeholder} missing from prompt"
  fi
done

# Verify red team covers three named scenario categories
for category in runtime deployment configuration; do
  if grep -qi "$category" "$RED_TEAM" 2>/dev/null; then
    pass "red team prompt covers scenario category: $category"
  else
    fail "red team prompt missing scenario category: $category"
  fi
done

# Verify red team output schema fields
for field in category title description severity; do
  if grep -q "$field" "$RED_TEAM" 2>/dev/null; then
    pass "red team output schema includes '$field'"
  else
    fail "red team output schema missing '$field'"
  fi
done

echo ""
echo "=== test_blue_team_prompt_structure ==="
SECTION="test_blue_team_prompt_structure"

# Verify blue team prompt file exists
if [ -f "$BLUE_TEAM" ]; then
  pass "scenario-blue-team.md prompt file exists"
else
  fail "scenario-blue-team.md prompt file missing at $BLUE_TEAM"
fi

# Verify blue team placeholders
for placeholder in epic-title epic-description red-team-scenarios; do
  if grep -q "{$placeholder}" "$BLUE_TEAM" 2>/dev/null; then
    pass "blue team placeholder {$placeholder} present in prompt"
  else
    fail "blue team placeholder {$placeholder} missing from prompt"
  fi
done

# Verify blue team has filtering criteria section
if grep -qi "filter" "$BLUE_TEAM" 2>/dev/null; then
  pass "blue team prompt has filtering criteria section"
else
  fail "blue team prompt missing filtering criteria section"
fi

# Verify blue team preserves red team fields
for field in category title description severity; do
  if grep -q "$field" "$BLUE_TEAM" 2>/dev/null; then
    pass "blue team schema chain preserves '$field' from red team"
  else
    fail "blue team schema chain missing '$field' (should preserve from red team)"
  fi
done

# Verify blue team adds its own fields
for field in disposition filter_rationale; do
  if grep -q "$field" "$BLUE_TEAM" 2>/dev/null; then
    pass "blue team adds output field '$field'"
  else
    fail "blue team missing output field '$field'"
  fi
done

echo ""
echo "=== test_skill_md_scenario_analysis ==="
SECTION="test_skill_md_scenario_analysis"

# REVIEW-DEFENSE: The two tests below are intentionally RED in this batch. SKILL.md integration of
# the Scenario Analysis phase is the subject of a separate implementation task (c846-99c2) scheduled
# in a future sprint batch. The .test-index RED marker [test_skill_md_scenario_analysis] scopes
# RED-zone tolerance to this section only — the prompt file structure tests above
# (test_red_team_prompt_structure and test_blue_team_prompt_structure) remain GREEN and blocking.
# These tests will become GREEN when SKILL.md is updated in task c846-99c2.

# Verify SKILL.md references Scenario Analysis phase (heading pattern)
if grep -qi "Scenario Analysis" "$SKILL_MD"; then
  pass "SKILL.md references Scenario Analysis phase"
else
  fail "SKILL.md missing Scenario Analysis phase heading"
fi

# Verify SKILL.md documents complexity threshold numbers for scenario analysis
# Both threshold numbers (e.g. "3" stories or "COMPLEX") and conditional directives
# Use grep-based approach: extract scenario analysis section then check for threshold + conditional
_scenario_section=$(grep -A 50 -i "Scenario Analysis" "$SKILL_MD" 2>/dev/null | head -60 || true)
_has_threshold=false
_has_conditional=false
if echo "$_scenario_section" | grep -qE '[0-9]+'; then
  _has_threshold=true
fi
if echo "$_scenario_section" | grep -qiE '\b(only|when|if|threshold|COMPLEX|MODERATE|score)\b'; then
  _has_conditional=true
fi
if [ "$_has_threshold" = "true" ] && [ "$_has_conditional" = "true" ]; then
  pass "SKILL.md documents complexity threshold with numbers and conditional directives for scenario analysis"
else
  fail "SKILL.md missing complexity threshold numbers or conditional directives for scenario analysis"
fi

# Verify SKILL.md differentiates brainstorm scenario analysis from preplanning adversarial review
# (must reference preplanning or adversarial review to show differentiation)
if grep -qi "preplanning\|adversarial" "$SKILL_MD"; then
  pass "SKILL.md differentiates brainstorm scenario analysis from preplanning adversarial review"
else
  fail "SKILL.md missing differentiation from preplanning adversarial review"
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
