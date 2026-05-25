#!/usr/bin/env bash
# verify-story-merge-trailer.sh — Phase F Step 18 positive-invariant gate.
#
# Asserts that <base>..HEAD contains at least one commit whose message body
# carries the trailer `DSO-Story-Merge: <story-id>`. Exit 0 if found,
# exit 1 otherwise (with recovery guidance on stderr).
#
# Rationale (bug db71-e078-ec99-4fbf):
#   merge-story-branch.sh can silently no-op when the story branch tip
#   equals the session branch tip (default post-harvest worktree-isolation
#   state). Without this verification, Phase F can proceed to
#   `ticket transition closed` even though no DSO-Story-Merge trailer
#   ever landed — corrupting the provenance pipeline that downstream
#   verifiers, CI integration-scope detection, and re-review attribution
#   all depend on.
#
# Positive-invariant design: this script does NOT ban or detect any
# particular git verb (e.g. `git merge`). It checks for the *presence* of
# the trailer regardless of how it got there (real merge commit,
# fast-forward + --allow-empty trailer commit, ci-pr GitHub merge, etc.).
# This avoids false positives against legitimate `git merge` calls in
# scripts like merge-to-main-pr.sh.
#
# Usage:
#   verify-story-merge-trailer.sh <story-id> [--base=<ref>]
#   verify-story-merge-trailer.sh --help
#
# --base defaults to the remote default branch (origin/HEAD → main fallback).

set -uo pipefail

_print_usage() {
    cat <<'EOF'
Usage: verify-story-merge-trailer.sh <story-id> [--base=<ref>]

Asserts that <base>..HEAD contains a commit whose body carries the
trailer 'DSO-Story-Merge: <story-id>'.

Options:
  --base=<ref>   Base ref to scan from (default: origin/HEAD → main).
  --help         Print this message and exit 0.

Exit codes:
  0   trailer found
  1   trailer absent (recovery guidance printed to stderr)
  2   bad usage
EOF
}

if [[ "${1:-}" == "--help" ]]; then
    _print_usage
    exit 0
fi

if [[ $# -lt 1 ]]; then
    echo "ERROR: missing <story-id>" >&2
    _print_usage >&2
    exit 2
fi

_STORY_ID="$1"
shift

_BASE=""
for arg in "$@"; do
    case "$arg" in
        --base=*) _BASE="${arg#--base=}" ;;
        *) echo "ERROR: unknown arg: $arg" >&2; _print_usage >&2; exit 2 ;;
    esac
done

# Resolve default base: try origin/HEAD symbolic ref, fall back to 'main'.
if [[ -z "$_BASE" ]]; then
    if _ref=$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null); then
        _BASE="${_ref#refs/remotes/origin/}"
        _BASE="origin/$_BASE"
    else
        _BASE="main"
    fi
fi

# Pattern: anchored at line start of body. --extended-regexp + --grep is
# applied across the full commit message (subject + body).
_PATTERN="^DSO-Story-Merge: ${_STORY_ID}\$"

# Verify the base ref resolves before invoking git log (else the user gets
# a confusing "unknown revision" error instead of an actionable message).
if ! git rev-parse --verify "$_BASE" >/dev/null 2>&1; then
    echo "ERROR: base ref '$_BASE' does not resolve" >&2
    echo "       (try passing --base=<ref> explicitly)" >&2
    exit 1
fi

_HITS=$(git log "${_BASE}..HEAD" \
    --grep="$_PATTERN" --extended-regexp --format=%H 2>/dev/null | head -1)

if [[ -n "$_HITS" ]]; then
    exit 0
fi

# No trailer found — emit recovery guidance.
{
    echo "ERROR: DSO-Story-Merge trailer for story '$_STORY_ID' not found in ${_BASE}..HEAD"
    echo ""
    echo "  This commonly happens when:"
    echo "  - merge-story-branch.sh ran but the story tip == session tip (no-diff merge,"
    echo "    silent 'Already up to date.' — bug db71-e078-ec99-4fbf)"
    echo "  - ci-pr mode opened a story PR but the PR has not yet auto-merged"
    echo "  - the story was closed via a bypass path that skipped the merge step"
    echo ""
    # Derive plugin-relative path for recovery guidance (no literal plugin path).
    _PLUGIN_GIT_PATH="${CLAUDE_PLUGIN_ROOT:-}"
    if [[ -n "$_PLUGIN_GIT_PATH" ]]; then
        _REPO_ROOT_GUESS=$(git rev-parse --show-toplevel 2>/dev/null || echo "")
        _PLUGIN_GIT_PATH="${_PLUGIN_GIT_PATH#"$_REPO_ROOT_GUESS"/}"
    else
        # shellcheck disable=SC2016  # literal placeholder shown to operator
        _PLUGIN_GIT_PATH='${CLAUDE_PLUGIN_ROOT}'
    fi
    echo "  Recovery:"
    echo "    # local mode — re-run merge (will emit empty trailer commit if no-diff):"
    echo "    bash ${_PLUGIN_GIT_PATH}/scripts/merge-story-branch.sh story/<epic-id>/${_STORY_ID} ${_STORY_ID}"
    echo ""
    echo "    # ci-pr mode — re-dispatch story PR:"
    echo "    BRANCH=story/<epic-id>/${_STORY_ID} STORY_PR_BASE=<session-branch> \\"
    echo "      bash ${_PLUGIN_GIT_PATH}/scripts/merge-to-main.sh"
} >&2

exit 1
