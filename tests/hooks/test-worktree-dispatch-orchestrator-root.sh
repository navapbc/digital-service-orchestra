#!/usr/bin/env bash
# tests/hooks/test-worktree-dispatch-orchestrator-root.sh
# Structural tests for worktree-dispatch.md and task-execution.md.
#
# What we test (structural contracts):
#   worktree-dispatch.md:
#     1. {orchestrator_root} literal placeholder exists
#     2. single-agent-integrate reference exists
#     3. SESSION_BRANCH injection protocol present
#     4. SESSION_HEAD injection protocol present
#     5. worktree-session-head-sync.sh reference present
#     6. IS_SESSION_WORKTREE detection one-liner present
#   task-execution.md:
#     7. worktree-session-head-sync.sh reference present
#     8. SESSION_BRANCH reference present
#     9. SESSION_HEAD reference present
#
# Usage:
#   bash tests/hooks/test-worktree-dispatch-orchestrator-root.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TARGET_FILE="$REPO_ROOT/plugins/dso/skills/shared/prompts/worktree-dispatch.md"
TASK_EXEC_FILE="$REPO_ROOT/plugins/dso/skills/sprint/prompts/task-execution.md"

source "$REPO_ROOT/tests/lib/assert.sh"

echo "=== test-worktree-dispatch-orchestrator-root.sh ==="

# Read file contents once for assert_contains calls
_dispatch_content=$(cat "$TARGET_FILE" 2>/dev/null || true)
_task_exec_content=$(cat "$TASK_EXEC_FILE" 2>/dev/null || true)

# ===========================================================================
# test_orchestrator_root_placeholder_present
# worktree-dispatch.md must contain the literal string {orchestrator_root}
# so that dispatch prompts can inject the orchestrator working directory
# at runtime. Without this placeholder, sub-agents have no reliable path
# anchor back to the session root.
# ===========================================================================
echo "--- test_orchestrator_root_placeholder_present ---"
_count=$(grep -c '{orchestrator_root}' "$TARGET_FILE" 2>/dev/null || true)
_count="${_count:-0}"
if [[ "$_count" -gt 0 ]]; then
    assert_eq "test_orchestrator_root_placeholder_present: {orchestrator_root} found" "present" "present"
else
    assert_eq "test_orchestrator_root_placeholder_present: {orchestrator_root} found" "present" "missing"
fi

# ===========================================================================
# test_single_agent_integrate_reference_present
# worktree-dispatch.md must reference single-agent-integrate so that
# the dispatch prompt describes the integration path for single-agent
# worktree merge scenarios. Without this reference, agents lack the
# workflow step needed to merge their worktree back into the session.
# ===========================================================================
echo "--- test_single_agent_integrate_reference_present ---"
_count=$(grep -c 'single-agent-integrate' "$TARGET_FILE" 2>/dev/null || true)
_count="${_count:-0}"
if [[ "$_count" -gt 0 ]]; then
    assert_eq "test_single_agent_integrate_reference_present: single-agent-integrate found" "present" "present"
else
    assert_eq "test_single_agent_integrate_reference_present: single-agent-integrate found" "present" "missing"
fi

# ===========================================================================
# SESSION_BRANCH / SESSION_HEAD injection protocol (bug 4724-41a7 fix)
# worktree-dispatch.md must document the mandatory injection of SESSION_BRANCH
# and SESSION_HEAD so sub-agents can sync to the session HEAD via
# worktree-session-head-sync.sh.
# ===========================================================================
echo "--- test_session_branch_present ---"
assert_contains "SESSION_BRANCH present in worktree-dispatch.md" "SESSION_BRANCH" "$_dispatch_content"

echo "--- test_session_head_present ---"
assert_contains "SESSION_HEAD present in worktree-dispatch.md" "SESSION_HEAD" "$_dispatch_content"

echo "--- test_session_head_sync_script_present ---"
assert_contains "worktree-session-head-sync.sh present in worktree-dispatch.md" "worktree-session-head-sync.sh" "$_dispatch_content"

echo "--- test_is_session_worktree_present ---"
assert_contains "IS_SESSION_WORKTREE present in worktree-dispatch.md" "IS_SESSION_WORKTREE" "$_dispatch_content"

# ===========================================================================
# task-execution.md structural assertions
# task-execution.md Pre-Step must call worktree-session-head-sync.sh when
# SESSION_BRANCH and SESSION_HEAD are set, ensuring sub-agents launched
# under isolation:worktree start from the correct session commit.
# ===========================================================================
echo "--- test_task_exec_session_head_sync_present ---"
assert_contains "worktree-session-head-sync.sh present in task-execution.md" "worktree-session-head-sync.sh" "$_task_exec_content"

echo "--- test_task_exec_session_branch_present ---"
assert_contains "SESSION_BRANCH present in task-execution.md" "SESSION_BRANCH" "$_task_exec_content"

echo "--- test_task_exec_session_head_present ---"
assert_contains "SESSION_HEAD present in task-execution.md" "SESSION_HEAD" "$_task_exec_content"

print_summary
