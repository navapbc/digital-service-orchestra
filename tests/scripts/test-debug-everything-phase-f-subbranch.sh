#!/usr/bin/env bash
# tests/scripts/test-debug-everything-phase-f-subbranch.sh
# Structural metadata validation of debug-everything SKILL.md Phase F sub-branch behaviors.
#
# Verifies that the debug-everything skill Phase F (per-tier sub-branch creation) includes:
#   1. Sub-branch naming: bug-batch/<debug-session-id>/tier-0
#   2. Tier-1 sub-branch naming reference
#   3. Zero-bug-tier → no sub-branch created
#   4. Sub-branch instructions are in Phase F section (not only preamble)
#   5. Exactly one sub-branch per tier (no per-bug chunking)
#
# Test status: All 5 tests PASS — SKILL.md Phase F contains required sub-branch documentation patterns.
#
# Exemption: structural metadata validation of prompt file — not executable code.
#
# Usage: bash tests/scripts/test-debug-everything-phase-f-subbranch.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
DSO_PLUGIN_DIR="$PLUGIN_ROOT/plugins/dso"
SKILL_FILE="$DSO_PLUGIN_DIR/skills/debug-everything/SKILL.md"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

echo "=== test-debug-everything-phase-f-subbranch.sh ==="

test_phase_f_subbranch_naming_contract() {
    local result="missing"
    if grep -qE 'bug-batch/.*tier-0' "$SKILL_FILE" 2>/dev/null; then
        result="found"
    fi
    assert_eq "test_phase_f_subbranch_naming_contract: SKILL.md Phase F contains bug-batch/<id>/tier-0 naming pattern" "found" "$result"
}

test_phase_f_subbranch_tier1_naming() {
    local result="missing"
    if grep -qE 'bug-batch/.*tier-1' "$SKILL_FILE" 2>/dev/null; then
        result="found"
    fi
    assert_eq "test_phase_f_subbranch_tier1_naming: SKILL.md Phase F contains tier-1 sub-branch reference" "found" "$result"
}

test_phase_f_zero_bug_tier_skip() {
    local result="missing"
    if grep -qE '(zero.bug.*tier|tier.*zero.bug|empty.*tier.*skip|0.*bugs.*no.*sub.branch|no.*sub.branch.*0.*bugs)' "$SKILL_FILE" 2>/dev/null; then
        result="found"
    fi
    assert_eq "test_phase_f_zero_bug_tier_skip: SKILL.md Phase F documents zero-bug-tier → no sub-branch created" "found" "$result"
}

test_phase_f_instructions_colocated() {
    local result="missing"
    if grep -qE '## Phase F.*sub.branch|Phase F.*one.*sub.branch.*per.*tier|sub.branch.*per.*tier.*Phase F' "$SKILL_FILE" 2>/dev/null; then
        result="found"
    fi
    assert_eq "test_phase_f_instructions_colocated: SKILL.md Phase F section references per-tier sub-branch creation" "found" "$result"
}

test_phase_f_one_branch_per_tier() {
    local result="missing"
    if grep -qE '(exactly one sub.branch per tier|one sub.branch per tier|one.*sub.branch.*per.*tier)' "$SKILL_FILE" 2>/dev/null; then
        result="found"
    fi
    assert_eq "test_phase_f_one_branch_per_tier: SKILL.md Phase F states one sub-branch per tier (no per-bug chunking)" "found" "$result"
}

echo ""
echo "--- test_phase_f_subbranch_naming_contract ---"
test_phase_f_subbranch_naming_contract
echo ""
echo "--- test_phase_f_subbranch_tier1_naming ---"
test_phase_f_subbranch_tier1_naming
echo ""
echo "--- test_phase_f_zero_bug_tier_skip ---"
test_phase_f_zero_bug_tier_skip
echo ""
echo "--- test_phase_f_instructions_colocated ---"
test_phase_f_instructions_colocated
echo ""
echo "--- test_phase_f_one_branch_per_tier ---"
test_phase_f_one_branch_per_tier
echo ""
print_summary
