#!/usr/bin/env bash
# scripts/worktree-sync-from-main.sh
# Sync a worktree branch with origin/main by fetching and merging.
#
# Usage: scripts/worktree-sync-from-main.sh
# Exit codes: 0=success, 1=error (merge conflict)
#
# This script is called by:
#   - /sprint Phase 4 (pre-batch update from main)
#   - merge-to-main.sh (pre-merge sync)
#   - Any worktree workflow needing to pull latest from main
#
# Never run bare `git merge origin/main` in a worktree — use this script instead.

set -euo pipefail

# --- Resolve repo root ---
if ! REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null); then
    echo "ERROR: Not a git repository."
    exit 1
fi

# Source config-paths.sh for CFG_PYTHON_VENV
_SYNC_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_sync_config_paths="${CLAUDE_PLUGIN_ROOT:-$_SYNC_SCRIPT_DIR/..}/hooks/lib/config-paths.sh"
[[ -f "$_sync_config_paths" ]] && source "$_sync_config_paths"

# --- Ensure pre-commit is available in PATH ---
# git merge --no-edit auto-commits, which runs pre-commit hooks. If the venv
# is not activated, `pre-commit` is not found and the merge commit fails.
# Probe the conventional venv location and prepend it without activating the
# full venv (activation changes PS1, sys.path, and other env state).
_VENV_BIN="$REPO_ROOT/$(dirname "$CFG_PYTHON_VENV")"
if [[ -f "$_VENV_BIN/pre-commit" && ":$PATH:" != *":$_VENV_BIN:"* ]]; then
    export PATH="$_VENV_BIN:$PATH"
fi

_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- Allow sourcing without executing ---
# When merge-to-main.sh sources this file to call _worktree_sync_from_main,
# it should not execute the main block. Only run when executed directly.
_worktree_sync_from_main() {
    local quiet="${1:-}"

    # --- 1) Fetch and merge ---
    echo "Syncing worktree with main..."
    if ! git fetch origin main 2>&1; then
        echo "ERROR: git fetch origin main failed."
        return 1
    fi

    if ! git merge origin/main ${quiet:+--quiet} --no-edit 2>&1; then
        local CONFLICTED
        CONFLICTED=$(git diff --name-only --diff-filter=U 2>/dev/null || true)
        local BRANCH
        BRANCH=$(git branch --show-current 2>/dev/null || echo "unknown")
        echo "ERROR: Merge conflict."
        echo "CONFLICT_DATA: direction=main-into-worktree branch=$BRANCH merge_base=$(git merge-base HEAD origin/main 2>/dev/null || echo unknown)"
        [ -n "$CONFLICTED" ] && echo "CONFLICT_FILES: $CONFLICTED"
        git merge --abort 2>/dev/null || true
        return 1
    fi
    echo "OK: Worktree synced with main."

    return 0
}

# --- Execute when run directly (not sourced) ---
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    cd "$REPO_ROOT"
    _worktree_sync_from_main "$@"
fi
