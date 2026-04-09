#!/usr/bin/env bash
# tests/hooks/test-sub-agent-guard.sh
# Verifies that all 20 target skills contain the appropriate SUB-AGENT-GUARD block.
#
# Two groups:
#   Sub-agent dependent (16): guard block must reference "Agent tool"
#   User-interaction dependent (4): guard block must reference "running as a sub-agent"
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
# design-wireframe: redirect stub — no guard needed (skill no longer dispatches sub-agents;
# design creation moved to dso:ui-designer agent dispatched by preplanning)
check_guard_agent_tool "design-review"
check_guard_agent_tool "roadmap"
check_guard_agent_tool "plan-review"

# --- Story 3459-7246 (6 remaining sub-agent dependent — RED until that story) ---
check_guard_agent_tool "architect-foundation"
check_guard_agent_tool "review-protocol"
check_guard_agent_tool "resolve-conflicts"
# dev-onboarding: tombstone/redirect stub — no guard needed (skill has no logic)
check_guard_agent_tool "validate-work"
check_guard_agent_tool "retro"
check_guard_agent_tool "ui-discover"
check_guard_agent_tool "update-docs"

# ===========================================================================
# Group 2: User-interaction dependent skills (4)
# Guard type: SUB-AGENT-GUARD block with orchestrator signal phrase check
# RED until Story 3459-7246 adds their guards
# ===========================================================================
check_guard_orchestrator_signal "end-session"
# project-setup: deleted — skill removed (use /dso:onboarding)
# design-onboarding: deleted — skill removed (use /dso:onboarding)
check_guard_orchestrator_signal "onboarding"

# ===========================================================================
# Group 3: worktree isolation guard removed (bugs 1fd7-7235)
# The platform already prevents sub-agents from using the Agent tool, so the
# hook_worktree_isolation_guard function and auth marker pattern are dead code.
# ===========================================================================

# ---------------------------------------------------------------------------
# test_worktree_isolation_guard_removed
# hook_worktree_isolation_guard must NOT be defined in session-misc-functions.sh
# — the platform prevents sub-agents from dispatching Agent calls, making the
# guard redundant. RED until the function is removed.
# ---------------------------------------------------------------------------
_SESSION_MISC="$DSO_PLUGIN_DIR/hooks/lib/session-misc-functions.sh"
if grep -q "^hook_worktree_isolation_guard" "$_SESSION_MISC" 2>/dev/null; then
    assert_eq "test_worktree_isolation_guard_removed: function absent from session-misc-functions.sh" "absent" "present"
else
    assert_eq "test_worktree_isolation_guard_removed: function absent from session-misc-functions.sh" "absent" "absent"
fi

# ---------------------------------------------------------------------------
# test_pre_agent_dispatcher_removed
# pre-agent.sh must NOT exist — its only purpose was to call the removed guard.
# ---------------------------------------------------------------------------
_PRE_AGENT="$DSO_PLUGIN_DIR/hooks/dispatchers/pre-agent.sh"
if [[ -f "$_PRE_AGENT" ]]; then
    assert_eq "test_pre_agent_dispatcher_removed: dispatcher absent" "absent" "present"
else
    assert_eq "test_pre_agent_dispatcher_removed: dispatcher absent" "absent" "absent"
fi

# ---------------------------------------------------------------------------
# test_auth_marker_pattern_removed_from_worktree_dispatch
# worktree-dispatch.md must NOT contain auth marker creation instructions.
# ---------------------------------------------------------------------------
_DISPATCH_MD="$DSO_PLUGIN_DIR/skills/shared/prompts/worktree-dispatch.md"
if grep -q "worktree-isolation-authorized" "$_DISPATCH_MD" 2>/dev/null; then
    assert_eq "test_auth_marker_pattern_removed_from_worktree_dispatch: auth marker absent" "absent" "present"
else
    assert_eq "test_auth_marker_pattern_removed_from_worktree_dispatch: auth marker absent" "absent" "absent"
fi

print_summary

# ---------------------------------------------------------------------------
# Test-gate anchor block: lists all test names produced by this file so that
# record-test-status.sh can locate RED marker boundaries via get_red_zone_line_number.
# The dynamic labels (test_${skill//-/_}_...) cannot be found by grep; this block
# provides the literal strings in execution order (GREEN skills first, then RED).
# Do NOT remove or reorder — the test gate relies on line-number ordering.
# ---------------------------------------------------------------------------
_TEST_GATE_ANCHORS=(
    test_sprint_has_sub_agent_guard_marker
    test_sprint_guard_references_agent_tool
    test_debug_everything_has_sub_agent_guard_marker
    test_debug_everything_guard_references_agent_tool
    test_brainstorm_has_sub_agent_guard_marker
    test_brainstorm_guard_references_agent_tool
    test_preplanning_has_sub_agent_guard_marker
    test_preplanning_guard_references_agent_tool
    test_implementation_plan_has_sub_agent_guard_marker
    test_implementation_plan_guard_references_agent_tool
    test_design_review_has_sub_agent_guard_marker
    test_design_review_guard_references_agent_tool
    test_roadmap_has_sub_agent_guard_marker
    test_roadmap_guard_references_agent_tool
    test_plan_review_has_sub_agent_guard_marker
    test_plan_review_guard_references_agent_tool
    test_review_protocol_has_sub_agent_guard_marker
    test_review_protocol_guard_references_agent_tool
    test_resolve_conflicts_has_sub_agent_guard_marker
    test_resolve_conflicts_guard_references_agent_tool
    test_dev_onboarding_has_sub_agent_guard_marker
    test_dev_onboarding_guard_references_agent_tool
    test_validate_work_has_sub_agent_guard_marker
    test_validate_work_guard_references_agent_tool
    test_retro_has_sub_agent_guard_marker
    test_retro_guard_references_agent_tool
    test_ui_discover_has_sub_agent_guard_marker
    test_ui_discover_guard_references_agent_tool
    test_architect_foundation_has_sub_agent_guard_marker
    test_architect_foundation_guard_references_agent_tool
    test_update_docs_has_sub_agent_guard_marker
    test_update_docs_guard_references_agent_tool
    test_end_session_has_sub_agent_guard_marker
    test_end_session_guard_references_orchestrator_signal
    test_project_setup_has_sub_agent_guard_marker
    test_project_setup_guard_references_orchestrator_signal
    test_design_onboarding_has_sub_agent_guard_marker
    test_design_onboarding_guard_references_orchestrator_signal
    test_onboarding_has_sub_agent_guard_marker
    test_onboarding_guard_references_orchestrator_signal
    test_worktree_isolation_guard_removed
    test_pre_agent_dispatcher_removed
    test_auth_marker_pattern_removed_from_worktree_dispatch
)
