#!/usr/bin/env bash
# pre-commit-ticket-unstage-guard.sh — Pre-commit hook to prevent .tickets/ files
# from being committed on worktree branches.
#
# The ticket sync mechanism automatically commits .tickets/ changes to main via
# the PostToolUse hook (lockpick-workflow/hooks/ticket-sync-push.sh). Committing
# ticket files on a worktree branch causes merge conflicts when the branch is
# rebased onto main where the same ticket files already exist via the sync path.
#
# Behavior:
#   - On the main branch: no-op (exits 0). Ticket commits on main are legitimate.
#   - During a merge commit (MERGE_HEAD set): no-op (exits 0). Merge scripts manage
#     .tickets/ via stash/restore; modifying the index here blocks the merge commit.
#   - On any other branch: if .tickets/ files are staged, unstages them and prints
#     a warning. Then exits 0 to allow the commit to proceed with remaining files.
#
# The warning names each unstaged file and explains the automatic sync mechanism
# so developers know the changes are not lost.
#
# Integration: registered as a local hook in .pre-commit-config.yaml under the
# 'ticket-unstage-guard' id.
#
# Debug command: ./scripts/pre-commit-ticket-unstage-guard.sh

set -uo pipefail

# ── Determine current branch ─────────────────────────────────────────────────
CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "HEAD")

# On main, ticket commits are expected — allow them through.
if [[ "$CURRENT_BRANCH" == "main" ]]; then
    exit 0
fi

# Belt-and-suspenders: git passes $2="merge" for merge commits regardless of file paths
if [[ "${2:-}" == "merge" ]]; then
    exit 0
fi

# During a merge commit (MERGE_HEAD exists), ticket files in the index are
# part of the merge resolution managed by worktree-sync-from-main.sh and
# merge-to-main.sh. Those scripts handle .tickets/ separately via stash/restore.
# Don't modify the index here — doing so causes pre-commit to mark the hook
# "Failed" and block the merge commit.
GIT_DIR=$(git rev-parse --git-dir 2>/dev/null || true)
if [[ -n "$GIT_DIR" && -f "$GIT_DIR/MERGE_HEAD" ]]; then
    exit 0
fi

# ── Check for staged .tickets/ files ─────────────────────────────────────────
STAGED_TICKET_FILES=$(git diff --cached --name-only 2>/dev/null | grep '\.tickets/' || true)

if [[ -z "$STAGED_TICKET_FILES" ]]; then
    exit 0  # Nothing to unstage
fi

# ── Unstage all .tickets/ files ──────────────────────────────────────────────
# git reset HEAD .tickets/ unstages all files under .tickets/ without touching
# the working tree. The files remain on disk but are removed from the index.
git reset HEAD .tickets/ 2>/dev/null || true

# ── Print warning ─────────────────────────────────────────────────────────────
echo "" >&2
echo "⚠  WARNING: .tickets/ files removed from this commit (branch: $CURRENT_BRANCH)" >&2
echo "" >&2
echo "   The following ticket files were unstaged automatically:" >&2
while IFS= read -r file; do
    [[ -z "$file" ]] && continue
    echo "     - $file" >&2
done <<< "$STAGED_TICKET_FILES"
echo "" >&2
echo "   Ticket changes are synced to main automatically via the PostToolUse" >&2
echo "   hook (ticket-sync-push). Committing .tickets/ files on worktree branches" >&2
echo "   causes merge conflicts when rebasing onto main." >&2
echo "" >&2
echo "   Your other staged files are unaffected. The commit will proceed normally." >&2
echo "" >&2

# ── Exit 0 to allow commit to proceed ────────────────────────────────────────
exit 0
