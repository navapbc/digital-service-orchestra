#!/usr/bin/env bash
set -uo pipefail
# scripts/resolve-default-branch.sh
# Resolve the host repository's default integration branch.
#
# DSO's merge/PR scripts were originally written assuming the default branch
# is "main". For host projects on master/develop/trunk/release-* branches,
# the hard-coded literal caused false diffs and wrong PR bases. This script
# resolves the actual default branch via a precedence chain that prefers
# local sources (no network, no auth) over remote calls.
#
# Precedence:
#   1. Config: dso.default_branch (if explicitly set in dso-config.conf)
#   2. git symbolic-ref --short refs/remotes/origin/HEAD (local, no network)
#   3. gh repo view --json defaultBranchRef (remote; only if gh authenticated)
#   4. Fallback "main" with a stderr warning
#
# Cache behavior:
#   The resolved value is written to .git/dso-default-branch by the caller
#   (typically merge-to-main.sh) at the start of each merge run. This script
#   does NOT consult or write the cache itself — it computes a fresh value.
#   Cache invalidation is the caller's responsibility (delete and re-run);
#   the file lives under .git/ which is per-clone and not committed.
#
# Usage:
#   resolve-default-branch.sh [--config <path>] [--no-warn]
#
# Environment:
#   DSO_CONFIG_FILE   Override config-file path (precedence over --config arg)
#   DSO_DEFAULT_BRANCH_TEST_GH_OUTPUT  Test-injection: override gh repo view output
#   DSO_DEFAULT_BRANCH_TEST_SYMBOLIC_REF  Test-injection: override symbolic-ref output
#
# Output:
#   stdout: the resolved branch name (one line)
#   stderr: warnings (suppress with --no-warn)
#
# Exit codes:
#   0  Always (the fallback to "main" ensures a value)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Argument parsing ─────────────────────────────────────────────────────────
_config_arg=""
_no_warn=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --config) _config_arg="$2"; shift 2 ;;
        --config=*) _config_arg="${1#--config=}"; shift ;;
        --no-warn) _no_warn=1; shift ;;
        --help|-h)
            sed -n '4,/^$/p' "$0" | sed 's/^# \?//'
            exit 0
            ;;
        *)
            echo "ERROR: Unknown argument: $1" >&2
            exit 1
            ;;
    esac
done

_warn() {
    [[ "$_no_warn" -eq 1 ]] && return 0
    echo "resolve-default-branch: $*" >&2
}

# ── Step 1: config (dso.default_branch) ──────────────────────────────────────
_resolve_config_file() {
    if [[ -n "${DSO_CONFIG_FILE:-}" ]]; then
        echo "$DSO_CONFIG_FILE"
        return
    fi
    if [[ -n "$_config_arg" ]]; then
        echo "$_config_arg"
        return
    fi
    # Default: walk up from script dir looking for .claude/dso-config.conf
    local dir="$SCRIPT_DIR"
    while [[ "$dir" != "/" ]]; do
        if [[ -f "$dir/.claude/dso-config.conf" ]]; then
            echo "$dir/.claude/dso-config.conf"
            return
        fi
        dir="$(dirname "$dir")"
    done
    # Try git toplevel as a final fallback
    local _top
    _top=$(git rev-parse --show-toplevel 2>/dev/null || true)
    if [[ -n "$_top" ]] && [[ -f "$_top/.claude/dso-config.conf" ]]; then
        echo "$_top/.claude/dso-config.conf"
        return
    fi
    echo ""
}

_CONFIG_FILE="$(_resolve_config_file)"

if [[ -n "$_CONFIG_FILE" ]] && [[ -f "$_CONFIG_FILE" ]]; then
    _value=$(bash "$SCRIPT_DIR/read-config.sh" dso.default_branch "$_CONFIG_FILE" 2>/dev/null || true)
    if [[ -n "$_value" ]]; then
        echo "$_value"
        exit 0
    fi
fi

# ── Step 2: git symbolic-ref (local, no network) ─────────────────────────────
# refs/remotes/origin/HEAD typically points to refs/remotes/origin/<default>
# The --short form strips "refs/remotes/" → "origin/<default>"; strip "origin/".
if [[ -n "${DSO_DEFAULT_BRANCH_TEST_SYMBOLIC_REF:-}" ]]; then
    _symref="$DSO_DEFAULT_BRANCH_TEST_SYMBOLIC_REF"
else
    _symref=$(git symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null || true)
fi

if [[ -n "$_symref" ]]; then
    # Strip leading "origin/" prefix
    _branch="${_symref#origin/}"
    if [[ -n "$_branch" ]]; then
        echo "$_branch"
        exit 0
    fi
fi

# ── Step 3: gh repo view (remote; only if gh is authenticated) ───────────────
if [[ -n "${DSO_DEFAULT_BRANCH_TEST_GH_OUTPUT:-}" ]]; then
    _gh_output="$DSO_DEFAULT_BRANCH_TEST_GH_OUTPUT"
else
    if command -v gh >/dev/null 2>&1; then
        _gh_output=$(gh repo view --json defaultBranchRef --jq '.defaultBranchRef.name' 2>/dev/null || true)
    else
        _gh_output=""
    fi
fi

if [[ -n "$_gh_output" ]]; then
    echo "$_gh_output"
    exit 0
fi

# ── Step 4: fallback "main" with warning ─────────────────────────────────────
_warn "Could not resolve default branch from config, symbolic-ref, or gh."
_warn "Falling back to 'main'. If your repo uses a different default,"
_warn "set dso.default_branch in .claude/dso-config.conf."
echo "main"
exit 0
