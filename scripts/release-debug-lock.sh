#!/usr/bin/env bash
# Release a /debug-everything session lock if held by this worktree.
# Usage: release-debug-lock.sh [reason]
#   reason: optional message for the lock release (default: "Session complete")
#
# Exit codes:
#   0 - Lock released, or no lock held by this worktree
#   1 - Error checking lock status

set -euo pipefail

REPO_ROOT=$(git rev-parse --show-toplevel)
REASON="${1:-Session complete}"

# Check for an active lock using the canonical lock-status subcommand
LOCK_STATUS=$("$REPO_ROOT/scripts/agent-batch-lifecycle.sh" lock-status "debug-everything" 2>/dev/null) || {
    echo "WARN: Could not check lock status" >&2
    exit 0
}

if echo "$LOCK_STATUS" | grep -q "^LOCKED:"; then
    LOCK_ID=$(echo "$LOCK_STATUS" | sed 's/^LOCKED: *//')

    # Verify the lock belongs to this worktree session
    LOCK_WORKTREE=$(tk show "$LOCK_ID" 2>/dev/null | grep -oE 'Worktree: [^ ]+' | sed 's/Worktree: //' || true)

    if [ "$LOCK_WORKTREE" = "$REPO_ROOT" ]; then
        "$REPO_ROOT/scripts/agent-batch-lifecycle.sh" lock-release "$LOCK_ID" "$REASON"
        echo "Released lock: $LOCK_ID"
    else
        echo "Lock $LOCK_ID belongs to a different worktree ($LOCK_WORKTREE) — skipping."
    fi
else
    echo "No active debug-everything lock — skipping."
fi
