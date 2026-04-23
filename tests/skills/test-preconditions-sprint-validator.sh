#!/usr/bin/env bash
# tests/skills/test-preconditions-sprint-validator.sh
# Structural boundary tests (Rule 5) for sprint SKILL.md validator wiring.
# Non-executable LLM instruction file — tests verify the validator sections
# are present in the sprint SKILL.md file.
#
# RED: tests fail before 502c-1e93 adds validator hooks to sprint SKILL.md.
# GREEN: tests pass after validator sections are inserted.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SKILL_FILE="$REPO_ROOT/plugins/dso/skills/sprint/SKILL.md"

source "$SCRIPT_DIR/../lib/assert.sh"

# ── Test 1: sprint SKILL.md contains _dso_pv_entry_check invocation ───────────
test_sprint_validator_entry_section_present() {
    local found=0
    if grep -q "_dso_pv_entry_check" "$SKILL_FILE" 2>/dev/null; then
        found=1
    fi
    assert_eq \
        "sprint_validator_entry_section_present: _dso_pv_entry_check found in sprint SKILL.md" \
        "1" \
        "$found"
}

# ── Test 2: sprint SKILL.md contains _dso_pv_exit_write invocation ────────────
test_sprint_validator_exit_section_present() {
    local found=0
    if grep -q "_dso_pv_exit_write" "$SKILL_FILE" 2>/dev/null; then
        found=1
    fi
    assert_eq \
        "sprint_validator_exit_section_present: _dso_pv_exit_write found in sprint SKILL.md" \
        "1" \
        "$found"
}

# ── Test 3: entry section references "implementation-plan" as upstream stage ───
test_sprint_validator_upstream_stage_is_impl_plan() {
    local found=0
    if grep -q '_dso_pv_entry_check.*implementation-plan\|_dso_pv_entry_check.*"implementation-plan"' \
        "$SKILL_FILE" 2>/dev/null; then
        found=1
    fi
    assert_eq \
        "sprint_validator_upstream_stage_is_impl_plan: implementation-plan referenced as upstream stage" \
        "1" \
        "$found"
}

# ── Test 4: no interactive prompt pattern in validator sections ───────────────
test_sprint_validator_zero_interaction() {
    local interactive_found=0
    if grep -A5 '_dso_pv_entry_check' "$SKILL_FILE" 2>/dev/null | grep -q 'read -p\|/dev/tty'; then
        interactive_found=1
    fi
    if grep -A5 '_dso_pv_exit_write' "$SKILL_FILE" 2>/dev/null | grep -q 'read -p\|/dev/tty'; then
        interactive_found=1
    fi
    assert_eq \
        "sprint_validator_zero_interaction: no interactive prompts in validator sections" \
        "0" \
        "$interactive_found"
}

# ── Run all tests ─────────────────────────────────────────────────────────────
echo "=== test-preconditions-sprint-validator.sh ==="
test_sprint_validator_entry_section_present
test_sprint_validator_exit_section_present
test_sprint_validator_upstream_stage_is_impl_plan
test_sprint_validator_zero_interaction

print_summary
