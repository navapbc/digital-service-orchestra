#!/usr/bin/env bash
# Structural-boundary tests for brainstorm SKILL.md SC2: External Dependency gate position,
# claude_auto+claude_has_access=no/unknown refusal trigger, and confirmation_token_required
# when verification_command is omitted.
# Rule 5 (behavioral-testing-standard.md): SKILL.md is non-executable; tests assert structural
# contracts (section presence, key tokens) — not behavioral content.
# Task: 6387-2c18
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && git rev-parse --show-toplevel)"
SKILL_MD="${REPO_ROOT}/plugins/dso/skills/brainstorm/SKILL.md"

# skill-refactor: brainstorm phases extracted. Rebind SKILL_MD to aggregated corpus
# (SKILL.md + phases/*.md + verifiable-sc-check.md).
_orig_SKILL_MD="$SKILL_MD"
source "$(git rev-parse --show-toplevel)/tests/skills/lib/brainstorm-skill-aggregate.sh"
SKILL_MD=$(brainstorm_aggregate_path)
trap brainstorm_aggregate_cleanup EXIT


PASS=0
FAIL=0

pass() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

echo "=== SC2-A: claude_auto + claude_has_access=no/unknown refusal trigger documented ==="
# test_claude_auto_access_no_unknown_refusal_trigger
# Assert that SKILL.md documents the contradiction pattern (handling=claude_auto AND
# claude_has_access no/unknown) that blocks the approval gate. This is the core refusal trigger.
if grep -qE "claude_auto.*claude_has_access|claude_has_access.*claude_auto|handling: claude_auto" "$SKILL_MD"; then
    pass "test_claude_auto_access_no_unknown_refusal_trigger: handling=claude_auto contradiction pattern found in SKILL.md"
else
    fail "test_claude_auto_access_no_unknown_refusal_trigger: handling=claude_auto contradiction pattern missing from SKILL.md"
fi

echo ""
echo "=== SC2-A supplemental: no/unknown access values documented in refusal diagnostic ==="
# test_refusal_diagnostic_no_unknown_values
# Assert that the refusal diagnostic message names the triggering values (no|unknown) — structural
# contract that the gate covers both access-denied and access-unknown cases.
if grep -qE "no\|unknown|claude_has_access.*no|no.*unknown" "$SKILL_MD"; then
    pass "test_refusal_diagnostic_no_unknown_values: no|unknown access value tokens found in SKILL.md"
else
    fail "test_refusal_diagnostic_no_unknown_values: no|unknown access values not found in SKILL.md refusal diagnostic"
fi

echo ""
echo "=== SC2-B: Contradiction gate section is positioned within Phase 2 approval gate flow ==="
# test_contradiction_gate_within_phase2_approval_gate_flow
# Assert that the "External Dependencies Contradiction Gate" section heading appears after the
# "Phase 2" heading — structural contract that the gate is part of the Phase 2 approval flow.
phase2_line=$(grep -n "^## Phase 2:" "$SKILL_MD" | head -1 | cut -d: -f1)
gate_line=$(grep -n "External Dependencies Contradiction Gate" "$SKILL_MD" | head -1 | cut -d: -f1)
if [ -n "$phase2_line" ] && [ -n "$gate_line" ] && [ "$gate_line" -gt "$phase2_line" ]; then
    pass "test_contradiction_gate_within_phase2_approval_gate_flow: gate (line $gate_line) is after Phase 2 heading (line $phase2_line)"
else
    fail "test_contradiction_gate_within_phase2_approval_gate_flow: gate not found after Phase 2 heading (phase2=$phase2_line, gate=$gate_line)"
fi

echo ""
echo "=== SC2-C: confirmation_token_required set when verification_command is omitted ==="
# test_confirmation_token_required_when_verification_command_omitted
# Assert that SKILL.md specifies the confirmation_token_required rule that fires when
# verification_command is absent — structural contract for the sprint pause-handshake.
if grep -q "verification_command.*omitted\|omitted.*verification_command" "$SKILL_MD"; then
    pass "test_confirmation_token_required_when_verification_command_omitted: verification_command omitted rule found in SKILL.md"
else
    fail "test_confirmation_token_required_when_verification_command_omitted: verification_command omitted condition missing from SKILL.md"
fi

echo ""
echo "=== SC2-C supplemental: confirmation_token_required field documented ==="
# test_confirmation_token_required_true_token
# Assert that SKILL.md documents the confirmation_token_required field that sprint reads.
# Tests the field name as a structural boundary token (not the specific value, which is prose).
if grep -q "confirmation_token_required" "$SKILL_MD"; then
    pass "test_confirmation_token_required_true_token: confirmation_token_required field documented in SKILL.md"
else
    fail "test_confirmation_token_required_true_token: confirmation_token_required field not documented in SKILL.md"
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
