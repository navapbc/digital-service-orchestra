#!/usr/bin/env bash
# tests/hooks/test-worktree-dispatch-orchestrator-root.sh
# RED tests for worktree-dispatch.md — verifies that the document contains
# the {orchestrator_root} placeholder and a reference to single-agent-integrate.
#
# Both assertions FAIL before task T6b (worktree-dispatch.md does not yet
# contain these strings) and pass after T6b adds them.
#
# What we test (structural contract):
#   1. {orchestrator_root} literal placeholder exists in worktree-dispatch.md
#   2. single-agent-integrate reference exists in worktree-dispatch.md
#
# Usage:
#   bash tests/hooks/test-worktree-dispatch-orchestrator-root.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TARGET_FILE="$REPO_ROOT/plugins/dso/skills/shared/prompts/worktree-dispatch.md"

source "$REPO_ROOT/tests/lib/assert.sh"

echo "=== test-worktree-dispatch-orchestrator-root.sh ==="

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

print_summary
