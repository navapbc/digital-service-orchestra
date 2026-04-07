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
check_guard_agent_tool "design-wireframe"
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
# Group 3: hook_worktree_isolation_guard function — auth-file allowlist behavior
# Tests source session-misc-functions.sh and call the function directly.
# RED phase: test_function_allows_with_valid_marker fails against the current
# function, which categorically denies isolation:worktree with no auth-file check.
# ===========================================================================

# Cleanup: remove any marker files created by these tests
trap 'rm -f /tmp/worktree-isolation-authorized-func-* 2>/dev/null; true' EXIT

# Helper: source the functions and call hook_worktree_isolation_guard, writing
# stdout to a temp file (avoids multi-line grep problems).
# Usage: _run_isolation_fn <marker_pid|"none"|"stale"> <tmp_out_file>
_run_isolation_fn() {
    local mode="$1"
    local out_file="$2"
    local _INPUT='{"tool_name":"Agent","tool_input":{"isolation":"worktree","prompt":"test dispatch"}}'

    # Run in a subshell so sourcing doesn't pollute the outer environment.
    # The subshell writes function stdout to out_file and exit code to out_file.exit.
    (
        # Enable isolation enforcement so tests exercise the auth marker path
        export WORKTREE_ISOLATION_ENABLED=true
        # Suppress the "no such file: deps.sh" error from sourcing in a worktree context;
        # the function itself does not depend on deps.sh at call time.
        source "$PLUGIN_ROOT/plugins/dso/hooks/lib/session-misc-functions.sh" 2>/dev/null

        # Set up marker file based on mode
        case "$mode" in
            valid)
                _MARKER="/tmp/worktree-isolation-authorized-func-$$"
                echo "$$" > "$_MARKER"
                trap "rm -f '$_MARKER' 2>/dev/null; true" EXIT
                ;;
            stale)
                # PID beyond any OS limit — guaranteed not running
                _DEAD_PID=9999999
                _MARKER="/tmp/worktree-isolation-authorized-func-${_DEAD_PID}"
                echo "$_DEAD_PID" > "$_MARKER"
                trap "rm -f '$_MARKER' 2>/dev/null; true" EXIT
                ;;
            none)
                rm -f /tmp/worktree-isolation-authorized-func-* 2>/dev/null
                ;;
        esac

        hook_worktree_isolation_guard "$_INPUT" 2>/dev/null > "$out_file"
        echo $? > "${out_file}.exit"
    )
}

# ---------------------------------------------------------------------------
# test_function_allows_with_valid_marker
# With a valid auth marker (PID = current process), function must allow:
#   return 0, no deny JSON in stdout.
# RED against current implementation: current function always outputs deny JSON.
# ---------------------------------------------------------------------------
echo "--- test_function_allows_with_valid_marker ---"
_out_f1="/tmp/_wisog_test1_$$"
_run_isolation_fn "valid" "$_out_f1"
_fn1_stdout=$(cat "$_out_f1" 2>/dev/null)
_fn1_ret=$(cat "${_out_f1}.exit" 2>/dev/null)
rm -f "$_out_f1" "${_out_f1}.exit" 2>/dev/null

assert_eq "test_function_allows_with_valid_marker: returns 0" "0" "${_fn1_ret:-0}"
# assert_not_contains: the deny JSON must NOT appear in stdout when a valid marker exists.
# assert_ne does exact equality, not substring — use inline containment check instead.
if [[ "$_fn1_stdout" == *'"permissionDecision": "deny"'* ]]; then
    assert_eq "test_function_allows_with_valid_marker: no deny output" "no_deny" "deny_found"
else
    assert_eq "test_function_allows_with_valid_marker: no deny output" "no_deny" "no_deny"
fi

# ---------------------------------------------------------------------------
# test_function_blocks_without_marker
# Without an auth marker, isolation:worktree must be denied (deny JSON in stdout).
# ---------------------------------------------------------------------------
echo "--- test_function_blocks_without_marker ---"
_out_f2="/tmp/_wisog_test2_$$"
_run_isolation_fn "none" "$_out_f2"
_fn2_stdout=$(cat "$_out_f2" 2>/dev/null)
rm -f "$_out_f2" "${_out_f2}.exit" 2>/dev/null

assert_contains "test_function_blocks_without_marker: deny output present" '"permissionDecision": "deny"' "$_fn2_stdout"

# ---------------------------------------------------------------------------
# test_function_blocks_stale_marker
# A marker file whose PID is no longer running must still produce deny output.
# ---------------------------------------------------------------------------
echo "--- test_function_blocks_stale_marker ---"
_out_f3="/tmp/_wisog_test3_$$"
_run_isolation_fn "stale" "$_out_f3"
_fn3_stdout=$(cat "$_out_f3" 2>/dev/null)
rm -f "$_out_f3" "${_out_f3}.exit" 2>/dev/null

assert_contains "test_function_blocks_stale_marker: deny output present" '"permissionDecision": "deny"' "$_fn3_stdout"

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
    test_design_wireframe_has_sub_agent_guard_marker
    test_design_wireframe_guard_references_agent_tool
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
    test_function_allows_with_valid_marker
    test_function_blocks_without_marker
    test_function_blocks_stale_marker
)
