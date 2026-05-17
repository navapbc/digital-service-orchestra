#!/usr/bin/env bash
# pre-push-merged-pr-check.sh
# Blocks pushes to branches whose PR is already MERGED.
#
# Failure mode (bug 680f-53fb): after auto-merge fires, additional commits
# pushed to the merged PR's branch succeed locally and on origin — but the
# commits are stranded because the PR is closed and merged. Discovered only
# when someone notices the diff missing from main.
#
# Resolution: surface the merged-state condition as a push failure with a
# clear remediation message. Operators can override via
# DSO_ALLOW_PUSH_TO_MERGED_PR=1 in the rare case the push is intentional
# (e.g., GC-style branch updates).
#
# Skipped silently when:
#   - `gh` CLI is unavailable
#   - GitHub is unreachable
#   - No PR is associated with the branch
#   - The detached-HEAD case (no branch name)
# Fail-open semantics: when state cannot be determined, the hook does not
# block. The goal is to catch the specific "merged, then pushed again"
# pattern, not to police every push.

set -uo pipefail

# Allow explicit override
if [ "${DSO_ALLOW_PUSH_TO_MERGED_PR:-}" = "1" ]; then
    exit 0
fi

# gh unavailable → silent skip
if ! command -v gh >/dev/null 2>&1; then
    exit 0
fi

BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null)
if [ -z "$BRANCH" ] || [ "$BRANCH" = "HEAD" ]; then
    exit 0  # detached HEAD — nothing to map to a PR
fi

# Query PR state. gh exits non-zero when no PR exists for the branch — that is
# the common case (most pushes are on branches without an open PR yet). Treat
# any non-zero gh exit as "no PR information" and silently pass.
PR_STATE=$(gh pr view "$BRANCH" --json state -q .state 2>/dev/null || true)

case "${PR_STATE:-}" in
    MERGED)
        printf 'ERROR: pre-push: PR for branch %s is MERGED.\n' "$BRANCH" >&2
        printf '       New commits pushed here will be stranded — they will NOT reach main.\n' >&2
        printf '       Cut a new branch from origin/main and open a follow-up PR instead.\n' >&2
        printf '       Override (if you really mean to push to a merged branch):\n' >&2
        printf '           DSO_ALLOW_PUSH_TO_MERGED_PR=1 git push ...\n' >&2
        exit 1
        ;;
    CLOSED)
        printf 'WARN: pre-push: PR for branch %s is CLOSED (not merged).\n' "$BRANCH" >&2
        printf '      Push proceeding; verify this is intended.\n' >&2
        exit 0
        ;;
    *)
        # OPEN, empty (no PR), or any other state → allow push
        exit 0
        ;;
esac
