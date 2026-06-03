#!/usr/bin/env bash
_PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(git rev-parse --show-toplevel)/plugins/dso}"
# Structural validation for the Story Decomposition phase wiring.
# Pins: agent file present with opus + required fields; SKILL.md inserts the
# phase between Phase B and Phase C; explicit model: "opus" passed to dispatch;
# AGENTS.md registers the agent; no inline-drafting language remains.
set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
SKILL_DIR="${_PLUGIN_ROOT}/skills/preplanning"
SKILL_MD="$SKILL_DIR/SKILL.md"
AGENT="${_PLUGIN_ROOT}/agents/story-decomposer.md"
AGENTS_REGISTRY="${_PLUGIN_ROOT}/docs/AGENTS.md"

PASS=0
FAIL=0

pass() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

echo "=== Agent file present and configured ==="
if [[ -f "$AGENT" ]]; then
  pass "agents/story-decomposer.md exists"
else
  fail "agents/story-decomposer.md missing"
  echo "Cannot proceed without agent file."
  exit 1
fi

if grep -E '^model:\s*opus\b' "$AGENT" >/dev/null; then
  pass "story-decomposer frontmatter declares model: opus"
else
  fail "story-decomposer frontmatter does not declare model: opus"
fi

if grep -E '^name:\s*story-decomposer\b' "$AGENT" >/dev/null; then
  pass "story-decomposer frontmatter name matches file name"
else
  fail "story-decomposer frontmatter name does not match file name"
fi

echo ""
echo "=== Agent declares every placeholder it expects from the dispatcher ==="
for placeholder in epic-title epic-description epic-success-criteria existing-stories external-dep-stories escalation-policy; do
  if grep -q "{$placeholder}" "$AGENT"; then
    pass "agent declares placeholder {$placeholder}"
  else
    fail "agent missing placeholder {$placeholder}"
  fi
done

echo ""
echo "=== Agent output schema fields ==="
# Top-level output keys
for key in sc_coverage_plan story_drafts decomposition_notes; do
  if grep -q "\"$key\"" "$AGENT"; then
    pass "agent output declares '$key' top-level key"
  else
    fail "agent output missing '$key' top-level key"
  fi
done

# sc_coverage_plan verdict enum — every verdict must be reachable
for verdict in covered_by_existing partial_coverage uncovered out_of_scope_for_stories; do
  if grep -q "$verdict" "$AGENT"; then
    pass "sc_coverage_plan verdict enum includes '$verdict'"
  else
    fail "sc_coverage_plan verdict enum missing '$verdict'"
  fi
done

# story_drafts required fields
for field in temp_id title priority description done_definitions depends_on split_candidate escalation_policy; do
  if grep -q "\b$field\b" "$AGENT"; then
    pass "story_drafts entry declares '$field' field"
  else
    fail "story_drafts entry missing '$field' field"
  fi
done

# DD-to-SC traceability marker
if grep -q '← Satisfies: sc-' "$AGENT"; then
  pass "agent requires DDs to cite the SC id with '← Satisfies: sc-N'"
else
  fail "agent does not enforce DD-to-SC traceability marker"
fi

echo ""
echo "=== SKILL.md wires the new phase between B and C ==="
if grep -q '^## Story Decomposition' "$SKILL_MD"; then
  pass "SKILL.md has '## Story Decomposition' heading"
else
  fail "SKILL.md missing '## Story Decomposition' heading"
fi

# Ordering: the Story Decomposition heading must appear after Phase B and before Phase C.
phase_b_line=$(grep -n '^## Phase B:' "$SKILL_MD" | head -1 | cut -d: -f1)
decomp_line=$(grep -n '^## Story Decomposition' "$SKILL_MD" | head -1 | cut -d: -f1)
phase_c_line=$(grep -n '^## Phase C:' "$SKILL_MD" | head -1 | cut -d: -f1)

if [[ -n "$phase_b_line" && -n "$decomp_line" && -n "$phase_c_line" ]]; then
  if (( phase_b_line < decomp_line && decomp_line < phase_c_line )); then
    pass "Story Decomposition appears between Phase B (line $phase_b_line) and Phase C (line $phase_c_line) at line $decomp_line"
  else
    fail "Story Decomposition out of order: B=$phase_b_line, decomp=$decomp_line, C=$phase_c_line"
  fi
else
  fail "could not locate Phase B / Story Decomposition / Phase C headings (B=$phase_b_line, decomp=$decomp_line, C=$phase_c_line)"
fi

echo ""
echo "=== Dispatch wiring ==="
if grep -q 'dso:story-decomposer' "$SKILL_MD"; then
  pass "SKILL.md dispatches dso:story-decomposer"
else
  fail "SKILL.md missing dso:story-decomposer dispatch"
fi

# Extract the Story Decomposition section (from its heading up to the next ## heading)
# so subsequent checks are scoped to that section, not the whole file.
decomp_section=$(awk '
  /^## Story Decomposition/ { in_section = 1; print; next }
  in_section && /^## / { exit }
  in_section { print }
' "$SKILL_MD")
if echo "$decomp_section" | grep -qE 'model:\s*"opus"'; then
  pass "Story Decomposition section passes model: \"opus\" explicitly to dispatch"
else
  fail "Story Decomposition section does not pass model: \"opus\" explicitly (frontmatter default is not sufficient)"
fi

# Every placeholder the agent expects must appear in the dispatcher section.
for placeholder in epic-title epic-description epic-success-criteria existing-stories external-dep-stories escalation-policy; do
  if echo "$decomp_section" | grep -q "{$placeholder}"; then
    pass "dispatcher passes {$placeholder} to story-decomposer"
  else
    fail "dispatcher does not pass {$placeholder} to story-decomposer"
  fi
done

# Lightweight mode must skip this phase — lightweight epics do not create stories.
if echo "$decomp_section" | grep -qi 'lightweight'; then
  pass "Story Decomposition section documents --lightweight skip"
else
  fail "Story Decomposition section does not document --lightweight skip"
fi

# Halt semantics: failure must NOT fall back to inline drafting.
if echo "$decomp_section" | grep -qi 'HALT'; then
  pass "Story Decomposition section halts on agent failure (no inline-drafting fallback)"
else
  fail "Story Decomposition section does not declare halt-on-failure semantics"
fi

echo ""
echo "=== Phase overview list registers the new phase ==="
if grep -q '^- \*\*Story Decomposition\*\*' "$SKILL_MD"; then
  pass "phase overview list includes Story Decomposition"
else
  fail "phase overview list missing Story Decomposition bullet"
fi

echo ""
echo "=== Quick Reference table registers the new phase ==="
if grep -q '^| Story Decomposition |' "$SKILL_MD"; then
  pass "Quick Reference table includes Story Decomposition row"
else
  fail "Quick Reference table missing Story Decomposition row"
fi

echo ""
echo "=== AGENTS.md registers dso:story-decomposer ==="
if grep -q '`dso:story-decomposer`' "$AGENTS_REGISTRY"; then
  pass "AGENTS.md registers dso:story-decomposer"
else
  fail "AGENTS.md missing dso:story-decomposer row"
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
