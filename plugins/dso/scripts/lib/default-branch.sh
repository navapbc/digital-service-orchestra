#!/usr/bin/env bash
# scripts/lib/default-branch.sh (under the DSO plugin root)
#
# Shared helper: resolve the host's default branch using a four-tier
# fallback chain. Sourced by provision-ruleset.sh (and any future script that
# needs to scope rulesets or workflow triggers against the host's
# default-branch name).
#
# Function: _dso_resolve_default_branch [<repo>]
#
# Resolution order (first non-empty value wins):
#   1. DSO_DEFAULT_BRANCH env override (explicit operator intent)
#   2. gh repo view <repo> --json defaultBranchRef (authoritative; requires
#      gh + an owner/repo argument)
#   3. git symbolic-ref --short refs/remotes/origin/HEAD (no GitHub auth
#      required; works from any clone with origin/HEAD set)
#   4. Hardcoded "main" literal (last-resort default)
#
# Output: prints the resolved branch name (newline-terminated) to stdout.
# Exit code: 0 (never fails — the literal-main fallback always succeeds).
#
# Usage:
#   source "${CLAUDE_PLUGIN_ROOT:-/path/to/plugin}/scripts/lib/default-branch.sh"
#   DEFAULT_BRANCH=$(_dso_resolve_default_branch "$REPO")
#
# A note for callers: when REPO is empty (e.g., dry-run without --repo),
# the gh-repo-view tier silently skips; resolution falls through to git
# symbolic-ref and the literal fallback. The function still succeeds —
# callers do not need to special-case "REPO empty".

# Avoid double-define if the script is sourced multiple times.
if [[ "${_DSO_RESOLVE_DEFAULT_BRANCH_LOADED:-}" == "1" ]]; then
    return 0
fi
_DSO_RESOLVE_DEFAULT_BRANCH_LOADED=1

_dso_resolve_default_branch() {
    local _repo="${1:-}"
    local _branch=""

    # Tier 1: env override.
    if [[ -n "${DSO_DEFAULT_BRANCH:-}" ]]; then
        printf '%s\n' "$DSO_DEFAULT_BRANCH"
        return 0
    fi

    # Tier 2: gh repo view (requires repo argument).
    if [[ -n "$_repo" ]] && command -v gh >/dev/null 2>&1; then
        _branch=$(gh repo view "$_repo" --json defaultBranchRef -q '.defaultBranchRef.name' 2>/dev/null || true)
        if [[ -n "$_branch" ]]; then
            printf '%s\n' "$_branch"
            return 0
        fi
    fi

    # Tier 3: git symbolic-ref refs/remotes/origin/HEAD.
    _branch=$(git symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null \
        | sed 's|^origin/||' || true)
    if [[ -n "$_branch" ]]; then
        printf '%s\n' "$_branch"
        return 0
    fi

    # Tier 4: hardcoded fallback.
    printf '%s\n' "main"
    return 0
}
