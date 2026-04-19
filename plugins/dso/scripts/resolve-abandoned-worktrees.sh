#!/usr/bin/env bash
# resolve-abandoned-worktrees.sh
# Scan local branches for abandoned worktrees and merge or skip each one.
#
# Usage: resolve-abandoned-worktrees.sh [--repo <path>] [--session-branch <branch>]
#   --repo <path>            Path to git repo root (default: current repo via git rev-parse)
#   --session-branch <name>  Branch to merge into (default: current branch)
#
# For each local branch that is NOT the session branch:
#   - If already an ancestor of the session branch: skip (already merged)
#   - If has unique commits: attempt git merge --no-edit
#     - On success: log 'Merged abandoned branch <b>'
#     - On conflict: git merge --abort, log 'Conflict in <b> — discarded'

set -uo pipefail

_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Argument parsing ──────────────────────────────────────────────────────────

_REPO=""
_SESSION_BRANCH=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --repo)
            _REPO="$2"
            shift 2
            ;;
        --session-branch)
            _SESSION_BRANCH="$2"
            shift 2
            ;;
        *)
            echo "Unknown argument: $1" >&2
            exit 1
            ;;
    esac
done

# Resolve repo root
if [[ -z "$_REPO" ]]; then
    _REPO=$(git rev-parse --show-toplevel 2>/dev/null || echo "")
    if [[ -z "$_REPO" ]]; then
        echo "ERROR: not in a git repo and --repo not specified" >&2
        exit 1
    fi
fi

# Resolve session branch
if [[ -z "$_SESSION_BRANCH" ]]; then
    _SESSION_BRANCH=$(git -C "$_REPO" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
    if [[ -z "$_SESSION_BRANCH" ]]; then
        echo "ERROR: could not determine current branch and --session-branch not specified" >&2
        exit 1
    fi
fi

# ── Clean up any mid-merge state before scanning ─────────────────────────────

if [[ -f "$_REPO/.git/MERGE_HEAD" ]]; then
    echo "INFO: MERGE_HEAD detected — aborting in-progress merge before scan" >&2
    git -C "$_REPO" merge --abort 2>/dev/null || true
fi

# ── Scan all local branches except the session branch ────────────────────────

_merged_count=0
_skipped_count=0
_conflict_count=0

while IFS= read -r _branch; do
    # Skip the session branch itself
    [[ "$_branch" == "$_SESSION_BRANCH" ]] && continue

    # Check if branch is already an ancestor of the session branch
    if git -C "$_REPO" merge-base --is-ancestor "$_branch" "$_SESSION_BRANCH" 2>/dev/null; then
        echo "INFO: Branch $_branch is already merged into $_SESSION_BRANCH — skipping" >&2
        _skipped_count=$((_skipped_count + 1))
        continue
    fi

    # Branch has unique commits — attempt merge
    local_merge_exit=0
    git -C "$_REPO" merge --no-edit "$_branch" 2>/dev/null || local_merge_exit=$?
    if [[ "$local_merge_exit" -eq 0 ]]; then
        echo "INFO: Merged abandoned branch $_branch" >&2
        _merged_count=$((_merged_count + 1))
    else
        git -C "$_REPO" merge --abort 2>/dev/null || true
        echo "INFO: Conflict in $_branch — discarded" >&2
        _conflict_count=$((_conflict_count + 1))
    fi
done < <(git -C "$_REPO" branch --format='%(refname:short)' 2>/dev/null)

echo "resolve-abandoned-worktrees: merged=${_merged_count} skipped=${_skipped_count} discarded=${_conflict_count}" >&2
