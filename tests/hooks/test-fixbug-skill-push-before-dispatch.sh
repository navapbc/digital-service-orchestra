#!/usr/bin/env bash
# tests/hooks/test-fixbug-skill-push-before-dispatch.sh
# Structural test: fix-bug SKILL.md contains a pre-dispatch git push step
# for session-worktree isolation (bug 4724-41a7).
#
# What we test (structural boundary — acceptable per behavioral-testing-standard Rule 5):
#   - git push -u origin HEAD appears in the file (the push command is the integration
#     interface that enables sub-agent worktrees to branch from session HEAD)
#   - IS_SESSION_WORKTREE detection expression is present (detection gate for the push)
#   - SESSION_HEAD and SESSION_BRANCH variable assignments are present (injected into
#     sub-agent prompts per worktree-dispatch.md protocol)
#   - Reference to bug 4724-41a7 or worktree-dispatch.md appears in the file
#     (traceability: ties the push to the known bug fix)
#
# What we do NOT test (content assertions prohibited by Rule 5):
#   - LLM behavioral correctness (non-deterministic)
#   - Specific prose wording beyond the structural markers above
#
# Usage:
#   bash tests/hooks/test-fixbug-skill-push-before-dispatch.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

source "$REPO_ROOT/tests/lib/assert.sh"

SKILL_FILE="$REPO_ROOT/plugins/dso/skills/fix-bug/SKILL.md"

echo "=== test-fixbug-skill-push-before-dispatch.sh ==="

# ---------------------------------------------------------------------------
# Guard: SKILL.md must exist
# ---------------------------------------------------------------------------
if [[ ! -f "$SKILL_FILE" ]]; then
    printf "FATAL: %s not found\n" "$SKILL_FILE" >&2
    exit 2
fi

# ===========================================================================
# test: git push -u origin HEAD appears in fix-bug/SKILL.md
# This is the integration interface that pushes the session branch so
# sub-agent worktrees can be created from session HEAD instead of main HEAD.
# ===========================================================================
echo "--- git push -u origin HEAD present ---"
if grep -qF 'git push -u origin HEAD' "$SKILL_FILE"; then
    assert_eq "fixbug_skill_contains_git_push_origin_head" "present" "present"
else
    assert_eq "fixbug_skill_contains_git_push_origin_head" "present" "missing"
fi

# ===========================================================================
# test: IS_SESSION_WORKTREE detection expression present
# The detection gate determines whether the push is needed (session worktree
# vs. orchestrator running directly on main).
# ===========================================================================
echo "--- IS_SESSION_WORKTREE detection present ---"
if grep -qF 'IS_SESSION_WORKTREE' "$SKILL_FILE"; then
    assert_eq "fixbug_skill_contains_IS_SESSION_WORKTREE" "present" "present"
else
    assert_eq "fixbug_skill_contains_IS_SESSION_WORKTREE" "present" "missing"
fi

# ===========================================================================
# test: SESSION_HEAD variable assignment present
# SESSION_HEAD captures the commit SHA that sub-agents must sync to.
# It is injected into each sub-agent's prompt per worktree-dispatch.md.
# ===========================================================================
echo "--- SESSION_HEAD assignment present ---"
if grep -qF 'SESSION_HEAD' "$SKILL_FILE"; then
    assert_eq "fixbug_skill_contains_SESSION_HEAD" "present" "present"
else
    assert_eq "fixbug_skill_contains_SESSION_HEAD" "present" "missing"
fi

# ===========================================================================
# test: SESSION_BRANCH variable assignment present
# SESSION_BRANCH identifies the branch name sub-agents fetch from origin.
# It is injected alongside SESSION_HEAD per worktree-dispatch.md protocol.
# ===========================================================================
echo "--- SESSION_BRANCH assignment present ---"
if grep -qF 'SESSION_BRANCH' "$SKILL_FILE"; then
    assert_eq "fixbug_skill_contains_SESSION_BRANCH" "present" "present"
else
    assert_eq "fixbug_skill_contains_SESSION_BRANCH" "present" "missing"
fi

# ===========================================================================
# test: bug 4724-41a7 or worktree-dispatch.md referenced in the file
# Traceability contract: the push step must be tied to the bug that motivated
# it, or reference the injection protocol doc that consumes SESSION_BRANCH/HEAD.
# ===========================================================================
echo "--- bug 4724-41a7 or worktree-dispatch.md reference present ---"
if grep -qF '4724-41a7' "$SKILL_FILE" || grep -qF 'worktree-dispatch.md' "$SKILL_FILE"; then
    assert_eq "fixbug_skill_contains_bug_or_dispatch_ref" "present" "present"
else
    assert_eq "fixbug_skill_contains_bug_or_dispatch_ref" "present" "missing"
fi

print_summary
