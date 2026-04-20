#!/usr/bin/env bash
# Structural-boundary tests for preplanning SKILL.md Phase 1.5 External Dependencies block reader.
# Rule 5 (behavioral-testing-standard.md): SKILL.md is non-executable; tests assert structural
# contracts (section headings, referenced flags, tag names, path references).
set -euo pipefail

_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_MD="${_SCRIPT_DIR}/../SKILL.md"

PASS=0
FAIL=0

pass() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

echo "=== Phase 1.5 section heading exists ==="
# test_phase_1_5_section_heading_exists
# Assert Phase 1.5 External Dependencies Block Reading section heading present.
if grep -qi "Phase 1\.5.*External Dep\|External Dep.*Phase 1\.5" "$SKILL_MD"; then
    pass "test_phase_1_5_section_heading_exists: Phase 1.5 External Dependencies heading found"
else
    fail "test_phase_1_5_section_heading_exists: Phase 1.5 External Dependencies heading not found in SKILL.md"
fi

echo ""
echo "=== Flag check reference present ==="
# test_flag_check_reference_present
# Assert that Phase 1.5 references the feature flag that gates it.
if grep -q "planning\.external_dependency_block_enabled\|is_external_dep_block_enabled\|planning-config\.sh" "$SKILL_MD"; then
    pass "test_flag_check_reference_present: planning flag reference found"
else
    fail "test_flag_check_reference_present: planning flag reference missing from SKILL.md"
fi

echo ""
echo "=== Contract doc path referenced ==="
# test_contract_doc_path_referenced
# Assert that the external-dependencies-block.md contract is referenced.
if grep -q "external-dependencies-block\.md" "$SKILL_MD"; then
    pass "test_contract_doc_path_referenced: external-dependencies-block.md reference found"
else
    fail "test_contract_doc_path_referenced: external-dependencies-block.md reference missing from SKILL.md"
fi

echo ""
echo "=== manual:awaiting_user tag referenced ==="
# test_manual_awaiting_user_tag_referenced
# Assert that Phase 1.5 references the manual:awaiting_user tag for handshake tracking.
if grep -q "manual:awaiting_user\|manual\.awaiting_user" "$SKILL_MD"; then
    pass "test_manual_awaiting_user_tag_referenced: manual:awaiting_user tag reference found"
else
    fail "test_manual_awaiting_user_tag_referenced: manual:awaiting_user tag reference missing from SKILL.md"
fi

echo ""
echo "=== Idempotency check instruction present ==="
# test_idempotency_check_instruction_present
# Assert that SKILL.md Phase 1.5 contains idempotency check guidance.
if grep -qi "idempoten\|already.*present.*skip\|skip.*already.*present" "$SKILL_MD"; then
    pass "test_idempotency_check_instruction_present: idempotency check instruction found"
else
    fail "test_idempotency_check_instruction_present: idempotency check instruction missing from SKILL.md"
fi

echo ""
echo "=== Verification command or token instruction present ==="
# test_verification_command_or_token_instruction_present
# Assert that SKILL.md Phase 1.5 references verification_command and confirmation token fallback.
if grep -q "verification_command" "$SKILL_MD" && grep -q "confirmation.token\|confirmation_token" "$SKILL_MD"; then
    pass "test_verification_command_or_token_instruction_present: both verification_command and confirmation token found"
else
    fail "test_verification_command_or_token_instruction_present: verification_command or confirmation token reference missing"
fi

echo ""
echo "=== Refusal diagnostic references brainstorm ==="
# test_refusal_diagnostic_references_brainstorm
# Assert that the Refusal Gate section specifically directs users to /dso:brainstorm.
# Scoped check: Refusal Gate heading must exist AND brainstorm must appear within 20 lines of it.
if grep -qi "Refusal Gate" "$SKILL_MD" && grep -A20 -i "Refusal Gate" "$SKILL_MD" | grep -qi "brainstorm"; then
    pass "test_refusal_diagnostic_references_brainstorm: Refusal Gate section references /dso:brainstorm"
else
    fail "test_refusal_diagnostic_references_brainstorm: Refusal Gate section missing or does not reference /dso:brainstorm within 20 lines"
fi

echo ""
echo "=== Refusal Gate section heading exists ==="
# test_refusal_gate_section_heading_exists
# RED marker boundary: assert Refusal Gate section heading exists. Fails until task 68e7-8085 adds it.
if grep -qi "Refusal Gate" "$SKILL_MD"; then
    pass "test_refusal_gate_section_heading_exists: Refusal Gate heading found"
else
    fail "test_refusal_gate_section_heading_exists: Refusal Gate heading not found in SKILL.md"
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
