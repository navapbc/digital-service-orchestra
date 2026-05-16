#!/usr/bin/env bash
# tests/hooks/test-fix-bug-worktree-integration.sh
# Structural boundary tests for the worktree-integration additions to fix-bug/SKILL.md.
#
# These tests verify that fix-bug/SKILL.md contains the structural contracts
# required for worktree-isolation integration: the single-agent-integrate token,
# WORKTREE_PATH reference in the Verify Fix step, and an explicit isolation_enabled=false
# conditional clause with "existing" language.
#
# All 3 assertions are intentionally RED against the unmodified SKILL.md — they
# will turn GREEN once the corresponding implementation task updates the file.
#
# What we test (structural boundary):
#   1. 'single-agent-integrate' token present in SKILL.md
#   2. Verify Fix step section references WORKTREE_PATH or single-agent-integrate
#   3. Explicit 'isolation_enabled=false' conditional with "existing" language
#
# Usage:
#   bash tests/hooks/test-fix-bug-worktree-integration.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SKILL_FILE="$REPO_ROOT/plugins/dso/skills/fix-bug/SKILL.md"

source "$REPO_ROOT/tests/lib/assert.sh"

echo "=== test-fix-bug-worktree-integration.sh ==="

# ===========================================================================
# test_single_agent_integrate_token_present
# fix-bug/SKILL.md must contain the 'single-agent-integrate' token so agents
# can identify the worktree integration path. This is the navigable contract
# token for the new integration behavior.
# RED: current SKILL.md does not contain this string.
# ===========================================================================
echo "--- test_single_agent_integrate_token_present ---"
_count=$(grep -c 'single-agent-integrate' "$SKILL_FILE" 2>/dev/null); _count=${_count:-0}
if [[ "$_count" -gt 0 ]]; then
    assert_eq "test_single_agent_integrate_token_present: token present in SKILL.md" "present" "present"
else
    assert_eq "test_single_agent_integrate_token_present: token present in SKILL.md" "present" "missing"
fi

# ===========================================================================
# test_step7_references_worktree_path_or_integrate
# The Verify Fix step section of fix-bug/SKILL.md must reference WORKTREE_PATH or
# single-agent-integrate within 5 lines of the "Step 7" heading. Structural:
# The Verify Fix step is the worktree result-harvest step; WORKTREE_PATH is the signal
# variable agents use to locate the worktree output.
# RED: current Verify Fix step section contains neither string.
# ===========================================================================
echo "--- test_step7_references_worktree_path_or_integrate ---"
_step7_count=$(grep -A5 -E "Step [0-9]+: Verify Fix" "$SKILL_FILE" 2>/dev/null | grep -cE 'WORKTREE_PATH|single-agent-integrate'); _step7_count=${_step7_count:-0}
if [[ "$_step7_count" -gt 0 ]]; then
    assert_eq "test_step7_references_worktree_path_or_integrate: WORKTREE_PATH or single-agent-integrate in Verify Fix step" "present" "present"
else
    assert_eq "test_step7_references_worktree_path_or_integrate: WORKTREE_PATH or single-agent-integrate in Verify Fix step" "present" "missing"
fi

# ===========================================================================
# test_isolation_always_enabled_documented
# fix-bug/SKILL.md must document that worktree isolation is always enabled
# (the new always-on contract) and include the 'isolation: "worktree"' dispatch
# token used by agents to route correctly.
# GREEN once SKILL.md contains the always-enabled contract language.
# ===========================================================================
echo "--- test_isolation_false_branch_present ---"
# Asserts SKILL.md documents the always-enabled isolation contract.
_always_enabled=$(grep -c 'Worktree isolation is always enabled' "$SKILL_FILE" 2>/dev/null); _always_enabled=${_always_enabled:-0}
_dispatch_token=$(grep -c 'isolation: "worktree"' "$SKILL_FILE" 2>/dev/null); _dispatch_token=${_dispatch_token:-0}
if [[ "$_always_enabled" -gt 0 && "$_dispatch_token" -gt 0 ]]; then
    assert_eq "test_isolation_always_enabled_documented: always-enabled contract and dispatch token in SKILL.md" "present" "present"
else
    assert_eq "test_isolation_always_enabled_documented: always-enabled contract and dispatch token in SKILL.md (always_enabled=$_always_enabled dispatch_token=$_dispatch_token)" "present" "missing"
fi

print_summary
