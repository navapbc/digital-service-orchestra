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

    RECOVERED_ARR=()
    for f in "$@"; do
        [ -n "$f" ] || continue
        # File must exist and be non-empty under session_root.
        [ -s "$SESSION_ROOT/$f" ] || continue
        # File must show as untracked ('??') or modified/added in porcelain.
        # Porcelain lines look like 'XY <path>' (2 status chars + space + path,
        # path at col 4). Match the path field LITERALLY (string equality) — a
        # file path is NOT a regex, and paths routinely contain regex
        # metacharacters ('.', '+', '[', '(') that would mis-match under
        # `grep -E` (e.g. 'src/app.py' would match 'src/appXpy', and '[' could
        # error). Reported on PR #534 review (recover-reaped-worktree.sh:79).
        _match=""
        while IFS= read -r _line; do
            [ -n "$_line" ] || continue
            _p="${_line#???}"          # strip 'XY ' (2 status chars + 1 space)
            case "$_p" in              # git quotes paths containing special chars
                \"*\") _p="${_p#\"}"; _p="${_p%\"}" ;;
            esac
            if [ "$_p" = "$f" ]; then _match=1; break; fi
        done <<INNER_EOF
$STATUS
INNER_EOF
        if [ -n "$_match" ]; then
            RECOVERED_ARR+=("$f")
        fi
    done

    if [ ${#RECOVERED_ARR[@]} -gt 0 ]; then
        # Stage each recovered file via the array (each element quoted, preserved
        # exactly) — paths may contain spaces or glob/metacharacters; the prior
        # space-joined `$RECOVERED` word-split broke such paths (e.g. a recovered
        # 'src/my file.py' would be split into 'src/my' and 'file.py', leaving the
        # real file unstaged). Reported on PR #548 review (recover-reaped-worktree.sh:109).
        if ! git -C "$SESSION_ROOT" add -- "${RECOVERED_ARR[@]}"; then
            echo "UNRECOVERABLE_REDISPATCH"
            exit 3
        fi
        echo "RECOVERED_FROM_SESSION: ${RECOVERED_ARR[*]}"
        exit 0
    fi
fi

# ── Tier 3: unrecoverable ────────────────────────────────────────────────────

echo "UNRECOVERABLE_REDISPATCH"
exit 3
