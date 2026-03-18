#!/usr/bin/env bash
# tests/scripts/test-shim-cross-context.sh
# Cross-context smoke tests for the dso shim installed at .claude/scripts/dso.
#
# Verifies that the shim resolves DSO_ROOT and exits 0 when invoked from:
#   - the repository root
#   - a subdirectory (hooks/)
#   - a git worktree (skips gracefully if worktrees are unavailable)
#
# Uses --lib mode (exits 0 on successful DSO_ROOT resolution without dispatching
# any command) so these tests are fast and have no side effects.
#
# Usage:
#   bash tests/scripts/test-shim-cross-context.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DSO_PLUGIN_DIR="$PLUGIN_ROOT/plugins/dso"
SHIM="$PLUGIN_ROOT/.claude/scripts/dso"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

WORKTREES=()
trap 'for wt in "${WORKTREES[@]:-}"; do git worktree remove --force "$wt" 2>/dev/null; rm -rf "$wt"; done' EXIT

echo "=== test-shim-cross-context.sh ==="

# ── test_shim_works_from_repo_root ────────────────────────────────────────────
# The shim must exit 0 (resolve DSO_ROOT) when invoked from the repository root.
test_shim_works_from_repo_root() {
    local exit_code=0
    bash "$SHIM" --lib >/dev/null 2>&1 || exit_code=$?
    assert_eq "test_shim_works_from_repo_root" "0" "$exit_code"
}

# ── test_shim_works_from_subdirectory ────────────────────────────────────────
# The shim must exit 0 when invoked from a subdirectory (hooks/).
# Verifies that git rev-parse --show-toplevel navigation inside the shim works
# regardless of the caller's CWD.
test_shim_works_from_subdirectory() {
    local exit_code=0
    (cd "$DSO_PLUGIN_DIR/hooks" && bash "$SHIM" --lib >/dev/null 2>&1) || exit_code=$?
    assert_eq "test_shim_works_from_subdirectory" "0" "$exit_code"
}

# ── test_shim_works_from_worktree ─────────────────────────────────────────────
# The shim must exit 0 when invoked from a git worktree.
# Skips gracefully (skip-as-pass idiom: assert_eq "0" "0") if git worktree add
# is unavailable or fails in this environment (e.g., shallow clone, CI).
test_shim_works_from_worktree() {
    local wttmp
    wttmp="$(mktemp -d)" || {
        echo "SKIP: mktemp failed"
        # skip-as-pass: worktree test skipped (unavailable)
        assert_eq "test_shim_works_from_worktree (skipped)" "0" "0"
        return
    }
    WORKTREES+=("$wttmp")

    if ! git -C "$PLUGIN_ROOT" worktree add "$wttmp/wt" HEAD >/dev/null 2>&1; then
        echo "SKIP: git worktree add failed — skipping cross-context worktree test"
        # skip-as-pass: assert_eq "0" "0" is the intentional skip-as-pass idiom
        assert_eq "test_shim_works_from_worktree (skipped)" "0" "0"
        return
    fi

    local exit_code=0
    (cd "$wttmp/wt" && bash "$SHIM" --lib >/dev/null 2>&1) || exit_code=$?
    assert_eq "test_shim_works_from_worktree" "0" "$exit_code"
}

# ── Run all tests ─────────────────────────────────────────────────────────────
test_shim_works_from_repo_root
test_shim_works_from_subdirectory
test_shim_works_from_worktree

print_summary
