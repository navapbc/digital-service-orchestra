#!/usr/bin/env bash
# tests/scripts/test-debug-everything-branch-tracking.sh
# Structural metadata validation of debug-everything SKILL.md DEBUG_BRANCH_TRACKING contract.
#
# Verifies that the debug-everything skill contains the DEBUG_BRANCH_TRACKING contract:
#   1. Comment format string: DEBUG_BRANCH_TRACKING: sub_branch=
#   2. Tier field in comment format: tier=
#   3. Timestamp field in comment format: timestamp=
#   4. COMPACTION_RESUME reads the most-recent DEBUG_BRANCH_TRACKING comment
#   5. Parser uses exact-prefix match (does NOT match WORKTREE_TRACKING:)
#   6. DEBUG_BRANCH_TRACKING written in Phase F AND Phase G
#
# Test status: All 6 tests PASS — SKILL.md contains required DEBUG_BRANCH_TRACKING documentation patterns.
#
# Exemption: structural metadata validation of prompt file — not executable code.
#
# Usage: bash tests/scripts/test-debug-everything-branch-tracking.sh

# pipefail intentionally omitted: awk|grep-q pipelines below trigger SIGPIPE on Linux under pipefail (bug 8142-c280)
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
DSO_PLUGIN_DIR="$PLUGIN_ROOT/plugins/dso"
SKILL_FILE="$DSO_PLUGIN_DIR/skills/debug-everything/SKILL.md"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

if [[ ! -f "$SKILL_FILE" ]]; then
    printf "FAIL: SKILL.md not found at expected path: %s\n" "$SKILL_FILE" >&2
    printf "Check BASH_SOURCE[0]-based path derivation — test cannot proceed.\n" >&2
    exit 1
fi

echo "=== test-debug-everything-branch-tracking.sh ==="

test_debug_branch_tracking_comment_format() {
    local result="missing"
    if grep -q "DEBUG_BRANCH_TRACKING: sub_branch=" "$SKILL_FILE" 2>/dev/null; then
        result="found"
    fi
    assert_eq "test_debug_branch_tracking_comment_format: SKILL.md contains DEBUG_BRANCH_TRACKING: sub_branch= format string" "found" "$result"
}

test_debug_branch_tracking_tier_field() {
    local result="missing"
    if grep -q "tier=" "$SKILL_FILE" 2>/dev/null && grep -q "DEBUG_BRANCH_TRACKING" "$SKILL_FILE" 2>/dev/null; then
        # Both must be present — tier= field in DEBUG_BRANCH_TRACKING comment format context
        if grep -A5 "DEBUG_BRANCH_TRACKING" "$SKILL_FILE" 2>/dev/null | grep -q "tier="; then
            result="found"
        elif grep "DEBUG_BRANCH_TRACKING" "$SKILL_FILE" 2>/dev/null | grep -q "tier="; then
            result="found"
        fi
    fi
    assert_eq "test_debug_branch_tracking_tier_field: SKILL.md contains tier= field in DEBUG_BRANCH_TRACKING comment format" "found" "$result"
}

test_debug_branch_tracking_timestamp_field() {
    local result="missing"
    if grep -q "DEBUG_BRANCH_TRACKING" "$SKILL_FILE" 2>/dev/null; then
        if grep -A5 "DEBUG_BRANCH_TRACKING" "$SKILL_FILE" 2>/dev/null | grep -q "timestamp="; then
            result="found"
        elif grep "DEBUG_BRANCH_TRACKING" "$SKILL_FILE" 2>/dev/null | grep -q "timestamp="; then
            result="found"
        fi
    fi
    assert_eq "test_debug_branch_tracking_timestamp_field: SKILL.md contains timestamp= field in DEBUG_BRANCH_TRACKING comment format" "found" "$result"
}

test_compaction_resume_reads_debug_tracking() {
    local result="missing"
    if grep -q "DEBUG_BRANCH_TRACKING:" "$SKILL_FILE" 2>/dev/null && \
       grep -q "COMPACTION_RESUME" "$SKILL_FILE" 2>/dev/null; then
        # COMPACTION_RESUME section must reference DEBUG_BRANCH_TRACKING:
        if grep -A20 "COMPACTION_RESUME" "$SKILL_FILE" 2>/dev/null | grep -q "DEBUG_BRANCH_TRACKING:"; then
            result="found"
        fi
    fi
    assert_eq "test_compaction_resume_reads_debug_tracking: SKILL.md COMPACTION_RESUME section reads DEBUG_BRANCH_TRACKING: comment" "found" "$result"
}

test_debug_tracking_namespace_isolated() {
    local result="missing"
    if grep -qE "(exact.prefix|exact prefix)" "$SKILL_FILE" 2>/dev/null && \
       grep -q "DEBUG_BRANCH_TRACKING" "$SKILL_FILE" 2>/dev/null; then
        result="found"
    fi
    assert_eq "test_debug_tracking_namespace_isolated: SKILL.md documents exact-prefix match for DEBUG_BRANCH_TRACKING parser (not WORKTREE_TRACKING)" "found" "$result"
}

test_debug_tracking_written_phase_f_and_g() {
    local result="missing"
    # DEBUG_BRANCH_TRACKING must appear in both Phase F and Phase G context
    local phase_f_has=""
    local phase_g_has=""
    if grep -qE "## Phase F" "$SKILL_FILE" 2>/dev/null; then
        if awk '/## Phase F/,/## Phase G/' "$SKILL_FILE" 2>/dev/null | grep -q "DEBUG_BRANCH_TRACKING"; then
            phase_f_has="yes"
        fi
    fi
    if grep -qE "## Phase G" "$SKILL_FILE" 2>/dev/null; then
        if awk '/^## Phase G/,/^## Phase [HI]/' "$SKILL_FILE" 2>/dev/null | grep -q "DEBUG_BRANCH_TRACKING"; then
            phase_g_has="yes"
        fi
    fi
    if [ "$phase_f_has" = "yes" ] && [ "$phase_g_has" = "yes" ]; then
        result="found"
    fi
    assert_eq "test_debug_tracking_written_phase_f_and_g: SKILL.md documents DEBUG_BRANCH_TRACKING in both Phase F and Phase G" "found" "$result"
}

echo ""
echo "--- test_debug_branch_tracking_comment_format ---"
test_debug_branch_tracking_comment_format
echo ""
echo "--- test_debug_branch_tracking_tier_field ---"
test_debug_branch_tracking_tier_field
echo ""
echo "--- test_debug_branch_tracking_timestamp_field ---"
test_debug_branch_tracking_timestamp_field
echo ""
echo "--- test_compaction_resume_reads_debug_tracking ---"
test_compaction_resume_reads_debug_tracking
echo ""
echo "--- test_debug_tracking_namespace_isolated ---"
test_debug_tracking_namespace_isolated
echo ""
echo "--- test_debug_tracking_written_phase_f_and_g ---"
test_debug_tracking_written_phase_f_and_g
echo ""
print_summary
