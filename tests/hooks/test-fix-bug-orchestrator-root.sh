#!/usr/bin/env bash
# tests/hooks/test-fix-bug-orchestrator-root.sh
# Structural interface test for the WORKTREE_PATH != ORCHESTRATOR_ROOT guard
# pattern in plugins/dso/skills/fix-bug/SKILL.md.
#
# What we test (structural boundary):
#   - SKILL.md contains the combined guard pattern referencing both
#     WORKTREE_PATH and ORCHESTRATOR_ROOT in the same expression,
#     indicating an explicit isolation guard is present.
#
# What we do NOT test:
#   - The exact wording or prose around the guard
#   - Other ORCHESTRATOR_ROOT or WORKTREE_PATH references in isolation
#
# RED state: fix-bug/SKILL.md has ORCHESTRATOR_ROOT in documentation only —
#   the combined guard expression does NOT yet exist. This assertion will FAIL
#   until the implementation task adds the guard.
#
# Usage:
#   bash tests/hooks/test-fix-bug-orchestrator-root.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SKILL_FILE="$REPO_ROOT/plugins/dso/skills/fix-bug/SKILL.md"

source "$REPO_ROOT/tests/lib/assert.sh"

echo "=== test-fix-bug-orchestrator-root.sh ==="

# ===========================================================================
# test_worktree_path_orchestrator_root_guard_present
# fix-bug/SKILL.md must contain a combined guard pattern that references both
# WORKTREE_PATH and ORCHESTRATOR_ROOT together. This signals the explicit
# isolation check: "if WORKTREE_PATH != ORCHESTRATOR_ROOT, treat as sub-agent
# worktree context". Structural: the guard pattern is the machine-readable
# contract that agents use to determine which execution context they are in.
#
# Uses grep -Ec (extended regex) so | is treated as alternation, not literal.
# Without -E, grep -c treats | as a literal character and the count stays 0
# even after the guard is added.
# ===========================================================================
echo "--- test_worktree_path_orchestrator_root_guard_present ---"
_guard_count=$(grep -Ec 'WORKTREE_PATH.*ORCHESTRATOR_ROOT|ORCHESTRATOR_ROOT.*WORKTREE_PATH' "$SKILL_FILE" 2>/dev/null || true)
_guard_count="${_guard_count:-0}"
if [[ "$_guard_count" -gt 0 ]]; then
    assert_eq "test_worktree_path_orchestrator_root_guard_present: combined guard pattern present" "present" "present"
else
    assert_eq "test_worktree_path_orchestrator_root_guard_present: combined guard pattern present" "present" "missing"
fi

print_summary
