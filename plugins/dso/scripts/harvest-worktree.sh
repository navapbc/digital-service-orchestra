#!/usr/bin/env bash
# harvest-worktree.sh
# Merges a worktree branch into the current (session) branch after validating
# that the worktree's gate artifacts (test-gate-status, review-status) pass.
#
# Usage:
#   harvest-worktree.sh <worktree-branch> <worktree-artifacts-dir> [--session-artifacts <dir>]
#
# Arguments:
#   worktree-branch        Git branch name to merge
#   worktree-artifacts-dir Path to the worktree's artifacts directory containing gate files
#   --session-artifacts    Optional: directory to write attested gate files for the session
#
# Exit codes:
#   0  Success (merge commit created, or branch already merged)
#   1  Conflict in non-.test-index files, or MERGE_HEAD present on entry
#   2  Gate verification failed (test-gate-status or review-status missing/failed)

set -euo pipefail

# ── Parse arguments ──────────────────────────────────────────────────────────

WORKTREE_BRANCH=""
WORKTREE_ARTIFACTS_DIR=""
SESSION_ARTIFACTS_DIR=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --session-artifacts)
            SESSION_ARTIFACTS_DIR="$2"
            shift 2
            ;;
        *)
            if [[ -z "$WORKTREE_BRANCH" ]]; then
                WORKTREE_BRANCH="$1"
            elif [[ -z "$WORKTREE_ARTIFACTS_DIR" ]]; then
                WORKTREE_ARTIFACTS_DIR="$1"
            else
                echo "ERROR: unexpected argument: $1" >&2
                exit 1
            fi
            shift
            ;;
    esac
done

if [[ -z "$WORKTREE_BRANCH" || -z "$WORKTREE_ARTIFACTS_DIR" ]]; then
    echo "Usage: harvest-worktree.sh <worktree-branch> <worktree-artifacts-dir> [--session-artifacts <dir>]" >&2
    exit 1
fi

# ── Verify no MERGE_HEAD on entry ────────────────────────────────────────────

GIT_DIR=$(git rev-parse --git-dir 2>/dev/null || echo ".git")

if [[ -f "$GIT_DIR/MERGE_HEAD" ]]; then
    echo "ERROR: MERGE_HEAD already exists — a merge is in progress. Abort or complete it first." >&2
    exit 1
fi

# ── Trap: clean up MERGE_HEAD on any failure ─────────────────────────────────

_harvest_exit_code=0
_harvest_cleanup() {
    local ec=${_harvest_exit_code:-$?}
    if [[ -f "$GIT_DIR/MERGE_HEAD" ]]; then
        git merge --abort 2>/dev/null || true
    fi
    exit "$ec"
}
trap '_harvest_exit_code=$?; _harvest_cleanup' ERR EXIT
trap '_harvest_exit_code=1; _harvest_cleanup' TERM INT HUP

# ── Check if branch is already merged ────────────────────────────────────────

if git merge-base --is-ancestor "$WORKTREE_BRANCH" HEAD 2>/dev/null; then
    echo "Branch $WORKTREE_BRANCH is already merged — nothing to do." >&2
    _harvest_exit_code=0
    exit 0
fi

# ── Verify gate artifacts ────────────────────────────────────────────────────

# Check test-gate-status
if [[ ! -f "$WORKTREE_ARTIFACTS_DIR/test-gate-status" ]]; then
    echo "ERROR: test-gate-status not found in $WORKTREE_ARTIFACTS_DIR" >&2
    _harvest_exit_code=2
    exit 2
fi

TEST_GATE_STATUS=$(head -1 "$WORKTREE_ARTIFACTS_DIR/test-gate-status")
if [[ "$TEST_GATE_STATUS" != "passed" ]]; then
    echo "ERROR: test-gate-status is '$TEST_GATE_STATUS' (expected 'passed')" >&2
    _harvest_exit_code=2
    exit 2
fi

# Check review-status
if [[ ! -f "$WORKTREE_ARTIFACTS_DIR/review-status" ]]; then
    echo "ERROR: review-status not found in $WORKTREE_ARTIFACTS_DIR" >&2
    _harvest_exit_code=2
    exit 2
fi

REVIEW_STATUS=$(head -1 "$WORKTREE_ARTIFACTS_DIR/review-status")
if [[ "$REVIEW_STATUS" != "passed" ]]; then
    echo "ERROR: review-status is '$REVIEW_STATUS' (expected 'passed')" >&2
    _harvest_exit_code=2
    exit 2
fi

# ── Merge ────────────────────────────────────────────────────────────────────

set +e
git merge --no-commit "$WORKTREE_BRANCH" >/dev/null 2>&1
set -e

# Check for conflicts
CONFLICTED_FILES=$(git diff --name-only --diff-filter=U 2>/dev/null || true)

if [[ -n "$CONFLICTED_FILES" ]]; then
    # Check if ALL conflicts are in .test-index (union driver handles those)
    NON_TEST_INDEX_CONFLICTS=""
    while IFS= read -r cfile; do
        [[ -z "$cfile" ]] && continue
        if [[ "$cfile" != ".test-index" ]]; then
            NON_TEST_INDEX_CONFLICTS+="$cfile"$'\n'
        fi
    done <<< "$CONFLICTED_FILES"

    if [[ -n "$NON_TEST_INDEX_CONFLICTS" ]]; then
        echo "ERROR: merge conflicts in non-.test-index files:" >&2
        echo "$NON_TEST_INDEX_CONFLICTS" >&2
        git merge --abort 2>/dev/null || true
        _harvest_exit_code=1
        exit 1
    fi
    # Only .test-index conflicts — union driver should have resolved them.
    # Mark as resolved explicitly in case the union driver is misconfigured.
    git add .test-index 2>/dev/null || true
fi

# ── Attest gate status to session artifacts ──────────────────────────────────

# Determine session artifacts directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$SCRIPT_DIR/..}"
[[ ! -f "${_PLUGIN_ROOT}/hooks/lib/deps.sh" ]] && _PLUGIN_ROOT="$SCRIPT_DIR/.."
if [[ -z "$SESSION_ARTIFACTS_DIR" ]]; then
    # Use the current repo's artifacts dir
    if [[ -f "${_PLUGIN_ROOT}/hooks/lib/deps.sh" ]]; then
        source "${_PLUGIN_ROOT}/hooks/lib/deps.sh"
        SESSION_ARTIFACTS_DIR=$(get_artifacts_dir 2>/dev/null || echo "")
    fi
fi

if [[ -n "$SESSION_ARTIFACTS_DIR" ]]; then
    mkdir -p "$SESSION_ARTIFACTS_DIR"

    HOOK_DIR="${_PLUGIN_ROOT}/hooks"

    # Attest test gate status with post-merge diff hash (f518-bba6).
    # --attest validates the worktree's status is "passed", then writes a new
    # test-gate-status with the session's current diff_hash so pre-commit gates match.
    # Export WORKFLOW_PLUGIN_ARTIFACTS_DIR so get_artifacts_dir() in the attest
    # scripts writes to the session artifacts dir (not the default hash-based path).
    WORKFLOW_PLUGIN_ARTIFACTS_DIR="$SESSION_ARTIFACTS_DIR" \
        bash "$HOOK_DIR/record-test-status.sh" --attest "$WORKTREE_ARTIFACTS_DIR"

    # Attest review status with post-merge diff hash.
    WORKFLOW_PLUGIN_ARTIFACTS_DIR="$SESSION_ARTIFACTS_DIR" \
        bash "$HOOK_DIR/record-review.sh" --attest "$WORKTREE_ARTIFACTS_DIR"
fi

# ── Commit ───────────────────────────────────────────────────────────────────

# If merge was a fast-forward (no MERGE_HEAD), git already committed
if [[ -f "$GIT_DIR/MERGE_HEAD" ]]; then
    git commit --no-edit >/dev/null 2>&1
fi

_harvest_exit_code=0
echo "Worktree $WORKTREE_BRANCH merged successfully" >&2
exit 0
