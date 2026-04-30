#!/usr/bin/env bash
# Structural-boundary tests for implementation-plan SKILL.md tag-guard contract.
# Per behavioral-testing-standard.md Rule 5: instruction-file tests assert on
# binding contract tokens (config keys, file paths, wire formats, tag literals)
# — never on heading text or prose.
set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
SKILL_MD="${REPO_ROOT}/plugins/dso/skills/implementation-plan/SKILL.md"

PASS=0
FAIL=0

pass() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

echo "--- test_external_dependencies_block_contract_referenced ---"
# Binding caller: external-dependencies-block.md is a real file at
# plugins/dso/docs/contracts/external-dependencies-block.md whose schema is
# emitted by brainstorm and consumed here for prep-task seeding. The reference
# is a cross-file dependency, not a prose phrase.
if grep -q "external-dependencies-block\.md" "$SKILL_MD"; then
    pass "test_external_dependencies_block_contract_referenced: contract reference present"
else
    fail "test_external_dependencies_block_contract_referenced: external-dependencies-block.md reference missing"
fi

echo ""
echo "--- test_flag_gate_referenced ---"
# Binding caller: planning.external_dependency_block_enabled is a config key
# read via read-config.sh (binding read in check-tag-guards.sh).
if grep -q "planning\.external_dependency_block_enabled" "$SKILL_MD"; then
    pass "test_flag_gate_referenced: planning flag reference present"
else
    fail "test_flag_gate_referenced: planning.external_dependency_block_enabled reference missing"
fi

echo ""
echo "--- test_refusal_diagnostic_structure_present ---"
# Binding caller: STATUS:blocked is a wire-format prefix consumed by the sprint
# orchestrator's STATUS-line parser. A manual-prep refusal must emit this.
if grep -q "STATUS:blocked REASON:manual_story_no_prep" "$SKILL_MD"; then
    pass "test_refusal_diagnostic_structure_present: manual-prep STATUS:blocked emit present"
else
    fail "test_refusal_diagnostic_structure_present: STATUS:blocked REASON:manual_story_no_prep emit missing"
fi

echo ""
echo "--- test_manual_step_exclusion_marker_present ---"
# Binding caller: manual:awaiting_user is a tag literal set by brainstorm and
# read by check-tag-guards.sh — string identity is the contract.
if grep -qi "manual:awaiting_user" "$SKILL_MD"; then
    pass "test_manual_step_exclusion_marker_present: tag literal present"
else
    fail "test_manual_step_exclusion_marker_present: manual:awaiting_user tag literal missing"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"

if [ "$FAIL" -gt 0 ]; then
    echo "VALIDATION FAILED"
    exit 1
fi

echo "ALL VALIDATIONS PASSED"
exit 0
