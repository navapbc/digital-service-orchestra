#!/usr/bin/env bash
# tests/hooks/test-debug-everything-worktree-integration.sh
# Structural boundary test for debug-everything/SKILL.md worktree integration.
#
# This test verifies that debug-everything Bug-Fix Mode correctly references
# the single-agent-integrate workflow when DISPATCH_ISOLATION=true. These
# assertions are RED until task T8 adds the single-agent-integrate.md
# integration to debug-everything/SKILL.md.
#
# What we test (structural boundary):
#   1. SKILL.md contains the string "single-agent-integrate"
#   2. The Bug-Fix Mode section references single-agent-integrate.md in a
#      "when DISPATCH_ISOLATION=true" context
#
# Usage:
#   bash tests/hooks/test-debug-everything-worktree-integration.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SKILL_FILE="$REPO_ROOT/plugins/dso/skills/debug-everything/SKILL.md"

source "$REPO_ROOT/tests/lib/assert.sh"

echo "=== test-debug-everything-worktree-integration.sh ==="

# ===========================================================================
# test_skill_contains_single_agent_integrate
# debug-everything/SKILL.md must reference "single-agent-integrate" to route
# Bug-Fix Mode through the worktree integration workflow. The string is the
# navigable interface between the orchestrator and the integration prompt —
# its absence means the worktree integration path is never invoked.
# ===========================================================================
echo "--- test_skill_contains_single_agent_integrate ---"
# REVIEW-DEFENSE: grep -c returns an integer (0 or more); `|| true` ensures exit 0 when file
# is absent (grep exits non-zero). ${_count:-0} sets empty string to 0 as a defensive guard.
# Both assertions in this file use the same consistent pattern intentionally.
_count=$(grep -c 'single-agent-integrate' "$SKILL_FILE" 2>/dev/null || true)
_count="${_count:-0}"
if [[ "$_count" -gt 0 ]]; then
    assert_eq "test_skill_contains_single_agent_integrate: single-agent-integrate present in SKILL.md" "present" "present"
else
    assert_eq "test_skill_contains_single_agent_integrate: single-agent-integrate present in SKILL.md" "present" "missing"
fi

# ===========================================================================
# test_bug_fix_mode_references_single_agent_integrate_with_dispatch_isolation
# The Bug-Fix Mode section must reference single-agent-integrate.md in a
# DISPATCH_ISOLATION=true context. Structural: this guards the routing logic —
# agents must see both the condition (DISPATCH_ISOLATION=true) and the target
# prompt (single-agent-integrate.md) co-located so the branch is unambiguous.
# ===========================================================================
echo "--- test_bug_fix_mode_references_single_agent_integrate_with_dispatch_isolation ---"
_context_count=$(grep -Ec 'DISPATCH_ISOLATION.*single-agent-integrate|single-agent-integrate.*DISPATCH_ISOLATION' "$SKILL_FILE" 2>/dev/null || true)
_context_count="${_context_count:-0}"
if [[ "$_context_count" -gt 0 ]]; then
    assert_eq "test_bug_fix_mode_references_single_agent_integrate_with_dispatch_isolation: DISPATCH_ISOLATION+single-agent-integrate co-located" "present" "present"
else
    assert_eq "test_bug_fix_mode_references_single_agent_integrate_with_dispatch_isolation: DISPATCH_ISOLATION+single-agent-integrate co-located" "present" "missing"
fi

print_summary
