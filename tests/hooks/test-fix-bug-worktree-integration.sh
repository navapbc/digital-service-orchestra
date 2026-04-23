#!/usr/bin/env bash
# tests/hooks/test-fix-bug-worktree-integration.sh
# Structural boundary tests for the worktree-integration additions to fix-bug/SKILL.md.
#
# These tests verify that fix-bug/SKILL.md contains the structural contracts
# required for worktree-isolation integration: the single-agent-integrate token,
# WORKTREE_PATH reference in Step 7, and an explicit isolation_enabled=false
# conditional clause with "existing" language.
#
# All 3 assertions are intentionally RED against the unmodified SKILL.md — they
# will turn GREEN once the corresponding implementation task updates the file.
#
# What we test (structural boundary):
#   1. 'single-agent-integrate' token present in SKILL.md
#   2. Step 7 section references WORKTREE_PATH or single-agent-integrate
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
# The Step 7 section of fix-bug/SKILL.md must reference WORKTREE_PATH or
# single-agent-integrate within 5 lines of the "Step 7" heading. Structural:
# Step 7 is the worktree result-harvest step; WORKTREE_PATH is the signal
# variable agents use to locate the worktree output.
# RED: current Step 7 section contains neither string.
# ===========================================================================
echo "--- test_step7_references_worktree_path_or_integrate ---"
_step7_count=$(grep -A5 "Step 7" "$SKILL_FILE" 2>/dev/null | grep -cE 'WORKTREE_PATH|single-agent-integrate'); _step7_count=${_step7_count:-0}
if [[ "$_step7_count" -gt 0 ]]; then
    assert_eq "test_step7_references_worktree_path_or_integrate: WORKTREE_PATH or single-agent-integrate in Step 7" "present" "present"
else
    assert_eq "test_step7_references_worktree_path_or_integrate: WORKTREE_PATH or single-agent-integrate in Step 7" "present" "missing"
fi

# ===========================================================================
# test_isolation_false_existing_conditional_present
# fix-bug/SKILL.md must contain an explicit 'isolation_enabled=false'
# conditional clause paired with "existing" language, describing the
# single-agent path that integrates directly into the existing worktree.
# Structural: the conditional clause is the behavioral contract that routes
# agents to the correct integration path when isolation is disabled.
# RED: current SKILL.md has isolation/false mentions but NOT the combined
#      'isolation_enabled=false.*existing' pattern.
# ===========================================================================
echo "--- test_isolation_false_existing_conditional_present ---"
_iso_count=$(grep -Ec 'isolation_enabled=false.*existing' "$SKILL_FILE" 2>/dev/null); _iso_count=${_iso_count:-0}
if [[ "$_iso_count" -gt 0 ]]; then
    assert_eq "test_isolation_false_existing_conditional_present: isolation_enabled=false...existing clause present" "present" "present"
else
    assert_eq "test_isolation_false_existing_conditional_present: isolation_enabled=false...existing clause present" "present" "missing"
fi

print_summary
