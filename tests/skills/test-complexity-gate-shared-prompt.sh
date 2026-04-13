#!/usr/bin/env bash
# Structural boundary validation for the complexity-gate shared prompt.
# Tests: prompt file existence, required gate keywords, and consumer SKILL.md/agent references.
# These are RED tests — all assertions fail until complexity-gate.md is created
# and brainstorm/implementation-plan SKILL.md + approach-decision-maker.md are updated.
set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
COMPLEXITY_GATE_MD="${REPO_ROOT}/plugins/dso/skills/shared/prompts/complexity-gate.md"
BRAINSTORM_MD="${REPO_ROOT}/plugins/dso/skills/brainstorm/SKILL.md"
IMPL_PLAN_MD="${REPO_ROOT}/plugins/dso/skills/implementation-plan/SKILL.md"
APPROACH_DM_MD="${REPO_ROOT}/plugins/dso/agents/approach-decision-maker.md"

PASS=0
FAIL=0

pass() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

# ---------------------------------------------------------------------------
# Test 1: complexity-gate.md exists and is non-empty
# ---------------------------------------------------------------------------
test_complexity_gate_file_exists() {
  echo "=== test_complexity_gate_file_exists ==="

  if [ -s "$COMPLEXITY_GATE_MD" ] && grep -qiE "^## Gate 1|^## YAGNI" "$COMPLEXITY_GATE_MD"; then
    pass "complexity-gate.md exists and has required gate section heading (Gate 1/YAGNI)"
  else
    fail "complexity-gate.md missing or does not contain required gate section heading"
  fi
}

# ---------------------------------------------------------------------------
# Test 2: Required content keywords present in complexity-gate.md
# ---------------------------------------------------------------------------
test_complexity_gate_required_content() {
  echo ""
  echo "=== test_complexity_gate_required_content ==="

  if [ ! -f "$COMPLEXITY_GATE_MD" ]; then
    fail "complexity-gate.md missing — cannot check '## Output Format' heading"
    fail "complexity-gate.md missing — cannot check YAGNI gate heading"
    fail "complexity-gate.md missing — cannot check Rule of Three gate heading"
    fail "complexity-gate.md missing — cannot check Dependency Cost gate heading"
    fail "complexity-gate.md missing — cannot check Scale Threshold/Profiling gate heading"
    fail "complexity-gate.md missing — cannot check LLM Self-Audit gate heading"
    fail "complexity-gate.md missing — cannot check Justified-Complexity heading"
    fail "complexity-gate.md missing — cannot check Sandbagging prohibition heading"
    return
  fi

  # GATE/CHECKED/FINDING/VERDICT format — check for '## Output Format' section heading
  if grep -q "^## Output Format" "$COMPLEXITY_GATE_MD"; then
    pass "complexity-gate.md has '## Output Format' section heading (GATE/CHECKED/FINDING/VERDICT schema)"
  else
    fail "complexity-gate.md missing '## Output Format' section heading"
  fi

  # YAGNI gate — check for gate section heading
  if grep -qiE "^## Gate 1|^##.*YAGNI" "$COMPLEXITY_GATE_MD"; then
    pass "complexity-gate.md has YAGNI gate section heading"
  else
    fail "complexity-gate.md missing YAGNI gate section heading"
  fi

  # Rule of Three gate — check for gate section heading
  if grep -qiE "^## Gate 2|^##.*Rule of Three" "$COMPLEXITY_GATE_MD"; then
    pass "complexity-gate.md has Rule of Three gate section heading"
  else
    fail "complexity-gate.md missing Rule of Three gate section heading"
  fi

  # Dependency cost/benefit gate — check for gate section heading
  if grep -qiE "^## Gate 3|^##.*Dependency" "$COMPLEXITY_GATE_MD"; then
    pass "complexity-gate.md has Dependency cost/benefit gate section heading"
  else
    fail "complexity-gate.md missing Dependency cost/benefit gate section heading"
  fi

  # Scale threshold or profiling-first gate — check for gate section heading
  if grep -qiE "^## Gate 4|^## Gate 5|^##.*Scale|^##.*Profiling" "$COMPLEXITY_GATE_MD"; then
    pass "complexity-gate.md has scale threshold/profiling gate section heading"
  else
    fail "complexity-gate.md missing scale threshold/profiling gate section heading"
  fi

  # LLM self-audit gate — check for gate section heading
  if grep -qiE "^## Gate 6|^##.*Self.Audit|^##.*LLM" "$COMPLEXITY_GATE_MD"; then
    pass "complexity-gate.md has LLM self-audit gate section heading"
  else
    fail "complexity-gate.md missing LLM self-audit gate section heading"
  fi

  # Justified-complexity path — check for section heading
  if grep -qiE "^##.*Justified" "$COMPLEXITY_GATE_MD"; then
    pass "complexity-gate.md has Justified-Complexity section heading"
  else
    fail "complexity-gate.md missing Justified-Complexity section heading"
  fi

  # Prohibition on sandbagging — check for section heading
  if grep -qiE "^##.*Sandbagging|^##.*Prohibition" "$COMPLEXITY_GATE_MD"; then
    pass "complexity-gate.md has Sandbagging prohibition section heading"
  else
    fail "complexity-gate.md missing Sandbagging prohibition section heading"
  fi
}

# ---------------------------------------------------------------------------
# Test 3: brainstorm/SKILL.md references shared/prompts/complexity-gate.md
# ---------------------------------------------------------------------------
test_brainstorm_references_complexity_gate() {
  echo ""
  echo "=== test_brainstorm_references_complexity_gate ==="

  if grep -q "shared/prompts/complexity-gate.md" "$BRAINSTORM_MD"; then
    pass "Brainstorm SKILL.md references shared/prompts/complexity-gate.md"
  else
    fail "Brainstorm SKILL.md missing reference to shared/prompts/complexity-gate.md"
  fi
}

# ---------------------------------------------------------------------------
# Test 4: implementation-plan/SKILL.md references shared/prompts/complexity-gate.md
# ---------------------------------------------------------------------------
test_implementation_plan_references_complexity_gate() {
  echo ""
  echo "=== test_implementation_plan_references_complexity_gate ==="

  if grep -q "shared/prompts/complexity-gate.md" "$IMPL_PLAN_MD"; then
    pass "Implementation-plan SKILL.md references shared/prompts/complexity-gate.md"
  else
    fail "Implementation-plan SKILL.md missing reference to shared/prompts/complexity-gate.md"
  fi
}

# ---------------------------------------------------------------------------
# Test 5: approach-decision-maker.md references shared/prompts/complexity-gate.md
# ---------------------------------------------------------------------------
test_approach_decision_maker_references_complexity_gate() {
  echo ""
  echo "=== test_approach_decision_maker_references_complexity_gate ==="

  if grep -q "shared/prompts/complexity-gate.md" "$APPROACH_DM_MD"; then
    pass "approach-decision-maker.md references shared/prompts/complexity-gate.md"
  else
    fail "approach-decision-maker.md missing reference to shared/prompts/complexity-gate.md"
  fi
}

# ---------------------------------------------------------------------------
# Run all tests
# ---------------------------------------------------------------------------
test_complexity_gate_file_exists
test_complexity_gate_required_content
test_brainstorm_references_complexity_gate
test_implementation_plan_references_complexity_gate
test_approach_decision_maker_references_complexity_gate

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
