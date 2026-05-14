#!/usr/bin/env bash
# tests/scripts/test-debug-everything-phase-g-subbranch.sh
# Structural metadata validation of debug-everything SKILL.md Phase G sub-branch behaviors.
#
# Verifies that the debug-everything skill Phase G (parallel sub-agent dispatch) includes:
#   1. Sub-branch naming: bug-batch/<debug-session-id>/tier-<N>-batch-<K>
#   2. 5-bug cap per sub-branch
#   3. Large-fix exception (>500 lines) gets its own -large sub-branch
#   4. Large-fix takes precedence over file-conflict split
#   5. File-conflict splits produce additional sub-branches
#   6. Serialized integration prevents concurrent push race
#   7. Sub-branch instructions are in the Phase G section header (not only preamble)
#
# Test status: All 7 tests are RED — SKILL.md Phase G not yet updated.
#
# Exemption: structural metadata validation of prompt file — not executable code.
#
# Usage: bash tests/scripts/test-debug-everything-phase-g-subbranch.sh

set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
DSO_PLUGIN_DIR="$PLUGIN_ROOT/plugins/dso"
SKILL_FILE="$DSO_PLUGIN_DIR/skills/debug-everything/SKILL.md"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

echo "=== test-debug-everything-phase-g-subbranch.sh ==="

test_phase_g_subbranch_naming_contract() {
    local result="missing"
    if grep -qE 'bug-batch/.*tier-[0-9]+-batch-[0-9]+' "$SKILL_FILE" 2>/dev/null; then
        result="found"
    fi
    assert_eq "test_phase_g_subbranch_naming_contract: SKILL.md Phase G contains bug-batch/<id>/tier-N-batch-K naming pattern" "found" "$result"
}

test_phase_g_max_5_bugs_per_branch() {
    local result="missing"
    if grep -qE '(5 bugs|at most 5|≤5|max.*5|5-bug)' "$SKILL_FILE" 2>/dev/null; then
        result="found"
    fi
    assert_eq "test_phase_g_max_5_bugs_per_branch: SKILL.md Phase G documents 5-bug cap per sub-branch" "found" "$result"
}

test_phase_g_large_fix_exception() {
    local result="missing"
    if grep -qE '(>500 lines|large.fix|large-fix|-large)' "$SKILL_FILE" 2>/dev/null; then
        result="found"
    fi
    assert_eq "test_phase_g_large_fix_exception: SKILL.md Phase G documents large-fix exception" "found" "$result"
}

test_phase_g_large_fix_precedence_over_conflict() {
    local result="missing"
    if grep -qE '(large.fix.*prece|prece.*large.fix|large.fix.*before.*conflict|large.fix.*over.*conflict)' "$SKILL_FILE" 2>/dev/null; then
        result="found"
    fi
    assert_eq "test_phase_g_large_fix_precedence_over_conflict: SKILL.md Phase G states large-fix takes precedence over file-conflict split" "found" "$result"
}

test_phase_g_file_conflict_split() {
    local result="missing"
    if grep -qE '(file.conflict.*split|split.*file.conflict|conflict.*sub.branch|sub.branch.*conflict)' "$SKILL_FILE" 2>/dev/null; then
        result="found"
    fi
    assert_eq "test_phase_g_file_conflict_split: SKILL.md Phase G documents file-conflict splits" "found" "$result"
}

test_phase_g_serialized_integration() {
    local result="missing"
    if grep -qE '(serialized integration|serialize.*integration|integrate.*serial)' "$SKILL_FILE" 2>/dev/null; then
        result="found"
    fi
    assert_eq "test_phase_g_serialized_integration: SKILL.md Phase G references serialized integration" "found" "$result"
}

test_phase_g_instructions_colocated() {
    local result="missing"
    if awk '/^## Phase G/,/^## Phase [HI]/' "$SKILL_FILE" 2>/dev/null | grep -qE 'sub.branch|sub-branch'; then
        result="found"
    fi
    assert_eq "test_phase_g_instructions_colocated: SKILL.md Phase G section references sub-branch dispatch" "found" "$result"
}

echo ""
echo "--- test_phase_g_subbranch_naming_contract ---"
test_phase_g_subbranch_naming_contract
echo ""
echo "--- test_phase_g_max_5_bugs_per_branch ---"
test_phase_g_max_5_bugs_per_branch
echo ""
echo "--- test_phase_g_large_fix_exception ---"
test_phase_g_large_fix_exception
echo ""
echo "--- test_phase_g_large_fix_precedence_over_conflict ---"
test_phase_g_large_fix_precedence_over_conflict
echo ""
echo "--- test_phase_g_file_conflict_split ---"
test_phase_g_file_conflict_split
echo ""
echo "--- test_phase_g_serialized_integration ---"
test_phase_g_serialized_integration
echo ""
echo "--- test_phase_g_instructions_colocated ---"
test_phase_g_instructions_colocated
echo ""
print_summary
