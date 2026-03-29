#!/usr/bin/env bash
# tests/hooks/test-fix-bug-context-detection.sh
# Structural metadata validation of fix-bug SKILL.md Sub-Agent Context Detection section.
#
# Verifies that the Detection Methods section prioritizes Agent tool availability as the
# PRIMARY detection method and orchestrator signal as the FALLBACK.
#
# Test approach: direct grep pattern matching on heading lines in SKILL.md.
#
# Test status:
#   test_primary_detection_is_agent_tool      — RED (current Primary = orchestrator signal)
#   test_fallback_detection_is_orchestrator_signal — RED (current Fallback = Agent tool)
#   test_both_detection_methods_documented    — GREEN (both present in current code)
#   test_sub_agent_behavior_documents_tier_gating — GREEN (ADVANCED/ESCALATED gating documented)
#
# Exemption: structural metadata validation of prompt file — not executable code.
# RED marker: test_primary_detection_is_agent_tool (tests at/after this marker are RED)
#
# Usage: bash tests/hooks/test-fix-bug-context-detection.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DSO_PLUGIN_DIR="$PLUGIN_ROOT/plugins/dso"
SKILL_FILE="$DSO_PLUGIN_DIR/skills/fix-bug/SKILL.md"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

echo "=== test-fix-bug-context-detection.sh ==="

# ============================================================
# test_both_detection_methods_documented
# Both "Agent tool" AND "orchestrator signal" must appear in
# the Sub-Agent Context Detection section. GREEN on current code.
# ============================================================
test_both_detection_methods_documented() {
    local agent_tool_found="missing"
    local orchestrator_signal_found="missing"

    if grep -q "Agent tool" "$SKILL_FILE" 2>/dev/null; then
        agent_tool_found="found"
    fi
    if grep -q "orchestrator signal" "$SKILL_FILE" 2>/dev/null; then
        orchestrator_signal_found="found"
    fi

    assert_eq "test_both_detection_methods_documented: Agent tool appears" "found" "$agent_tool_found"
    assert_eq "test_both_detection_methods_documented: orchestrator signal appears" "found" "$orchestrator_signal_found"
}

# ============================================================
# test_sub_agent_behavior_documents_tier_gating
# Behavior in Sub-Agent Context section must document
# ADVANCED and ESCALATED tier gating via Agent tool availability check.
# GREEN on current code (lines 607-608 of SKILL.md).
# ============================================================
test_sub_agent_behavior_documents_tier_gating() {
    local advanced_gating_found="missing"
    local escalated_gating_found="missing"

    if grep -qE "ADVANCED.*Agent tool|Agent tool.*ADVANCED" "$SKILL_FILE" 2>/dev/null; then
        advanced_gating_found="found"
    fi
    if grep -qE "ESCALATED.*Agent tool|Agent tool.*ESCALATED" "$SKILL_FILE" 2>/dev/null; then
        escalated_gating_found="found"
    fi

    assert_eq "test_sub_agent_behavior_documents_tier_gating: ADVANCED tier gated by Agent tool" "found" "$advanced_gating_found"
    assert_eq "test_sub_agent_behavior_documents_tier_gating: ESCALATED tier gated by Agent tool" "found" "$escalated_gating_found"
}

# ============================================================
# RED MARKER BOUNDARY
# Tests above this comment are GREEN on current code.
# Tests below this comment are RED until the Detection Methods
# section is updated to prioritize Agent tool as Primary.
# RED marker: test_primary_detection_is_agent_tool
# ============================================================

# ============================================================
# test_primary_detection_is_agent_tool
# The "Primary" detection method heading must reference "Agent tool",
# not "orchestrator signal". RED because current heading says Primary =
# orchestrator signal.
# ============================================================
test_primary_detection_is_agent_tool() {
    local primary_agent_tool_found="missing"

    if grep -qE '\*\*Primary.*Agent tool' "$SKILL_FILE" 2>/dev/null; then
        primary_agent_tool_found="found"
    fi

    assert_eq "test_primary_detection_is_agent_tool: Primary heading references Agent tool" "found" "$primary_agent_tool_found"
}

# ============================================================
# test_fallback_detection_is_orchestrator_signal
# The "Fallback" (or "Secondary") detection method heading must
# reference "orchestrator signal", not "Agent tool". RED because
# current heading says Fallback = Agent tool availability.
# ============================================================
test_fallback_detection_is_orchestrator_signal() {
    local fallback_orchestrator_found="missing"

    if grep -qE '\*\*(Fallback|Secondary).*orchestrator signal' "$SKILL_FILE" 2>/dev/null; then
        fallback_orchestrator_found="found"
    fi

    assert_eq "test_fallback_detection_is_orchestrator_signal: Fallback/Secondary heading references orchestrator signal" "found" "$fallback_orchestrator_found"
}

# Run all tests
test_both_detection_methods_documented
test_sub_agent_behavior_documents_tier_gating
test_primary_detection_is_agent_tool
test_fallback_detection_is_orchestrator_signal

print_summary
