#!/usr/bin/env bash
# .claude/hooks/pre-commit/check-plugin-boundary.sh
# Pre-commit hook: enforce plugin directory boundary using a positive-enumeration allowlist.
#
# Reads ALLOWLIST_FILE (env override) or .claude/hooks/pre-commit/plugin-boundary-allowlist.conf
# relative to the repo root. Any file staged under plugins/dso/ that does NOT match any
# allowlist pattern is blocked (exits non-zero).
#
# Fail-open: if the allowlist file is missing or unreadable, the hook exits 0 with a warning.
#
# Usage:
#   check-plugin-boundary.sh [REPO_ROOT]   (default: git rev-parse --show-toplevel)
#
# Environment:
#   ALLOWLIST_FILE   Override the allowlist path (for testing)
#
# Exit codes:
#   0 — No violations (or allowlist missing — fail-open)
#   1 — One or more boundary violations found

set -uo pipefail

# ── Resolve repo root ────────────────────────────────────────────────────────
if [[ $# -gt 0 ]]; then
    REPO_ROOT="$1"
else
    REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
fi

# ── Resolve allowlist path ───────────────────────────────────────────────────
if [[ -n "${ALLOWLIST_FILE:-}" ]]; then
    _ALLOWLIST="$ALLOWLIST_FILE"
else
    _ALLOWLIST="$REPO_ROOT/.claude/hooks/pre-commit/plugin-boundary-allowlist.conf"
fi

# ── Fail-open: missing or unreadable allowlist ───────────────────────────────
if [[ ! -f "$_ALLOWLIST" || ! -r "$_ALLOWLIST" ]]; then
    echo "check-plugin-boundary: WARNING: allowlist not found at $_ALLOWLIST — skipping boundary check (fail-open)" >&2
    exit 0
fi

# ── Collect staged files under plugins/dso/ ──────────────────────────────────
_staged=()
while IFS= read -r _f; do
    [[ -n "$_f" ]] && _staged+=("$_f")
done < <(git -C "$REPO_ROOT" diff --cached --name-only --diff-filter=ACM 2>/dev/null | grep '^plugins/dso/' || true)

if [[ ${#_staged[@]} -eq 0 ]]; then
    exit 0
fi

# ── Load allowlist patterns (strip comments and blank lines) ─────────────────
_patterns=()
while IFS= read -r _line; do
    # Strip inline comments
    _line="${_line%%#*}"
    # Trim leading whitespace
    _line="${_line#"${_line%%[![:space:]]*}"}"
    # Trim trailing whitespace
    _line="${_line%"${_line##*[![:space:]]}"}"
    [[ -z "$_line" ]] && continue
    _patterns+=("$_line")
done < "$_ALLOWLIST"

# ── Pattern matching helper ───────────────────────────────────────────────────
# Returns 0 if _file matches _pattern, 1 otherwise.
# Uses Python fnmatch semantics: * matches within a single path segment only.
# Pattern '/**' suffix: matches any file under the given directory prefix.
_path_matches() {
    local _file="$1"
    local _pat="$2"

    # Case 1: pattern ends with /** — prefix match on directory
    if [[ "$_pat" == *"/**" ]]; then
        local _prefix="${_pat%/**}"
        [[ "$_file" == "$_prefix/"* ]] && return 0
        return 1
    fi

    # Case 2: exact match (no wildcard)
    if [[ "$_pat" != *"*"* && "$_pat" != *"?"* ]]; then
        [[ "$_file" == "$_pat" ]] && return 0
        return 1
    fi

    # Case 3: pattern with * but not ** — use Python fnmatch to avoid crossing /
    # fnmatch.fnmatch treats * as matching anything except / when pathsep is used
    # We use Python since bash case glob crosses / boundaries
    python3 -c "
import fnmatch, sys
file = sys.argv[1]
pat = sys.argv[2]
# Use fnmatch which treats * as crossing path separators by default
# To enforce per-segment matching, we split on '/' and match each segment
file_parts = file.split('/')
pat_parts = pat.split('/')
if len(file_parts) != len(pat_parts):
    sys.exit(1)
for fp, pp in zip(file_parts, pat_parts):
    if not fnmatch.fnmatch(fp, pp):
        sys.exit(1)
sys.exit(0)
" "$_file" "$_pat" 2>/dev/null && return 0
    return 1
}

# ── Check each staged file against allowlist ─────────────────────────────────
_violations=0
for _file in "${_staged[@]}"; do
    _allowed=0
    for _pat in "${_patterns[@]}"; do
        if _path_matches "$_file" "$_pat"; then
            _allowed=1
            break
        fi
    done
    if [[ $_allowed -eq 0 ]]; then
        echo "check-plugin-boundary: BLOCKED: '$_file'" >&2
        echo "  File '$_file' is not in the plugin boundary allowlist." >&2
        echo "  To permit this path, add a pattern to: $_ALLOWLIST" >&2
        (( _violations++ )) || true
    fi
done

if [[ $_violations -gt 0 ]]; then
    echo "" >&2
    echo "check-plugin-boundary: $_violations violation(s) found. Commit blocked." >&2
    echo "  Add permitted paths to: $_ALLOWLIST" >&2
    exit 1
fi

exit 0
