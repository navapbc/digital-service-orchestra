#!/usr/bin/env bash
# tests/skills/test-preconditions-impl-plan-validator.sh
# Structural boundary tests (Rule 5) for implementation-plan SKILL.md validator wiring.
# Non-executable LLM instruction file — tests verify the validator hook sections
# are present in the skill file, not behavioral correctness.
#
# RED: tests fail before 8306-8edb adds validator hooks to implementation-plan SKILL.md.
# GREEN: tests pass after validator sections are inserted.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SKILL_FILE="$REPO_ROOT/plugins/dso/skills/implementation-plan/SKILL.md"

source "$SCRIPT_DIR/../lib/assert.sh"

# ── Test 1: SKILL.md contains _dso_pv_entry_check or preconditions-validator-lib ref
test_impl_plan_validator_entry_section_present() {
    local found=0
    if grep -q "_dso_pv_entry_check\|preconditions-validator-lib" "$SKILL_FILE" 2>/dev/null; then
        found=1
    fi
    assert_eq \
        "impl_plan_validator_entry_section_present: _dso_pv_entry_check or preconditions-validator-lib found in SKILL.md" \
        "1" \
        "$found"
}

# ── Test 2: SKILL.md contains _dso_pv_exit_write invocation ───────────────────
test_impl_plan_validator_exit_section_present() {
    local found=0
    if grep -q "_dso_pv_exit_write" "$SKILL_FILE" 2>/dev/null; then
        found=1
    fi
    assert_eq \
        "impl_plan_validator_exit_section_present: _dso_pv_exit_write found in SKILL.md" \
        "1" \
        "$found"
}

# ── Test 3: entry section references "preplanning" as upstream stage name ──────
test_impl_plan_validator_upstream_stage_is_preplanning() {
    local found=0
    if grep -q '_dso_pv_entry_check.*preplanning\|_dso_pv_entry_check.*"preplanning"' "$SKILL_FILE" 2>/dev/null; then
        found=1
    fi
    assert_eq \
        "impl_plan_validator_upstream_stage_is_preplanning: preplanning referenced as upstream stage" \
        "1" \
        "$found"
}

# ── Test 4: no interactive prompt pattern in validator sections ───────────────
test_impl_plan_validator_zero_interaction() {
    local interactive_found=0
    if grep -A5 '_dso_pv_entry_check' "$SKILL_FILE" 2>/dev/null | grep -q 'read -p\|/dev/tty'; then
        interactive_found=1
    fi
    if grep -A5 '_dso_pv_exit_write' "$SKILL_FILE" 2>/dev/null | grep -q 'read -p\|/dev/tty'; then
        interactive_found=1
    fi
    assert_eq \
        "impl_plan_validator_zero_interaction: no interactive prompts in validator sections" \
        "0" \
        "$interactive_found"
}

# ── Run all tests ─────────────────────────────────────────────────────────────
echo "=== test-preconditions-impl-plan-validator.sh ==="
test_impl_plan_validator_entry_section_present
test_impl_plan_validator_exit_section_present
test_impl_plan_validator_upstream_stage_is_preplanning
test_impl_plan_validator_zero_interaction

print_summary
