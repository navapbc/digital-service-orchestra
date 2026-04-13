#!/usr/bin/env bash
# Structural validation for simplify-first behavioral preconditions.
# Tests: Phase 1 scale evidence step, Phase 2 simple baseline requirement,
#        and Phase 2 GATE/CHECKED/FINDING/VERDICT enforcement in brainstorm SKILL.md.
# Part of epic 4ba1-759f: Simplify-first scale inference and complexity gates.
set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
BRAINSTORM_MD="${REPO_ROOT}/plugins/dso/skills/brainstorm/SKILL.md"

PASS=0
FAIL=0

pass() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

# ---------------------------------------------------------------------------
# test_phase1_scale_evidence_step
# Verify brainstorm/SKILL.md contains scale_context in the planning-intelligence
# log definition — added by task 8f37-ddb2 (Phase 1 scale inference integration).
# ---------------------------------------------------------------------------
echo "=== test_phase1_scale_evidence_step ==="

if grep -q "scale_context" "$BRAINSTORM_MD"; then
  pass "brainstorm/SKILL.md contains 'scale_context' field (Phase 1 scale evidence step present)"
else
  fail "brainstorm/SKILL.md missing 'scale_context' field — task 8f37-ddb2 (Phase 1 scale inference) not complete"
fi

# ---------------------------------------------------------------------------
# test_phase2_simple_baseline_requirement
# Verify brainstorm/SKILL.md Phase 2 requires a simple baseline option —
# added by task a0ae-d68c (Phase 2 complexity gate enforcement).
# ---------------------------------------------------------------------------
echo ""
echo "=== test_phase2_simple_baseline_requirement ==="

if grep -qi "simple baseline" "$BRAINSTORM_MD"; then
  pass "brainstorm/SKILL.md contains simple baseline requirement (Phase 2 sandbagging prohibition active)"
else
  fail "brainstorm/SKILL.md missing simple baseline requirement — task a0ae-d68c (Phase 2 complexity gate) not complete"
fi

# ---------------------------------------------------------------------------
# test_phase2_evidence_citation_gate
# Verify brainstorm/SKILL.md Phase 2 requires GATE/CHECKED/FINDING/VERDICT
# blocks for complex proposals — added by task a0ae-d68c.
# ---------------------------------------------------------------------------
echo ""
echo "=== test_phase2_evidence_citation_gate ==="

if grep -q "GATE/CHECKED/FINDING/VERDICT" "$BRAINSTORM_MD"; then
  pass "brainstorm/SKILL.md contains GATE/CHECKED/FINDING/VERDICT requirement for complex proposals"
else
  fail "brainstorm/SKILL.md missing GATE/CHECKED/FINDING/VERDICT requirement — task a0ae-d68c (Phase 2 complexity gate) not complete"
fi

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
