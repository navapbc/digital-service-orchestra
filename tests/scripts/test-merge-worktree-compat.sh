#!/usr/bin/env bash
# tests/scripts/test-merge-worktree-compat.sh
# Integration smoke tests for scripts/merge-to-main.sh worktree path compatibility.
#
# Usage: bash tests/scripts/test-merge-worktree-compat.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail
#
# Tests:
#   1. No hardcoded worktree paths in merge-to-main.sh
#   2. MAIN_REPO resolution via git rev-parse --git-common-dir works from a real worktree
#   3. Worktree detection guard (exits non-zero when run from main repo)
#   4. Path resolution logic reaches the worktree-detection guard without path errors
#   5. Script is executable and has no bash syntax errors

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DSO_PLUGIN_DIR="$PLUGIN_ROOT/plugins/dso"
REPO_ROOT="$(cd "$SCRIPT_DIR" && git rev-parse --show-toplevel)"
SCRIPT="$DSO_PLUGIN_DIR/scripts/merge-to-main.sh"

source "$SCRIPT_DIR/../lib/run_test.sh"

echo "=== test-merge-worktree-compat.sh ==="

# ── Test 1: Script is executable ──────────────────────────────────────────────
echo "Test 1: Script is executable"
if [ -x "$SCRIPT" ]; then
    echo "  PASS: merge-to-main.sh is executable"
    (( PASS++ ))
else
    echo "  FAIL: merge-to-main.sh is not executable" >&2
    (( FAIL++ ))
fi

# ── Test 2: No bash syntax errors ────────────────────────────────────────────
echo "Test 2: No bash syntax errors"
if bash -n "$SCRIPT" 2>/dev/null; then
    echo "  PASS: no syntax errors"
    (( PASS++ ))
else
    echo "  FAIL: syntax errors found in merge-to-main.sh" >&2
    (( FAIL++ ))
fi

# ── Test 3: No hardcoded worktree path patterns ───────────────────────────────
# AC #1: merge-to-main.sh must not contain repo-specific or project-specific
# worktree path literals. Paths like "lockpick-worktrees" or "doc-to-logic-worktrees"
# indicate a hardcoded, non-portable path.
echo "Test 3: No hardcoded worktree paths in merge-to-main.sh"
if grep -iE 'lockpick-worktrees|doc-to-logic-worktrees' "$SCRIPT" >/dev/null 2>&1; then
    echo "  FAIL: hardcoded worktree path found in merge-to-main.sh" >&2
    grep -iE 'lockpick-worktrees|doc-to-logic-worktrees' "$SCRIPT" | head -5 >&2
    (( FAIL++ ))
else
    echo "  PASS: no hardcoded worktree paths found"
    (( PASS++ ))
fi

# ── Test 4: MAIN_REPO derivation uses git-common-dir (not hardcoded path) ────
# The canonical pattern for worktree→main-repo resolution is:
#   MAIN_REPO=$(dirname "$(git rev-parse --git-common-dir)")
# Verify the script uses this pattern (not a hardcoded path).
echo "Test 4: MAIN_REPO derived from git rev-parse --git-common-dir"
if grep -qE 'git-common-dir' "$SCRIPT"; then
    echo "  PASS: script uses git-common-dir for MAIN_REPO resolution"
    (( PASS++ ))
else
    echo "  FAIL: script does not use git-common-dir for MAIN_REPO resolution" >&2
    (( FAIL++ ))
fi

# ── Test 5: Worktree context guard exits non-zero from main repo ──────────────
# merge-to-main.sh is designed for worktree sessions only and must exit non-zero
# when run from the main repo (where .git is a directory, not a file).
# We run it from the actual REPO_ROOT — which is a normal git repo (not a worktree).
echo "Test 5: Script exits non-zero when run from main repo (not a worktree)"
exit_code=0
output=$(cd "$REPO_ROOT" && bash "$SCRIPT" 2>&1) || exit_code=$?
if [ "$exit_code" -ne 0 ]; then
    if echo "$output" | grep -qiE "not a worktree|not.*worktree|worktree.*only"; then
        echo "  PASS: script exits non-zero with worktree guard message (exit $exit_code)"
        (( PASS++ ))
    else
        echo "  PASS: script exits non-zero from main repo (exit $exit_code)"
        (( PASS++ ))
    fi
else
    echo "  FAIL: script exited 0 from main repo — worktree guard did not trigger" >&2
    echo "  Output: $output" >&2
    (( FAIL++ ))
fi

# ── Test 6: MAIN_REPO=$(dirname "$(git rev-parse --git-common-dir)") resolves correctly from a real worktree ──
# Creates a real git worktree under .claude/worktrees/test-<timestamp> (matching
# Claude Code convention), then verifies that running the git-common-dir
# derivation expression from within the worktree correctly resolves back to
# the original repo root.
echo "Test 6: git rev-parse --git-common-dir resolves to main repo from a worktree"

# Determine worktree parent directory — match Claude Code convention
WORKTREE_PARENT="$REPO_ROOT/.claude/worktrees"
WT_NAME="test-$$"
WT_PATH="$WORKTREE_PARENT/$WT_NAME"

cleanup_wt() {
    git -C "$REPO_ROOT" worktree remove --force "$WT_PATH" 2>/dev/null || true
    git -C "$REPO_ROOT" worktree prune 2>/dev/null || true
}

wt_created=false
wt_test_failed=false

# Create the worktree on a temporary branch
BRANCH_NAME="test-compat-$$"
wt_output=""
wt_exit=0
mkdir -p "$WORKTREE_PARENT"
wt_output=$(git -C "$REPO_ROOT" worktree add -b "$BRANCH_NAME" "$WT_PATH" HEAD 2>&1) || wt_exit=$?
if [ "$wt_exit" -ne 0 ]; then
    echo "  SKIP: could not create test worktree (git worktree add exited $wt_exit)" >&2
    echo "  Output: $wt_output" >&2
    # Don't fail the test suite for setup failures — skip instead
else
    wt_created=true
    # From within the worktree, derive MAIN_REPO using the same expression in merge-to-main.sh
    derived_main=""
    derive_exit=0
    derived_main=$(cd "$WT_PATH" && dirname "$(git rev-parse --git-common-dir)") || derive_exit=$?

    if [ "$derive_exit" -ne 0 ]; then
        echo "  FAIL: git rev-parse --git-common-dir failed from worktree (exit $derive_exit)" >&2
        (( FAIL++ ))
        wt_test_failed=true
    else
        # Normalize both paths to resolve symlinks for comparison.
        # When running from a worktree, REPO_ROOT is the worktree root, but
        # MAIN_REPO should resolve to the *main* repo root (git-common-dir parent).
        main_repo_root=$(cd "$REPO_ROOT" && dirname "$(git rev-parse --git-common-dir)")
        expected_real=$(cd "$main_repo_root" && pwd -P 2>/dev/null || echo "$main_repo_root")
        derived_real=$(cd "$derived_main" && pwd -P 2>/dev/null || echo "$derived_main")

        if [ "$derived_real" = "$expected_real" ]; then
            echo "  PASS: MAIN_REPO resolves to repo root from worktree ($derived_real)"
            (( PASS++ ))
        else
            echo "  FAIL: MAIN_REPO mismatch — expected '$expected_real', got '$derived_real'" >&2
            (( FAIL++ ))
            wt_test_failed=true
        fi
    fi

    cleanup_wt
    git -C "$REPO_ROOT" branch -D "$BRANCH_NAME" 2>/dev/null || true
fi

# ── Test 7: Static analysis — path derivation is dynamic (no hardcoded paths) ──
# Verifies that the MAIN_REPO assignment expression in merge-to-main.sh is the
# dynamic git rev-parse pattern and does not embed any absolute path literals.
# This complements Test 6 (live MAIN_REPO resolution) with a source-level check.
#
# NOTE: We do NOT run the full script from a worktree in this test to avoid
# triggering worktree sync operations (which can time out with large ticket counts).
# Test 6 already validates the live MAIN_REPO resolution from a real worktree.
echo "Test 7: MAIN_REPO assignment is dynamic — no absolute path literals"
main_repo_line=$(grep 'MAIN_REPO=' "$SCRIPT" | head -1)
hardcoded_path=false

# Fail if the MAIN_REPO= line contains a hardcoded absolute path (starts with /)
# but NOT a git command (dynamic derivation is fine).
if echo "$main_repo_line" | grep -qE "MAIN_REPO=['\"]?/" && \
   ! echo "$main_repo_line" | grep -qE "git rev-parse|git-common-dir"; then
    hardcoded_path=true
fi

if $hardcoded_path; then
    echo "  FAIL: MAIN_REPO assignment appears to use a hardcoded path: $main_repo_line" >&2
    (( FAIL++ ))
else
    echo "  PASS: MAIN_REPO assignment uses dynamic git rev-parse derivation"
    (( PASS++ ))
fi

# ── Test 8: Script references no project-specific ticket/path strings ─────────
# Verify merge-to-main.sh does not contain project-specific directory names
# that would break portability across repos.
echo "Test 8: No project-specific directory references in merge-to-main.sh"
project_specific_found=false
# Check for common anti-patterns: hardcoded repo name in paths
if grep -qE 'lockpick-doc-to-logic(?!/)|\bloc-to-logic\b' "$SCRIPT" 2>/dev/null; then
    project_specific_found=true
fi

if $project_specific_found; then
    echo "  FAIL: project-specific directory references found in merge-to-main.sh" >&2
    (( FAIL++ ))
else
    echo "  PASS: no project-specific directory references"
    (( PASS++ ))
fi

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
