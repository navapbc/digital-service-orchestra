#!/usr/bin/env bash
_PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../..}"
# Structural validation for adversarial review prompt templates and SKILL.md consistency.
# Tests: placeholder consistency, output-input schema chain consistency.
set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
SKILL_DIR="${_PLUGIN_ROOT}/skills/preplanning"
RED_TEAM="$SKILL_DIR/prompts/red-team-review.md"
BLUE_TEAM="$SKILL_DIR/prompts/blue-team-review.md"
SKILL_MD="$SKILL_DIR/SKILL.md"

PASS=0
FAIL=0

pass() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

echo "=== Red team placeholder consistency ==="
# Verify red team prompt has all placeholders referenced in SKILL.md Phase 2.5
for placeholder in epic-title epic-description story-map risk-register dependency-graph; do
  if grep -q "{$placeholder}" "$RED_TEAM"; then
    pass "red team placeholder {$placeholder} present in prompt"
  else
    fail "red team placeholder {$placeholder} missing from prompt"
  fi
done

echo ""
echo "=== Blue team placeholder consistency ==="
# Verify blue team prompt has all placeholders referenced in SKILL.md Phase 2.5
for placeholder in epic-title epic-description story-map red-team-findings; do
  if grep -q "{$placeholder}" "$BLUE_TEAM"; then
    pass "blue team placeholder {$placeholder} present in prompt"
  else
    fail "blue team placeholder {$placeholder} missing from prompt"
  fi
done

echo ""
echo "=== SKILL.md references dedicated agent dispatch ==="
if grep -q "dso:red-team-reviewer" "$SKILL_MD"; then
  pass "SKILL.md dispatches dso:red-team-reviewer dedicated agent"
else
  fail "SKILL.md missing dso:red-team-reviewer dispatch"
fi

if grep -q "dso:blue-team-filter" "$SKILL_MD"; then
  pass "SKILL.md dispatches dso:blue-team-filter dedicated agent"
else
  fail "SKILL.md missing dso:blue-team-filter dispatch"
fi

echo ""
echo "=== Output-input schema chain consistency ==="
# Red team output schema fields must match blue team input expectations.
# Red team outputs: type, target_story_id, title, description, rationale, taxonomy_category
# Blue team receives {red-team-findings} which is the red team output.
# Blue team adds: disposition, rejection_rationale

# Verify red team defines all required output fields
for field in type target_story_id title description rationale taxonomy_category; do
  if grep -q "$field" "$RED_TEAM"; then
    pass "red team output schema includes '$field'"
  else
    fail "red team output schema missing '$field'"
  fi
done

# Verify blue team references the same fields (it preserves them)
for field in type target_story_id title description rationale taxonomy_category; do
  if grep -q "$field" "$BLUE_TEAM"; then
    pass "blue team schema chain preserves '$field'"
  else
    fail "blue team schema chain missing '$field' (should preserve from red team)"
  fi
done

# Verify blue team adds its own fields
for field in disposition rejection_rationale; do
  if grep -q "$field" "$BLUE_TEAM"; then
    pass "blue team adds output field '$field'"
  else
    fail "blue team missing output field '$field'"
  fi
done

# Verify SKILL.md Phase 2.5 references all four amendment types that match red team output types
echo ""
echo "=== SKILL.md amendment type coverage ==="
for amendment in "new_story|new story" "modify_done_definition|done def" "add_dependency|new.*depend" "add_consideration|consideration"; do
  if grep -qiE "$amendment" "$SKILL_MD"; then
    pass "SKILL.md covers amendment type matching: $amendment"
  else
    fail "SKILL.md missing amendment type: $amendment"
  fi
done

echo ""
echo "=== Step 5 unambiguous confirmation ==="
# The Step 5 final review prompt must NOT contain paired contradictory questions
# where 'yes' means approval for one but disapproval for the other.
# The prose template block should not contain both "capture your vision" and
# "Should we adjust" in the same sentence — this creates a yes/no ambiguity.
if grep -q "Should we adjust any priorities before I finalize" "$SKILL_MD"; then
  fail "Step 5 contains ambiguous paired question 'Should we adjust any priorities before I finalize' — remove it; AskUserQuestion handles approval unambiguously"
else
  pass "Step 5 does not contain ambiguous paired confirmation question"
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
