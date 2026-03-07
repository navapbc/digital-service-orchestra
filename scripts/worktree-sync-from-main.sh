#!/usr/bin/env bash
# scripts/worktree-sync-from-main.sh
# Sync a worktree branch with origin/main by fetching, merging, and preserving
# local .tickets/ changes. Handles skip-worktree flags that block standard
# git stash/merge operations.
#
# Usage: scripts/worktree-sync-from-main.sh
# Exit codes: 0=success, 1=error (non-ticket merge conflict)
#
# This script is called by:
#   - /sprint Phase 4 (pre-batch update from main)
#   - merge-to-main.sh (pre-merge sync)
#   - Any worktree workflow needing to pull latest from main
#
# The ticket stash/restore logic is extracted from merge-to-main.sh to provide
# a single reusable entry point. Never run bare `git merge origin/main` in a
# worktree — use this script instead.

set -euo pipefail

# --- Resolve repo root ---
if ! REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null); then
    echo "ERROR: Not a git repository."
    exit 1
fi

# --- Load ticket sync library ---
_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$_SCRIPT_DIR/tk-sync-lib.sh" || { echo "ERROR: tk-sync-lib.sh not found"; exit 1; }

# --- Allow sourcing without executing ---
# When merge-to-main.sh sources this file to call _worktree_sync_from_main,
# it should not execute the main block. Only run when executed directly.
_worktree_sync_from_main() {
    local quiet="${1:-}"

    # --- 1) Clear skip-worktree flags ---
    # The ticket-sync-push hook sets skip-worktree after pushing to suppress
    # git status noise, but this makes .tickets/ files invisible to git
    # stash/add/diff, causing merge failures.
    _clear_ticket_skip_worktree

    # --- 2) Stash .tickets/ files ---
    # Local .tickets/ files may be modified (by tk CLI via Bash tool) or
    # untracked (new tickets). These block git merge. Stash them, merge,
    # then restore.
    local UNTRACKED_TICKETS MODIFIED_TICKETS TICKETS_STASHED
    UNTRACKED_TICKETS=$(git ls-files --others -- .tickets/ 2>/dev/null || true)
    MODIFIED_TICKETS=$(git diff --name-only -- .tickets/ 2>/dev/null || true)
    TICKETS_STASHED=false

    if [ -n "$UNTRACKED_TICKETS" ] || [ -n "$MODIFIED_TICKETS" ]; then
        echo "Stashing .tickets/ changes before merge..."
        # Stage untracked tickets so git stash captures them
        if [ -n "$UNTRACKED_TICKETS" ]; then
            git add .tickets/ 2>/dev/null || true
        fi
        git stash push --quiet -m "worktree-sync: ticket stash" -- .tickets/ 2>/dev/null && TICKETS_STASHED=true
        # If stash failed (nothing to stash), force-clean as fallback
        if ! $TICKETS_STASHED; then
            git checkout -- .tickets/ 2>/dev/null || true
            git clean -fd .tickets/ 2>/dev/null || true
        fi
    fi

    # --- 3) Fetch and merge ---
    echo "Syncing worktree with main..."
    if ! git fetch origin main 2>&1; then
        echo "ERROR: git fetch origin main failed."
        # Restore stash before exiting
        if $TICKETS_STASHED; then
            git stash pop --quiet 2>/dev/null || git stash drop --quiet 2>/dev/null || true
        fi
        return 1
    fi

    if ! git merge origin/main ${quiet:+--quiet} --no-edit 2>&1; then
        local CONFLICTED
        CONFLICTED=$(git diff --name-only --diff-filter=U 2>/dev/null || true)
        # Auto-resolve .tickets/ conflicts — worktree version wins
        local NON_TICKET_CONFLICTS
        NON_TICKET_CONFLICTS=$(echo "$CONFLICTED" | grep -v '^\.tickets/' || true)
        if [ -z "$NON_TICKET_CONFLICTS" ] && [ -n "$CONFLICTED" ]; then
            echo "Auto-resolving ticket conflicts (worktree wins)..."
            git checkout --ours -- .tickets/ 2>/dev/null || true
            git add .tickets/ 2>/dev/null || true
            git commit --no-edit --quiet 2>/dev/null || true
            echo "OK: Auto-resolved ticket conflicts."
        else
            local BRANCH
            BRANCH=$(git branch --show-current 2>/dev/null || echo "unknown")
            echo "ERROR: Merge conflict with non-ticket files."
            echo "CONFLICT_DATA: direction=main-into-worktree branch=$BRANCH merge_base=$(git merge-base HEAD origin/main 2>/dev/null || echo unknown)"
            [ -n "$CONFLICTED" ] && echo "CONFLICT_FILES: $CONFLICTED"
            # Restore stash before exiting
            if $TICKETS_STASHED; then
                git stash pop --quiet 2>/dev/null || git stash drop --quiet 2>/dev/null || true
            fi
            return 1
        fi
    fi
    echo "OK: Worktree synced with main."

    # --- 4) Restore stashed .tickets/ files ---
    # Worktree version wins on conflict (these are the session's authoritative edits).
    if $TICKETS_STASHED; then
        echo "Restoring stashed .tickets/ changes..."
        if ! git stash pop --quiet 2>/dev/null; then
            # Stash pop conflicted with merged ticket files — accept worktree version
            echo "Resolving ticket stash conflicts (worktree wins)..."
            git checkout --ours -- .tickets/ 2>/dev/null || true
            git reset HEAD .tickets/ 2>/dev/null || true
            git stash drop --quiet 2>/dev/null || true
        else
            # Stash pop succeeded — unstage any auto-staged files from the stash
            git reset HEAD .tickets/ 2>/dev/null || true
        fi
    fi

    return 0
}

# --- Execute when run directly (not sourced) ---
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    cd "$REPO_ROOT"
    _worktree_sync_from_main "$@"
fi
