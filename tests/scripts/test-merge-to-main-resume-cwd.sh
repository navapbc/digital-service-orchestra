#!/usr/bin/env bash
# tests/scripts/test-merge-to-main-resume-cwd.sh
# Behavioral tests for the CWD-correctness invariant in merge-to-main.sh:
#   Bug 34cc-526c: --resume skips _phase_sync, so cd "$MAIN_REPO" (inside
#                  _phase_sync) never runs → _phase_merge and _phase_push
#                  execute from the worktree dir → push fails non-fast-forward.
#   Bug 687d-b448: same root — _phase_version_bump runs in worktree context,
#                  amend targets worktree HEAD (not MAIN_REPO HEAD) → MAIN_REPO
#                  commit unchanged; state file records version_bump=complete.
#
# Both bugs share the same fix: _phase_merge must cd into MAIN_REPO at its
# start, making CWD-correctness self-contained rather than inheriting from
# _phase_sync. These tests verify that invariant.
#
# Correctness gap (reviewer finding): when --resume skips _phase_merge entirely
# (because merge is already complete) and resumes from _phase_version_bump,
# _phase_validate, or _phase_push, no cd "$MAIN_REPO" would execute. These
# phases therefore each carry their own explicit cd "$MAIN_REPO" guard.
#
# Tests:
#   1. test_phase_merge_begins_with_cd_main_repo
#      _phase_merge() must contain an explicit cd "$MAIN_REPO" as its first
#      git-context operation (after state bookkeeping). RED: absent before fix.
#
#   2. test_phase_merge_cd_main_repo_precedes_git_merge
#      The cd "$MAIN_REPO" line must appear BEFORE any 'git merge' call inside
#      the same function body. RED: cd absent before fix, so this also fails.
#
#   3. test_phase_version_bump_has_standalone_cd_main_repo
#      _phase_version_bump must contain its own standalone cd "$MAIN_REPO" so
#      that --resume-from-version_bump (skipping _phase_merge) runs in the
#      correct directory. Each downstream phase is self-contained.
#
#   4. test_phase_validate_has_standalone_cd_main_repo
#      _phase_validate must contain its own standalone cd "$MAIN_REPO" for the
#      same reason: --resume can skip _phase_merge entirely.
#
#   5. test_phase_push_has_standalone_cd_main_repo
#      _phase_push must contain its own standalone cd "$MAIN_REPO" to protect
#      bare git push from running in the worktree on resume.
#
# Usage: bash tests/scripts/test-merge-to-main-resume-cwd.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DSO_PLUGIN_DIR="$PLUGIN_ROOT/plugins/dso"
MERGE_SCRIPT="$DSO_PLUGIN_DIR/scripts/merge-to-main.sh"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

echo "=== test-merge-to-main-resume-cwd.sh ==="
echo ""

# ---------------------------------------------------------------------------
# Helper: extract a named function body from merge-to-main.sh
# ---------------------------------------------------------------------------
_extract_fn() {
    local fn_name="$1"
    awk "/^${fn_name}\\(\\)/{found=1} found{print; if(/^\\}$/){exit}}" "$MERGE_SCRIPT"
}

# ---------------------------------------------------------------------------
# Precondition: merge-to-main.sh must exist
# ---------------------------------------------------------------------------
if [[ ! -f "$MERGE_SCRIPT" ]]; then
    echo "SKIP: merge-to-main.sh not found at $MERGE_SCRIPT" >&2
    exit 0
fi

# ---------------------------------------------------------------------------
# test_phase_merge_begins_with_cd_main_repo
#
# _phase_merge() must contain 'cd "$MAIN_REPO"' to ensure it always runs
# from the main repo regardless of whether --resume skipped _phase_sync.
# Before the fix: _phase_merge has NO such cd → test FAILS (RED).
# After the fix:  _phase_merge starts with cd "$MAIN_REPO" → test PASSES.
# ---------------------------------------------------------------------------
echo "--- test_phase_merge_begins_with_cd_main_repo ---"

_MERGE_BODY=$(_extract_fn "_phase_merge" 2>/dev/null || echo "")
_HAS_CD_MAIN_REPO="no"
if echo "$_MERGE_BODY" | grep -qE 'cd[[:space:]]+"?\$MAIN_REPO"?'; then
    _HAS_CD_MAIN_REPO="yes"
fi
assert_eq "test_phase_merge_begins_with_cd_main_repo" "yes" "$_HAS_CD_MAIN_REPO"

echo ""

# ---------------------------------------------------------------------------
# test_phase_merge_cd_main_repo_precedes_git_merge
#
# The cd "$MAIN_REPO" must appear BEFORE the 'git merge --no-ff' call so that
# git merge runs against the main repo HEAD, not the worktree HEAD.
# Both lines must be present AND in the correct order.
# Before the fix: cd absent → test FAILS (RED).
# After the fix:  cd appears before git merge → test PASSES.
# ---------------------------------------------------------------------------
echo "--- test_phase_merge_cd_main_repo_precedes_git_merge ---"

_CD_LINE=$(echo "$_MERGE_BODY" | grep -nE 'cd[[:space:]]+"?\$MAIN_REPO"?' | head -1 | cut -d: -f1)
_GIT_MERGE_LINE=$(echo "$_MERGE_BODY" | grep -nE 'git merge --no-ff' | head -1 | cut -d: -f1)

_ORDER_CORRECT="no"
if [[ -n "$_CD_LINE" && -n "$_GIT_MERGE_LINE" ]]; then
    if [[ "$_CD_LINE" -lt "$_GIT_MERGE_LINE" ]]; then
        _ORDER_CORRECT="yes"
    fi
fi
assert_eq "test_phase_merge_cd_main_repo_precedes_git_merge" "yes" "$_ORDER_CORRECT"

echo ""

# ---------------------------------------------------------------------------
# test_phase_version_bump_has_standalone_cd_main_repo
#
# _phase_version_bump must contain its own standalone cd "$MAIN_REPO" so that
# --resume-from-version_bump (which skips _phase_merge entirely when merge is
# already complete) still runs git operations from the main repo, not the
# worktree. Each phase that uses bare git commands must be self-contained.
# RED: absent before reviewer fix; GREEN after adding the cd guard.
# ---------------------------------------------------------------------------
echo "--- test_phase_version_bump_has_standalone_cd_main_repo ---"

_BUMP_BODY=$(_extract_fn "_phase_version_bump" 2>/dev/null || echo "")
# Check for standalone 'cd "$MAIN_REPO"' lines (not inside subshells like (cd ...))
_BUMP_HAS_STANDALONE_CD="no"
if echo "$_BUMP_BODY" | grep -qE '^[[:space:]]*cd[[:space:]]+"?\$MAIN_REPO"?' 2>/dev/null; then
    _BUMP_HAS_STANDALONE_CD="yes"
fi
assert_eq "test_phase_version_bump_has_standalone_cd_main_repo" "yes" "$_BUMP_HAS_STANDALONE_CD"

echo ""

# ---------------------------------------------------------------------------
# test_phase_validate_has_standalone_cd_main_repo
#
# _phase_validate must contain its own standalone cd "$MAIN_REPO" so that
# --resume-from-validate (skipping _phase_merge) runs from the main repo.
# Bare git operations in this phase (git add .gitignore, git diff --cached,
# git commit --amend) require CWD to be MAIN_REPO.
# ---------------------------------------------------------------------------
echo "--- test_phase_validate_has_standalone_cd_main_repo ---"

_VALIDATE_BODY=$(_extract_fn "_phase_validate" 2>/dev/null || echo "")
_VALIDATE_HAS_STANDALONE_CD="no"
if echo "$_VALIDATE_BODY" | grep -qE '^[[:space:]]*cd[[:space:]]+"?\$MAIN_REPO"?' 2>/dev/null; then
    _VALIDATE_HAS_STANDALONE_CD="yes"
fi
assert_eq "test_phase_validate_has_standalone_cd_main_repo" "yes" "$_VALIDATE_HAS_STANDALONE_CD"

echo ""

# ---------------------------------------------------------------------------
# test_phase_push_has_standalone_cd_main_repo
#
# _phase_push must contain its own standalone cd "$MAIN_REPO" so that
# --resume-from-push (skipping _phase_merge) runs bare git push from the
# main repo, not the worktree.
# ---------------------------------------------------------------------------
echo "--- test_phase_push_has_standalone_cd_main_repo ---"

_PUSH_BODY=$(_extract_fn "_phase_push" 2>/dev/null || echo "")
_PUSH_HAS_STANDALONE_CD="no"
if echo "$_PUSH_BODY" | grep -qE '^[[:space:]]*cd[[:space:]]+"?\$MAIN_REPO"?' 2>/dev/null; then
    _PUSH_HAS_STANDALONE_CD="yes"
fi
assert_eq "test_phase_push_has_standalone_cd_main_repo" "yes" "$_PUSH_HAS_STANDALONE_CD"

echo ""

print_summary
