#!/usr/bin/env bash
# recover-reaped-worktree.sh
# Tiered recovery for a worktree that the Claude Code harness reaped before the
# orchestrator could harvest it (bug 3ba5-0a11-02b8-483d). The 907d post-return
# existence check in per-worktree-review-commit.md and single-agent-integrate.md
# previously only HALTed; this helper attempts recovery before the loud halt.
#
# Usage:
#   recover-reaped-worktree.sh <worktree_branch> <session_root> [reported_file ...]
#
# Arguments:
#   worktree_branch  Git branch name the reaped worktree was on (may be empty).
#   session_root     Path to the session worktree (git repo) to inspect for leaks.
#   reported_file    Zero or more paths (relative to session_root) the sub-agent
#                    claimed to have written.
#
# Tiers (first match wins):
#   1. RECOVERABLE_VIA_BRANCH: <branch>  (exit 0)
#        worktree_branch is non-empty AND resolvable locally OR on origin.
#   2. RECOVERED_FROM_SESSION: <files>   (exit 0)
#        any reported_file exists non-empty under session_root and shows as
#        untracked/modified; such files are staged.
#   3. UNRECOVERABLE_REDISPATCH          (exit 3)
#        nothing recoverable — caller should revert the task to open + re-dispatch.
#
# Exit codes:
#   0  recovered (Tier 1 or Tier 2)
#   2  usage / invalid-input error
#   3  unrecoverable (Tier 3)

set -uo pipefail

# ── Parse / validate arguments ───────────────────────────────────────────────

if [ "$#" -lt 2 ]; then
    echo "ERROR: usage: recover-reaped-worktree.sh <worktree_branch> <session_root> [reported_file ...]" >&2
    exit 2
fi

WORKTREE_BRANCH="$1"
SESSION_ROOT="$2"
shift 2
# Remaining positional args are reported files (may be zero).

if [ -z "$SESSION_ROOT" ] || [ ! -d "$SESSION_ROOT" ]; then
    echo "ERROR: session_root does not exist or is not a directory: $SESSION_ROOT" >&2
    exit 2
fi

# ── Tier 1: recoverable via branch (local ref or origin) ─────────────────────

if [ -n "$WORKTREE_BRANCH" ]; then
    if git -C "$SESSION_ROOT" rev-parse --verify "$WORKTREE_BRANCH" >/dev/null 2>&1; then
        echo "RECOVERABLE_VIA_BRANCH: $WORKTREE_BRANCH"
        exit 0
    fi
    if git -C "$SESSION_ROOT" ls-remote --exit-code origin "$WORKTREE_BRANCH" >/dev/null 2>&1; then
        echo "RECOVERABLE_VIA_BRANCH: $WORKTREE_BRANCH"
        exit 0
    fi
fi

# ── Tier 2: recoverable from session leak ────────────────────────────────────
# Only proceed if session_root is itself a git work tree.

if git -C "$SESSION_ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    # Capture porcelain status once (untracked + modified entries).
    # --untracked-files=all expands entirely-untracked directories to their
    # individual files (default porcelain collapses 'src/foo.py' to 'src/').
    STATUS="$(git -C "$SESSION_ROOT" status --porcelain --untracked-files=all 2>/dev/null || true)"

    RECOVERED=""
    for f in "$@"; do
        [ -n "$f" ] || continue
        # File must exist and be non-empty under session_root.
        [ -s "$SESSION_ROOT/$f" ] || continue
        # File must show as untracked ('??') or modified/added in porcelain.
        # Porcelain lines look like 'XY <path>' (space-separated, path at col 4).
        if printf '%s\n' "$STATUS" | grep -qE "^.{2} \"?${f}\"?$"; then
            if [ -z "$RECOVERED" ]; then
                RECOVERED="$f"
            else
                RECOVERED="$RECOVERED $f"
            fi
        fi
    done

    if [ -n "$RECOVERED" ]; then
        # Stage the recovered files (word-split intentional: paths are space-joined).
        # shellcheck disable=SC2086
        git -C "$SESSION_ROOT" add -- $RECOVERED
        echo "RECOVERED_FROM_SESSION: $RECOVERED"
        exit 0
    fi
fi

# ── Tier 3: unrecoverable ────────────────────────────────────────────────────

echo "UNRECOVERABLE_REDISPATCH"
exit 3
