#!/usr/bin/env bash
# scripts/ci/match-session-branch.sh (under the DSO plugin root)
#
# F4 fix: determine whether a given branch name matches any pattern in
# config/sub-pr-branch-patterns.txt. The prior gate in ci.yml's API
# cross-branch fallback step used a hardcoded `^worktree-` regex, which
# silently no-op'd for legitimate session branches with other shapes
# (session/foo, session_X, bug-batch/Y, etc.) — those PRs fell into the
# trailer-only path and could end up reviewing the full session diff
# (defeating per-story decomposition).
#
# Reading patterns from the source-of-truth file keeps this gate in sync
# automatically when new branch conventions are added.
#
# Usage:
#   match-session-branch.sh <branch-name>
#   match-session-branch.sh --patterns-file <path> <branch-name>
#
# Exit codes:
#   0 — branch matches at least one pattern (caller should proceed)
#   1 — no match (caller should skip)
#   2 — argument or file error

set -uo pipefail

_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$_DIR/../.." 2>/dev/null && pwd)}"
_DEFAULT_PATTERNS_FILE="${_PLUGIN_ROOT}/config/sub-pr-branch-patterns.txt"

PATTERNS_FILE="$_DEFAULT_PATTERNS_FILE"
BRANCH=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --patterns-file)
            PATTERNS_FILE="${2:-}"
            shift 2
            ;;
        --patterns-file=*)
            PATTERNS_FILE="${1#--patterns-file=}"
            shift
            ;;
        -h|--help)
            sed -n '2,18p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *)
            if [[ -z "$BRANCH" ]]; then
                BRANCH="$1"
            else
                echo "Error: unexpected argument: $1" >&2
                exit 2
            fi
            shift
            ;;
    esac
done

if [[ -z "$BRANCH" ]]; then
    echo "Error: branch name required" >&2
    exit 2
fi
if [[ ! -f "$PATTERNS_FILE" ]]; then
    echo "Error: patterns file not found: $PATTERNS_FILE" >&2
    exit 2
fi

# Read active patterns and extract the literal prefix (everything before the
# first wildcard). Patterns use shell glob semantics:
#   session/**     → prefix "session/"
#   worktree-**    → prefix "worktree-"
#   feat/**        → prefix "feat/"
#   feat-**        → prefix "feat-"
# A branch matches if HEAD_REF starts with any extracted prefix. We do not
# attempt full glob matching because every pattern in the source-of-truth
# file is of the form "<literal-prefix><wildcards>", so prefix-match is
# sufficient and avoids re-implementing fnmatch in bash.
_PATTERNS=$(grep -vE '^[[:space:]]*#|^[[:space:]]*$' "$PATTERNS_FILE" 2>/dev/null || true)
if [[ -z "$_PATTERNS" ]]; then
    echo "Error: patterns file contains no active patterns: $PATTERNS_FILE" >&2
    exit 2
fi

while IFS= read -r _pattern; do
    [[ -z "$_pattern" ]] && continue
    # Extract prefix: everything up to (but not including) the first '*' or '?'.
    _prefix="${_pattern%%[*?]*}"
    if [[ -z "$_prefix" ]]; then
        # Pattern starts with a wildcard — would match anything. Treat as match.
        exit 0
    fi
    if [[ "$BRANCH" == "$_prefix"* ]]; then
        exit 0
    fi
done <<< "$_PATTERNS"

exit 1
