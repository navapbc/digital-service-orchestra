#!/usr/bin/env bash
_PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../..}"
# Structural validation for Phase E adversarial review wiring.
# Validates the LIVE agent files and the phase-e dispatcher prompt — the older
# prompts/red-team-review.md and prompts/blue-team-review.md copies were removed
# (only this test ever referenced them).
set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
SKILL_DIR="${_PLUGIN_ROOT}/skills/preplanning"
RED_TEAM_AGENT="${_PLUGIN_ROOT}/agents/red-team-reviewer.md"
BLUE_TEAM_AGENT="${_PLUGIN_ROOT}/agents/blue-team-filter.md"
PHASE_E="$SKILL_DIR/prompts/phase-e-adversarial-review.md"
SKILL_MD="$SKILL_DIR/SKILL.md"

PASS=0
FAIL=0

pass() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

echo "=== Red team placeholder consistency ==="
# The red team agent must receive every placeholder the dispatcher passes,
# including the new epic-success-criteria placeholder for the SC→DD audit.
for placeholder in epic-title epic-description epic-success-criteria story-map risk-register dependency-graph; do
  if grep -q "{$placeholder}" "$RED_TEAM_AGENT"; then
    pass "red team agent declares placeholder {$placeholder}"
  else
    fail "red team agent missing placeholder {$placeholder}"
  fi
done

echo ""
echo "=== Blue team placeholder consistency ==="
for placeholder in epic-title epic-description story-map red-team-findings; do
  if grep -q "{$placeholder}" "$BLUE_TEAM_AGENT"; then
    pass "blue team agent declares placeholder {$placeholder}"
  else
    fail "blue team agent missing placeholder {$placeholder}"
  fi
done

echo ""
echo "=== Phase-E dispatcher passes every placeholder ==="
for placeholder in epic-title epic-description epic-success-criteria story-map risk-register dependency-graph; do
  if grep -q "{$placeholder}" "$PHASE_E"; then
    pass "phase-e dispatcher passes {$placeholder}"
  else
    fail "phase-e dispatcher does not pass {$placeholder}"
  fi
done

echo ""
echo "=== Phase-E dispatch wiring ==="
if grep -q "dso:red-team-reviewer" "$PHASE_E"; then
  pass "phase-e dispatches dso:red-team-reviewer"
else
  fail "phase-e missing dso:red-team-reviewer dispatch"
fi

if grep -q "dso:blue-team-filter" "$PHASE_E"; then
  pass "phase-e dispatches dso:blue-team-filter"
else
  fail "phase-e missing dso:blue-team-filter dispatch"
fi

# Model enforcement: opus must be passed explicitly to the red team dispatch,
# not just relied on via agent frontmatter. The dispatcher line must combine
# the named subagent_type with an explicit model: "opus" parameter.
if grep -E 'subagent_type:\s*"?dso:red-team-reviewer"?.*model:\s*"opus"|model:\s*"opus".*dso:red-team-reviewer' "$PHASE_E" >/dev/null; then
  pass "phase-e passes model: \"opus\" explicitly to red team dispatch"
else
  fail "phase-e does not pass model: \"opus\" explicitly to red team dispatch (frontmatter default is not sufficient)"
fi

# Red team agent frontmatter must declare opus.
if grep -E '^model:\s*opus\b' "$RED_TEAM_AGENT" >/dev/null; then
  pass "red team agent frontmatter declares model: opus"
else
  fail "red team agent frontmatter does not declare model: opus"
fi

echo ""
echo "=== SKILL.md references Phase E dispatch ==="
if grep -q "dso:red-team-reviewer" "$SKILL_MD"; then
  pass "SKILL.md references dso:red-team-reviewer"
else
  fail "SKILL.md missing dso:red-team-reviewer reference"
fi

if grep -q "dso:blue-team-filter" "$SKILL_MD"; then
  pass "SKILL.md references dso:blue-team-filter"
else
  fail "SKILL.md missing dso:blue-team-filter reference"
fi

echo ""
echo "=== Red team output schema fields ==="
for field in type target_story_id title description rationale taxonomy_category; do
  if grep -q "$field" "$RED_TEAM_AGENT"; then
    pass "red team output schema includes '$field'"
  else
    fail "red team output schema missing '$field'"
  fi
done

# SC coverage audit is a load-bearing addition — the agent must declare both
# the new taxonomy_category value and the required sc_coverage_summary block.
if grep -q "sc_coverage_gap" "$RED_TEAM_AGENT"; then
  pass "red team output schema includes 'sc_coverage_gap' taxonomy_category"
else
  fail "red team output schema missing 'sc_coverage_gap' taxonomy_category"
fi

if grep -q "sc_coverage_summary" "$RED_TEAM_AGENT"; then
  pass "red team output requires 'sc_coverage_summary' block"
else
  fail "red team output missing 'sc_coverage_summary' block"
fi

# Verdict enum for SC coverage summary must enumerate every classification the
# protocol uses; missing one would let the agent silently drop a class.
for verdict in fully_covered partially_covered uncovered out_of_scope_for_stories; do
  if grep -q "$verdict" "$RED_TEAM_AGENT"; then
    pass "red team SC verdict enum includes '$verdict'"
  else
    fail "red team SC verdict enum missing '$verdict'"
  fi
done

echo ""
echo "=== Blue team schema chain preserves red team fields ==="
for field in type target_story_id title description rationale taxonomy_category; do
  if grep -q "$field" "$BLUE_TEAM_AGENT"; then
    pass "blue team preserves '$field'"
  else
    fail "blue team missing '$field' (should preserve from red team)"
  fi
done

# Blue team must acknowledge the new SC-coverage category in its pass-through
# rules so accept/reject rationale can reference it.
if grep -q "sc_coverage_gap" "$BLUE_TEAM_AGENT"; then
  pass "blue team acknowledges 'sc_coverage_gap' pass-through"
else
  fail "blue team does not acknowledge 'sc_coverage_gap' pass-through"
fi

for field in disposition rejection_rationale; do
  if grep -q "$field" "$BLUE_TEAM_AGENT"; then
    pass "blue team adds output field '$field'"
  else
    fail "blue team missing output field '$field'"
  fi
done

echo ""
echo "=== Phase-E amendment type coverage ==="
# The dispatcher must route every red team type the schema declares.
for amendment in "new_story|new story" "modify_done_definition|done def" "add_dependency|new.*depend" "add_consideration|consideration" "escalate_to_epic"; do
  if grep -qiE "$amendment" "$PHASE_E"; then
    pass "phase-e covers amendment type matching: $amendment"
  else
    fail "phase-e missing amendment type: $amendment"
  fi
done

echo ""
echo "=== Step 5 unambiguous confirmation ==="
# Regression guard: paired contradictory question previously made yes/no
# approval ambiguous. AskUserQuestion now handles approval directly.
if grep -q "Should we adjust any priorities before I finalize" "$SKILL_MD"; then
  fail "SKILL.md contains ambiguous paired question 'Should we adjust any priorities before I finalize' — remove it; AskUserQuestion handles approval unambiguously"
else
  pass "SKILL.md does not contain ambiguous paired confirmation question"
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
