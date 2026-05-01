#!/usr/bin/env bash
# shellcheck disable=SC2329
# RED tests for Phase 1 Gate loop-back, termination, and UNRESOLVABLE_INTENT_GAP.
# Tests: loop-back to Tell Me More on gap, two-condition termination, UNRESOLVABLE_INTENT_GAP escape,
# UX probe named symbol reference.
# NOTE: These tests are intentionally RED — SKILL.md sections they check do not exist yet.
# They will turn GREEN when the implementation task amends Phase 1 Gate Step 2.
set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
SKILL_MD="${REPO_ROOT}/plugins/dso/skills/brainstorm/SKILL.md"
source "${REPO_ROOT}/tests/skills/lib/brainstorm-skill-aggregate.sh"
SKILL_MD=$(brainstorm_aggregate_path)
trap brainstorm_aggregate_cleanup EXIT

PASS=0
FAIL=0
SECTION="unknown"

pass() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: ${SECTION}"; echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

# ============================================================
echo "=== test_loop_back_on_gap ==="
SECTION="test_loop_back_on_gap"

# Assert SKILL.md contains loop-back to Tell Me More directive
if grep -qiE 'loop.?back.*[Tt]ell [Mm]e [Mm]ore|[Tt]ell [Mm]e [Mm]ore.*loop.?back|return.*[Tt]ell [Mm]e [Mm]ore.*loop|return.*Tell Me More' "$SKILL_MD"; then
  pass "SKILL.md Phase 1 Gate Step 2 contains loop-back to Tell Me More directive"
else
  fail "SKILL.md Phase 1 Gate Step 2 missing loop-back to Tell Me More directive"
fi

# ============================================================
echo ""
echo "=== test_termination_both_conditions ==="
SECTION="test_termination_both_conditions"

# Assert termination requires empty gap list
if grep -qiE 'empty.*gap.*list|gap.*list.*empty|gap list is empty|no.*remaining.*gap|no remaining.*inferred' "$SKILL_MD"; then
  pass "SKILL.md contains empty-gap-list termination condition"
else
  fail "SKILL.md missing empty-gap-list termination condition"
fi

# Assert no numeric cap
if grep -qiE 'no numeric cap|no.*cap.*applied|No numeric cap|cap is not applied' "$SKILL_MD"; then
  pass "SKILL.md confirms no numeric cap on loop"
else
  fail "SKILL.md missing no-numeric-cap statement"
fi

# ============================================================
echo ""
echo "=== test_unresolvable_intent_gap ==="
SECTION="test_unresolvable_intent_gap"

# Assert UNRESOLVABLE_INTENT_GAP escape exists
if grep -q 'UNRESOLVABLE_INTENT_GAP' "$SKILL_MD"; then
  pass "SKILL.md contains UNRESOLVABLE_INTENT_GAP escape"
else
  fail "SKILL.md missing UNRESOLVABLE_INTENT_GAP escape"
fi

# Assert associated with anti-redundancy suppression
if grep -qiE 'suppress.*every|suppresses.*all|every candidate.*suppress|all.*candidate.*suppress|all remaining.*duplicate|suppress.*all.*candidate' "$SKILL_MD"; then
  pass "SKILL.md documents anti-redundancy suppression trigger for UNRESOLVABLE_INTENT_GAP"
else
  fail "SKILL.md missing anti-redundancy suppression trigger for UNRESOLVABLE_INTENT_GAP"
fi

# ============================================================
echo ""
echo "=== test_ux_probe_named_symbol ==="
SECTION="test_ux_probe_named_symbol"

# Assert SKILL.md references UX probe checkpoint by named dimension IDs
if grep -qE 'criticality|non_happy_path|flow_entry_exit' "$SKILL_MD"; then
  pass "SKILL.md references UX probe checkpoint by named dimension IDs (criticality, non_happy_path, flow_entry_exit)"
else
  fail "SKILL.md missing UX probe checkpoint named symbol reference (dimension IDs: criticality, non_happy_path, flow_entry_exit)"
fi

# ============================================================
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
