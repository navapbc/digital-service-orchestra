#!/usr/bin/env bash
# tests/hooks/test-plan-review-gate.sh
# Tests for .claude/hooks/plan-review-gate.sh
#
# plan-review-gate.sh is a PreToolUse hook (ExitPlanMode matcher) that
# blocks ExitPlanMode if no plan review has been recorded for this session.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DSO_PLUGIN_DIR="$PLUGIN_ROOT/plugins/dso"
REPO_ROOT="$(git rev-parse --show-toplevel)"
HOOK="$DSO_PLUGIN_DIR/hooks/plan-review-gate.sh"

source "$PLUGIN_ROOT/tests/lib/assert.sh"
source "$DSO_PLUGIN_DIR/hooks/lib/deps.sh"

ARTIFACTS_DIR=$(get_artifacts_dir)
REVIEW_STATE="$ARTIFACTS_DIR/plan-review-status"

run_hook() {
    local input="$1"
    local exit_code=0
    echo "$input" | bash "$HOOK" 2>/dev/null || exit_code=$?
    echo "$exit_code"
}

# test_plan_review_gate_exits_zero_on_non_plan_command
# Non-ExitPlanMode tool calls should pass through immediately
INPUT='{"tool_name":"Bash","tool_input":{"command":"ls -la"}}'
EXIT_CODE=$(run_hook "$INPUT")
assert_eq "test_plan_review_gate_exits_zero_on_non_plan_command" "0" "$EXIT_CODE"

# test_plan_review_gate_exits_zero_on_edit_tool
# Edit tool → not ExitPlanMode → pass through
INPUT='{"tool_name":"Edit","tool_input":{"file_path":"/tmp/test.py"}}'
EXIT_CODE=$(run_hook "$INPUT")
assert_eq "test_plan_review_gate_exits_zero_on_edit_tool" "0" "$EXIT_CODE"

# test_plan_review_gate_exits_zero_on_empty_input
# Empty stdin → exit 0 (no tool_name)
EXIT_CODE=$(run_hook "")
assert_eq "test_plan_review_gate_exits_zero_on_empty_input" "0" "$EXIT_CODE"

# test_plan_review_gate_blocks_exit_plan_mode_without_review
# ExitPlanMode with no review marker → should block (exit 2)
# Save any existing state
ORIG_STATE=""
if [[ -f "$REVIEW_STATE" ]]; then
    ORIG_STATE=$(cat "$REVIEW_STATE")
    rm -f "$REVIEW_STATE"
fi

INPUT='{"tool_name":"ExitPlanMode","tool_input":{}}'
EXIT_CODE=$(run_hook "$INPUT")
assert_eq "test_plan_review_gate_blocks_exit_plan_mode_without_review" "2" "$EXIT_CODE"

# test_plan_review_gate_blocks_exit_plan_mode_with_failed_review
# ExitPlanMode with failed review → should block (exit 2)
mkdir -p "$ARTIFACTS_DIR"
echo "failed" > "$REVIEW_STATE"

INPUT='{"tool_name":"ExitPlanMode","tool_input":{}}'
EXIT_CODE=$(run_hook "$INPUT")
assert_eq "test_plan_review_gate_blocks_exit_plan_mode_with_failed_review" "2" "$EXIT_CODE"

# test_plan_review_gate_exits_zero_on_exit_plan_mode_with_passed_review
# ExitPlanMode with passed review → should allow (exit 0)
echo "passed" > "$REVIEW_STATE"

INPUT='{"tool_name":"ExitPlanMode","tool_input":{}}'
EXIT_CODE=$(run_hook "$INPUT")
assert_eq "test_plan_review_gate_exits_zero_on_exit_plan_mode_with_passed_review" "0" "$EXIT_CODE"

# Restore original state
if [[ -n "$ORIG_STATE" ]]; then
    echo "$ORIG_STATE" > "$REVIEW_STATE"
else
    rm -f "$REVIEW_STATE"
fi

print_summary
