#!/usr/bin/env bash
set -euo pipefail
# worktree-sync-from-main.sh — Sync a worktree branch with the latest main
#
# Fetches origin/main and merges it into the current worktree branch, then
# fetches the latest ticket state from origin/tickets so the worktree's
# .tickets-tracker/ is current.
#
# Referenced from WORKTREE-GUIDE.md and sprint/SKILL.md Step 3.
# Run before launching sub-agent batches to ensure ticket state and code are current.
#
# Usage:
#   worktree-sync-from-main.sh [--skip-tickets] [--skip-code]
#
# Options:
#   --skip-tickets   Skip syncing the tickets branch
#   --skip-code      Skip merging origin/main into the worktree branch
#   --help           Print this usage message and exit
#
# Exit codes:
#   0 — Sync complete (or no-op if already up to date)
#   1 — Fatal error (merge conflict that could not be auto-resolved; not in worktree)
#
# Notes:
#   - Must be run from inside a worktree (i.e., .git is a file, not a directory)
#   - Non-ticket merge conflicts are reported and exit 1 so the caller can
#     invoke /dso:resolve-conflicts before continuing
#   - Ticket sync failures are non-fatal (stale ticket state < blocked batch)

set -euo pipefail

# ── Argument parsing ─────────────────────────────────────────────────────────

SKIP_TICKETS=0
SKIP_CODE=0

for arg in "$@"; do
    case "$arg" in
        --skip-tickets) SKIP_TICKETS=1 ;;
        --skip-code)    SKIP_CODE=1 ;;
        --help)
            cat <<'USAGE'
Usage: worktree-sync-from-main.sh [--skip-tickets] [--skip-code]

  --skip-tickets   Skip syncing the tickets branch
  --skip-code      Skip merging origin/main into the worktree branch
  --help           Print this usage message and exit

Syncs the current worktree branch with the latest origin/main and pulls the
latest ticket state from origin/tickets into .tickets-tracker/.
USAGE
            exit 0
            ;;
        *)
            echo "ERROR: Unknown option: $arg" >&2
            echo "Run '$0 --help' for usage." >&2
            exit 1
            ;;
    esac
done

# ── Locate repo root ─────────────────────────────────────────────────────────

REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || echo "")
if [ -z "$REPO_ROOT" ]; then
    echo "ERROR: Not inside a git repository." >&2
    exit 1
fi

# Must be called from a worktree (.git is a file, not a directory)
if [ -d "$REPO_ROOT/.git" ]; then
    echo "ERROR: Not inside a worktree. Run from a worktree session, not the main repo." >&2
    exit 1
fi

CURRENT_BRANCH=$(git branch --show-current 2>/dev/null || echo "")
if [ -z "$CURRENT_BRANCH" ]; then
    echo "ERROR: Could not determine current branch (detached HEAD?)." >&2
    exit 1
fi

echo "Syncing worktree '$CURRENT_BRANCH' from main..." >&2

# ── 1) Merge origin/main into the worktree branch ────────────────────────────

if [ "$SKIP_CODE" -eq 0 ]; then
    echo "  Fetching origin/main..." >&2
    if ! git fetch origin main --quiet 2>/dev/null; then
        echo "  WARNING: git fetch origin main failed — skipping code sync." >&2
    else
        # Check if already up to date
        LOCAL_SHA=$(git rev-parse HEAD)
        ORIGIN_MAIN_SHA=$(git rev-parse origin/main 2>/dev/null || echo "")
        MERGE_BASE=$(git merge-base HEAD origin/main 2>/dev/null || echo "")

        if [ "$MERGE_BASE" = "$ORIGIN_MAIN_SHA" ]; then
            echo "  OK: Worktree branch is already up to date with origin/main." >&2
        else
            echo "  Merging origin/main into $CURRENT_BRANCH..." >&2
            if ! git merge origin/main --no-edit -q 2>&1; then
                echo "ERROR: Merge of origin/main failed. Resolve conflicts then re-run." >&2
                echo "       Use /dso:resolve-conflicts for guided conflict resolution." >&2
                exit 1
            fi
            echo "  OK: Merged origin/main into $CURRENT_BRANCH." >&2
        fi
    fi
else
    echo "  Skipping code sync (--skip-code)." >&2
fi

# ── 2) Sync ticket state from origin/tickets ─────────────────────────────────

if [ "$SKIP_TICKETS" -eq 0 ]; then
    # Locate .tickets-tracker/ — it is a git worktree on the tickets branch
    # mounted relative to the main (non-worktree) checkout.  From a worktree,
    # git rev-parse --git-common-dir points to the main repo's .git directory.
    MAIN_GIT_DIR=$(git rev-parse --git-common-dir 2>/dev/null || echo "")
    MAIN_REPO=""
    if [ -n "$MAIN_GIT_DIR" ]; then
        MAIN_REPO=$(dirname "$MAIN_GIT_DIR")
    fi

    TRACKER_DIR=""
    if [ -n "$MAIN_REPO" ] && [ -d "$MAIN_REPO/.tickets-tracker" ]; then
        TRACKER_DIR="$MAIN_REPO/.tickets-tracker"
    elif [ -d "$REPO_ROOT/.tickets-tracker" ]; then
        TRACKER_DIR="$REPO_ROOT/.tickets-tracker"
    fi

    if [ -z "$TRACKER_DIR" ]; then
        echo "  INFO: .tickets-tracker/ not found — skipping ticket sync." >&2
    elif ! git -C "$TRACKER_DIR" rev-parse --verify tickets &>/dev/null; then
        echo "  INFO: tickets branch not found in .tickets-tracker/ — skipping ticket sync." >&2
    else
        echo "  Syncing tickets branch from origin..." >&2
        if git -C "$TRACKER_DIR" fetch origin tickets --quiet 2>/dev/null; then
            REMOTE_EXISTS=$(git -C "$TRACKER_DIR" rev-parse --verify origin/tickets 2>/dev/null || echo "")
            if [ -n "$REMOTE_EXISTS" ]; then
                if git -C "$TRACKER_DIR" pull --rebase origin tickets --quiet 2>/dev/null; then
                    echo "  OK: Ticket state synced from origin/tickets." >&2
                else
                    echo "  WARNING: Ticket rebase from origin/tickets failed — continuing with local state." >&2
                fi
            else
                echo "  INFO: origin/tickets not available — using local ticket state." >&2
            fi
        else
            echo "  WARNING: git fetch origin tickets failed — using local ticket state." >&2
        fi
    fi
else
    echo "  Skipping ticket sync (--skip-tickets)." >&2
fi

echo "Sync complete." >&2
