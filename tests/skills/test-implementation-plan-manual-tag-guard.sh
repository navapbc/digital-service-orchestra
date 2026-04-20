#!/usr/bin/env bash
# Structural-boundary tests for implementation-plan SKILL.md Manual Story Tag Guard section.
# Rule 5 (behavioral-testing-standard.md): SKILL.md is non-executable; tests assert structural
# contracts (section headings, flag references, contract doc references, output shape).
set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
SKILL_MD="${REPO_ROOT}/plugins/dso/skills/implementation-plan/SKILL.md"

PASS=0
FAIL=0

pass() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

echo "--- test_manual_tag_guard_section_heading_present ---"
# Given: implementation-plan SKILL.md with Manual Story Tag Guard section
# When: grep for the section heading
# Then: exits 0 (section heading is the navigable structural interface)
if grep -q "^## Manual Story Tag Guard" "$SKILL_MD"; then
    pass "test_manual_tag_guard_section_heading_present: heading found"
else
    fail "test_manual_tag_guard_section_heading_present: '## Manual Story Tag Guard' heading missing from SKILL.md"
fi

echo ""
echo "--- test_external_dependencies_block_contract_referenced ---"
# Given: Manual Story Tag Guard section exists
# When: grep for external-dependencies-block.md contract reference within 30 lines of heading
# Then: exits 0 (referential integrity — guard must reference the contract schema)
if grep -A30 "^## Manual Story Tag Guard" "$SKILL_MD" | grep -q "external-dependencies-block\.md"; then
    pass "test_external_dependencies_block_contract_referenced: contract reference found in guard section"
else
    fail "test_external_dependencies_block_contract_referenced: external-dependencies-block.md reference missing from Manual Story Tag Guard section"
fi

echo ""
echo "--- test_flag_gate_referenced ---"
# Given: Manual Story Tag Guard section exists
# When: grep for planning.external_dependency_block_enabled flag within 30 lines of heading
# Then: exits 0 (flag gate reference is the structural contract)
if grep -A30 "^## Manual Story Tag Guard" "$SKILL_MD" | grep -q "planning\.external_dependency_block_enabled"; then
    pass "test_flag_gate_referenced: planning flag reference found in guard section"
else
    fail "test_flag_gate_referenced: planning.external_dependency_block_enabled reference missing from Manual Story Tag Guard section"
fi

echo ""
echo "--- test_refusal_diagnostic_structure_present ---"
# Given: Manual Story Tag Guard section exists
# When: grep for STATUS:blocked within 30 lines of the guard section heading
# Then: exits 0 (the refusal output shape is present in the guard section — not just anywhere in SKILL.md)
if grep -A30 "^## Manual Story Tag Guard" "$SKILL_MD" | grep -q "STATUS:blocked"; then
    pass "test_refusal_diagnostic_structure_present: STATUS:blocked output shape found in guard section"
else
    fail "test_refusal_diagnostic_structure_present: STATUS:blocked output shape missing from Manual Story Tag Guard section"
fi

echo ""
echo "--- test_manual_step_exclusion_marker_present ---"
# Given: Manual Story Tag Guard section exists
# When: grep for manual:awaiting_user tag reference within 30 lines of heading
# Then: exits 0 (the exclusion instruction is the structural boundary per story DD4)
if grep -A30 "^## Manual Story Tag Guard" "$SKILL_MD" | grep -qi "manual:awaiting_user"; then
    pass "test_manual_step_exclusion_marker_present: manual:awaiting_user tag reference found in guard section"
else
    fail "test_manual_step_exclusion_marker_present: manual:awaiting_user tag reference missing from Manual Story Tag Guard section"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"

if [ "$FAIL" -gt 0 ]; then
    echo "VALIDATION FAILED"
    exit 1
fi

echo "ALL VALIDATIONS PASSED"
exit 0
