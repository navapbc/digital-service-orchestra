#!/usr/bin/env bash
set -euo pipefail
# lockpick-workflow/scripts/git-revert-safe.sh
# Wrapper around `git revert` that strips .tickets/ files from the revert commit
# by default. This prevents ticket sync state changes from contaminating reverts
# of application code.
#
# Usage:
#   git-revert-safe.sh [--include-tickets] <commit-ish> [<commit-ish>...]
#
# Options:
#   --include-tickets   Include .tickets/ files in the revert commit (disable
#                       the default strip behavior).
#
# Behavior:
#   1. Runs: git revert --no-commit <commit-ish(es)>
#   2. Checks staged index for .tickets/ files
#   3. If .tickets/ files are staged AND --include-tickets was NOT given:
#      - Unstages them via: git reset HEAD .tickets/
#      - Prints a warning to stderr listing each stripped file
#   4. Runs: git commit (auto-generated revert message)
#
# Exit codes:
#   0  success
#   1  git revert or git commit failed
set -euo pipefail

INCLUDE_TICKETS=false
COMMIT_ARGS=()

# ── Argument parsing ──────────────────────────────────────────────────────────
for arg in "$@"; do
    case "$arg" in
        --include-tickets)
            INCLUDE_TICKETS=true
            ;;
        *)
            COMMIT_ARGS+=("$arg")
            ;;
    esac
done

if [ "${#COMMIT_ARGS[@]}" -eq 0 ]; then
    echo "Usage: git-revert-safe.sh [--include-tickets] <commit-ish> [<commit-ish>...]" >&2
    exit 1
fi

# ── Step 1: Run git revert --no-commit ───────────────────────────────────────
# Capture the exit code so we can handle conflicts explicitly instead of
# letting set -e abort the script and leave the repo in a mid-revert state.
revert_exit=0
git revert --no-commit "${COMMIT_ARGS[@]}" || revert_exit=$?
if [ "$revert_exit" -ne 0 ]; then
    echo "Error: 'git revert --no-commit' failed (exit $revert_exit)." >&2
    echo "       The working tree may have conflict markers that need manual resolution." >&2
    echo "       Run 'git revert --abort' to cancel and restore the previous state." >&2
    git revert --abort 2>/dev/null || true
    exit "$revert_exit"
fi

# ── Step 2: Check for staged .tickets/ files ─────────────────────────────────
STAGED_TICKETS=$(git diff --cached --name-only | grep '^\.tickets/' || true)

# ── Step 3: Strip .tickets/ files if not opted in ────────────────────────────
if [ -n "$STAGED_TICKETS" ] && [ "$INCLUDE_TICKETS" = false ]; then
    # Print warning to stderr listing each stripped file
    echo "Warning: Stripping .tickets/ files from revert commit (use --include-tickets to keep them):" >&2
    while IFS= read -r filepath; do
        echo "  $filepath" >&2
    done <<< "$STAGED_TICKETS"

    # Unstage the .tickets/ directory (suppress stdout — output is not part of this
    # script's documented interface; only stderr warnings are produced by this script).
    git reset HEAD .tickets/ >/dev/null

    # Restore .tickets/ working-tree files to their HEAD state so the caller's
    # working tree is left clean (not dirty with unstaged .tickets/ modifications).
    git checkout HEAD -- .tickets/ 2>/dev/null || true
fi

# ── Step 4: Commit with auto-generated revert message ────────────────────────
# If stripping .tickets/ left no staged changes, abort the revert cleanly.
if [ -z "$(git diff --cached --name-only)" ]; then
    echo "Warning: Revert commit would be empty after stripping .tickets/ files — aborting revert." >&2
    # Use git revert --abort to cleanly undo the no-commit revert state.
    # This correctly restores both the index and working tree without discarding
    # any untracked files or other unstaged changes the caller may have had.
    git revert --abort
    exit 0
fi

git commit --no-edit
