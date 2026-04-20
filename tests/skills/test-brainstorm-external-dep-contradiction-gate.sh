#!/usr/bin/env bash
# Structural-boundary tests for brainstorm SKILL.md Phase 2 External Dependencies Contradiction Gate.
# Rule 5 (behavioral-testing-standard.md): SKILL.md is non-executable; tests assert structural
# contracts (section headings, referenced flags), not behavioral content.
set -euo pipefail

SKILL_MD="$(git rev-parse --show-toplevel)/plugins/dso/skills/brainstorm/SKILL.md"

PASS=0
FAIL=0

pass() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

echo "=== Contradiction gate section heading present ==="
# test_contradiction_gate_section_heading_present
# Assert a structural heading for the External Dependencies Contradiction Gate exists in
# the Phase 2 Approval Gate area. This is the RED marker boundary test.
if grep -qi "External Dependencies Contradiction Gate\|Contradiction Gate" "$SKILL_MD"; then
    pass "test_contradiction_gate_section_heading_present: gate heading found in SKILL.md"
else
    fail "test_contradiction_gate_section_heading_present: no contradiction gate heading found in SKILL.md"
fi

echo ""
echo "=== Token marker propagation section present ==="
# test_token_marker_propagation_section_present
# Assert that SKILL.md references confirmation_token_required propagation — a structural
# contract boundary signaling that the gate carries token metadata forward.
if grep -q "confirmation_token_required" "$SKILL_MD"; then
    pass "test_token_marker_propagation_section_present: confirmation_token_required marker found"
else
    fail "test_token_marker_propagation_section_present: confirmation_token_required marker missing from SKILL.md"
fi

echo ""
echo "=== Flag guard present ==="
# test_flag_guard_present
# Assert that the contradiction gate section references the planning flag that guards it.
if grep -q "planning\.external_dependency_block_enabled\|is_external_dep_block_enabled\|planning-config\.sh" "$SKILL_MD"; then
    pass "test_flag_guard_present: planning flag guard reference found in SKILL.md"
else
    fail "test_flag_guard_present: no planning flag guard reference found in SKILL.md contradiction gate"
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
