#!/usr/bin/env bash
# tests/hooks/test-sub-agent-guard.sh
# Verifies that all 18 target skills contain the appropriate SUB-AGENT-GUARD block.
#
# Two groups:
#   Sub-agent dependent (15): guard block must reference "Agent tool"
#   User-interaction dependent (3): guard block must reference "running as a sub-agent"
#     (the orchestrator signal phrase used to detect sub-agent context)
#
# TDD RED phase: only the 9 skills from Task 3611-298a will pass initially.
# The remaining 9 skills are RED until Story 3459-7246 adds their guards.
#
# Usage:
#   bash tests/hooks/test-sub-agent-guard.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DSO_PLUGIN_DIR="$PLUGIN_ROOT/plugins/dso"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

echo "=== test-sub-agent-guard.sh ==="

# ---------------------------------------------------------------------------
# Helper: check_guard_agent_tool <skill-name>
# Asserts that plugins/dso/skills/<skill>/SKILL.md contains:
#   1. A <SUB-AGENT-GUARD> marker
#   2. A reference to "Agent tool" inside the guard
# ---------------------------------------------------------------------------
check_guard_agent_tool() {
    local skill="$1"
    local skill_file="$DSO_PLUGIN_DIR/skills/$skill/SKILL.md"
    local label_guard="test_${skill//-/_}_has_sub_agent_guard_marker"
    local label_check="test_${skill//-/_}_guard_references_agent_tool"

    # test: SUB-AGENT-GUARD marker present
    if [[ -f "$skill_file" ]] && grep -q "SUB-AGENT-GUARD" "$skill_file"; then
        assert_eq "$label_guard" "present" "present"
    else
        assert_eq "$label_guard" "present" "missing"
    fi

    # test: "Agent tool" referenced (confirms it's the sub-agent-dispatch variant)
    if [[ -f "$skill_file" ]] && grep -q "Agent tool" "$skill_file" && grep -q "SUB-AGENT-GUARD" "$skill_file"; then
        assert_eq "$label_check" "present" "present"
    else
        assert_eq "$label_check" "present" "missing"
    fi
}

# ---------------------------------------------------------------------------
# Helper: check_guard_orchestrator_signal <skill-name>
# Asserts that plugins/dso/skills/<skill>/SKILL.md contains:
#   1. A <SUB-AGENT-GUARD> marker
#   2. A reference to "running as a sub-agent" (the orchestrator signal phrase)
# ---------------------------------------------------------------------------
check_guard_orchestrator_signal() {
    local skill="$1"
    local skill_file="$DSO_PLUGIN_DIR/skills/$skill/SKILL.md"
    local label_guard="test_${skill//-/_}_has_sub_agent_guard_marker"
    local label_check="test_${skill//-/_}_guard_references_orchestrator_signal"

    # test: SUB-AGENT-GUARD marker present
    if [[ -f "$skill_file" ]] && grep -q "SUB-AGENT-GUARD" "$skill_file"; then
        assert_eq "$label_guard" "present" "present"
    else
        assert_eq "$label_guard" "present" "missing"
    fi

    # test: "running as a sub-agent" referenced (confirms it's the user-interaction variant)
    if [[ -f "$skill_file" ]] && grep -q "running as a sub-agent" "$skill_file" && grep -q "SUB-AGENT-GUARD" "$skill_file"; then
        assert_eq "$label_check" "present" "present"
    else
        assert_eq "$label_check" "present" "missing"
    fi
}

# ===========================================================================
# Group 1: Sub-agent dependent skills (15)
# Guard type: SUB-AGENT-GUARD block with Agent tool availability check
# ===========================================================================

# --- Task 3611-298a (9 skills — GREEN after that task completes) ---
check_guard_agent_tool "sprint"
check_guard_agent_tool "debug-everything"
check_guard_agent_tool "brainstorm"
check_guard_agent_tool "preplanning"
check_guard_agent_tool "implementation-plan"
check_guard_agent_tool "design-wireframe"
check_guard_agent_tool "design-review"
check_guard_agent_tool "roadmap"
check_guard_agent_tool "plan-review"

# --- Story 3459-7246 (6 remaining sub-agent dependent — RED until that story) ---
check_guard_agent_tool "review-protocol"
check_guard_agent_tool "resolve-conflicts"
check_guard_agent_tool "dev-onboarding"
check_guard_agent_tool "validate-work"
check_guard_agent_tool "retro"
check_guard_agent_tool "ui-discover"

# ===========================================================================
# Group 2: User-interaction dependent skills (3)
# Guard type: SUB-AGENT-GUARD block with orchestrator signal phrase check
# RED until Story 3459-7246 adds their guards
# ===========================================================================
check_guard_orchestrator_signal "end-session"
check_guard_orchestrator_signal "project-setup"
check_guard_orchestrator_signal "design-onboarding"

print_summary
