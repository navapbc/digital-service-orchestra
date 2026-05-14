#!/usr/bin/env bash
# tests/scripts/test-debug-everything-bugfix-subbranch.sh
# Structural metadata validation of debug-everything SKILL.md Bug-Fix Mode sub-branch routing.
#
# Verifies that the debug-everything skill Bug-Fix Mode includes:
#   1. DEBUG_BRANCH_TRACKING: anchor referenced as a tracking mechanism in Bug-Fix Mode context
#   2. Fix-bug output committed to current sub-branch (not session branch) in Bug-Fix Mode
#   3. ABSENCE: "uniformly" is not present (cross-mode uniformity language is disallowed)
#   4. Sub-branch instructions co-located in the Bug-Fix Mode section (not only preamble)
#
# Test status: Tests 1, 2, 4 are RED — SKILL.md Bug-Fix Mode not yet updated with sub-branch routing.
#              Test 3 (absence check) passes immediately — "uniformly" is absent.
#
# Exemption: structural metadata validation of prompt file — not executable code.
#
# Usage: bash tests/scripts/test-debug-everything-bugfix-subbranch.sh

# pipefail intentionally omitted: grep-q pipelines below trigger SIGPIPE on Linux under pipefail (bug 8142-c280)
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
DSO_PLUGIN_DIR="$PLUGIN_ROOT/plugins/dso"
SKILL_FILE="$DSO_PLUGIN_DIR/skills/debug-everything/SKILL.md"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

echo "=== test-debug-everything-bugfix-subbranch.sh ==="

test_bugfix_mode_uses_tracking_anchor() {
    local result="missing"
    # Bug-Fix Mode Execution section must reference DEBUG_BRANCH_TRACKING: as a per-fix tracking anchor
    # (not only in the compaction-recovery sub-section)
    if grep -A 80 '### Bug-Fix Mode Execution' "$SKILL_FILE" 2>/dev/null | grep -qE 'DEBUG_BRANCH_TRACKING:.*sub.branch|sub.branch.*DEBUG_BRANCH_TRACKING:|record.*tracking.*comment.*Bug.Fix|Bug.Fix.*record.*tracking'; then
        result="found"
    fi
    assert_eq "test_bugfix_mode_uses_tracking_anchor: SKILL.md Bug-Fix Mode Execution section references DEBUG_BRANCH_TRACKING: as a sub-branch tracking anchor" "found" "$result"
}

test_bugfix_mode_commits_to_subbranch() {
    local result="missing"
    # Bug-Fix Mode Execution section must explicitly state that fix-bug output goes to the
    # current sub-branch (not session branch). Must appear in Bug-Fix Mode Execution section,
    # not only in the compaction-recovery sub-section.
    if grep -A 80 '### Bug-Fix Mode Execution' "$SKILL_FILE" 2>/dev/null | grep -qE 'current sub-branch|fix.bug.*commits.*sub-branch|sub-branch.*fix.bug.*commit|changes.*committed.*sub-branch|sub-branch.*not.*session'; then
        result="found"
    fi
    assert_eq "test_bugfix_mode_commits_to_subbranch: SKILL.md Bug-Fix Mode Execution states fix-bug output is committed to current sub-branch" "found" "$result"
}

test_no_cross_mode_uniformly_language() {
    local result="absent"
    # ABSENCE check: "uniformly" must NOT appear in SKILL.md
    # Sub-branch behavior must be mode-specific, not applied uniformly across all modes
    if grep -q 'uniformly' "$SKILL_FILE" 2>/dev/null; then
        result="present"
    fi
    assert_eq "test_no_cross_mode_uniformly_language: SKILL.md must NOT contain 'uniformly' (cross-mode sub-branch instruction is disallowed)" "absent" "$result"
}

test_bugfix_mode_has_own_subbranch_instructions() {
    local result="missing"
    # Sub-branch instructions must be co-located in the Bug-Fix Mode section header/body
    # (not only in Phase F or Phase G preamble)
    if grep -E '## Bug-Fix Mode.*sub.branch|Bug-Fix Mode.*one sub-branch|sub-branch.*per.*bug.*Bug-Fix|Bug-Fix.*sub-branch.*ci.pr' "$SKILL_FILE" 2>/dev/null | grep -qv 'Phase F\|Phase G'; then
        result="found"
    fi
    assert_eq "test_bugfix_mode_has_own_subbranch_instructions: SKILL.md Bug-Fix Mode section header/body contains co-located sub-branch routing instructions" "found" "$result"
}

echo ""
echo "--- test_bugfix_mode_uses_tracking_anchor ---"
test_bugfix_mode_uses_tracking_anchor
echo ""
echo "--- test_bugfix_mode_commits_to_subbranch ---"
test_bugfix_mode_commits_to_subbranch
echo ""
echo "--- test_no_cross_mode_uniformly_language ---"
test_no_cross_mode_uniformly_language
echo ""
echo "--- test_bugfix_mode_has_own_subbranch_instructions ---"
test_bugfix_mode_has_own_subbranch_instructions
echo ""
print_summary
