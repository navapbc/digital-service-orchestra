#!/usr/bin/env bash
# tests/hooks/test-edit-block-generated-agents.sh
# Unit tests for hook_block_generated_reviewer_agents in pre-edit-write-functions.sh.
#
# Tests:
#   test_hook_blocks_edit_to_generated_agent_file
#   test_hook_blocks_write_to_generated_agent_file
#   test_hook_allows_edit_to_non_generated_file
#   test_hook_blocks_all_6_generated_reviewer_names
#   test_hook_detects_conflict_markers_in_generated_file
#
# Usage: bash tests/hooks/test-edit-block-generated-agents.sh
# Exit code: 0 if all pass, 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DSO_PLUGIN_DIR="$PLUGIN_ROOT/plugins/dso"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

# Source hook functions (gives us hook_block_generated_reviewer_agents)
# Reset guards so we can re-source
unset _PRE_EDIT_WRITE_FUNCTIONS_LOADED
unset _PRE_BASH_FUNCTIONS_LOADED
unset _DEPS_LOADED
source "$DSO_PLUGIN_DIR/hooks/lib/pre-edit-write-functions.sh"

# Verify the function exists — if not, all tests fail RED
if ! declare -f hook_block_generated_reviewer_agents &>/dev/null; then
    echo "FAIL: hook_block_generated_reviewer_agents is not defined (RED — function not yet implemented)" >&2
    FAIL=5
    print_summary
fi

# ============================================================
# test_hook_blocks_edit_to_generated_agent_file
# Edit to a generated reviewer agent file must be blocked (exit 2)
# with guidance pointing to source fragments and build-review-agents.sh
# ============================================================
echo "--- test_hook_blocks_edit_to_generated_agent_file ---"
_INPUT='{"tool_name":"Edit","tool_input":{"file_path":"'"$PLUGIN_ROOT"'/plugins/dso/agents/code-reviewer-light.md","old_string":"old","new_string":"new"}}'
_exit_code=0
_output=""
_output=$(hook_block_generated_reviewer_agents "$_INPUT" 2>&1) || _exit_code=$?
assert_eq "blocks_edit_to_generated_agent: exit 2" "2" "$_exit_code"
assert_contains "blocks_edit_to_generated_agent: BLOCKED" "BLOCKED" "$_output"
assert_contains "blocks_edit_to_generated_agent: mentions source fragments" "source fragments" "$_output"
assert_contains "blocks_edit_to_generated_agent: mentions build script" "build-review-agents.sh" "$_output"

# ============================================================
# test_hook_blocks_write_to_generated_agent_file
# Write to a generated reviewer agent file must be blocked (exit 2)
# ============================================================
echo "--- test_hook_blocks_write_to_generated_agent_file ---"
_INPUT='{"tool_name":"Write","tool_input":{"file_path":"'"$PLUGIN_ROOT"'/plugins/dso/agents/code-reviewer-standard.md","content":"new content"}}'
_exit_code=0
_output=""
_output=$(hook_block_generated_reviewer_agents "$_INPUT" 2>&1) || _exit_code=$?
assert_eq "blocks_write_to_generated_agent: exit 2" "2" "$_exit_code"
assert_contains "blocks_write_to_generated_agent: BLOCKED" "BLOCKED" "$_output"

# ============================================================
# test_hook_allows_edit_to_non_generated_file
# Edit to a non-generated agent file (e.g., complexity-evaluator.md) must pass (exit 0)
# ============================================================
echo "--- test_hook_allows_edit_to_non_generated_file ---"
_INPUT='{"tool_name":"Edit","tool_input":{"file_path":"'"$PLUGIN_ROOT"'/plugins/dso/agents/complexity-evaluator.md","old_string":"old","new_string":"new"}}'
_exit_code=0
_output=""
_output=$(hook_block_generated_reviewer_agents "$_INPUT" 2>&1) || _exit_code=$?
assert_eq "allows_edit_to_non_generated: exit 0" "0" "$_exit_code"

# ============================================================
# test_hook_blocks_all_6_generated_reviewer_names
# Each of the 6 code-reviewer-*.md names must be blocked
# ============================================================
echo "--- test_hook_blocks_all_6_generated_reviewer_names ---"
_GENERATED_NAMES=(
    "code-reviewer-light.md"
    "code-reviewer-standard.md"
    "code-reviewer-deep-correctness.md"
    "code-reviewer-deep-verification.md"
    "code-reviewer-deep-hygiene.md"
    "code-reviewer-deep-arch.md"
)
for _name in "${_GENERATED_NAMES[@]}"; do
    _INPUT='{"tool_name":"Edit","tool_input":{"file_path":"'"$PLUGIN_ROOT"'/plugins/dso/agents/'"$_name"'","old_string":"old","new_string":"new"}}'
    _exit_code=0
    _output=""
    _output=$(hook_block_generated_reviewer_agents "$_INPUT" 2>&1) || _exit_code=$?
    assert_eq "blocks_generated_reviewer_$_name: exit 2" "2" "$_exit_code"
done

# ============================================================
# test_hook_detects_conflict_markers_in_generated_file
# File content with <<<<<<< markers in a generated file must be blocked (exit 2)
# with specific regeneration guidance
# ============================================================
echo "--- test_hook_detects_conflict_markers_in_generated_file ---"
_CONFLICT_CONTENT='some content
<<<<<<< HEAD
old version
=======
new version
>>>>>>> branch
more content'
_INPUT='{"tool_name":"Write","tool_input":{"file_path":"'"$PLUGIN_ROOT"'/plugins/dso/agents/code-reviewer-light.md","content":"'"$(echo "$_CONFLICT_CONTENT" | sed 's/"/\\"/g')"'"}}'
_exit_code=0
_output=""
_output=$(hook_block_generated_reviewer_agents "$_INPUT" 2>&1) || _exit_code=$?
assert_eq "detects_conflict_markers: exit 2" "2" "$_exit_code"
assert_contains "detects_conflict_markers: regeneration guidance" "build-review-agents.sh" "$_output"

# ============================================================
# Summary
# ============================================================
print_summary
