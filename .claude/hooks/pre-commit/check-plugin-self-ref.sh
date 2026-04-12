#!/usr/bin/env bash
# .claude/hooks/pre-commit/check-plugin-self-ref.sh
# Pre-commit hook: block ANY plugins/dso self-reference in files under plugins/dso/.
#
# Zero bypass — every occurrence is blocked, no exceptions.
# Any occurrence of "plugins/dso" in any staged file under plugins/dso/ blocks the commit.
#
# Usage:
#   check-plugin-self-ref.sh [REPO_ROOT]   (default: git rev-parse --show-toplevel)
#
# Exit codes:
#   0 — No violations
#   1 — One or more self-references found

set -uo pipefail

# ── Resolve repo root ────────────────────────────────────────────────────────
if [[ $# -gt 0 ]]; then
    REPO_ROOT="$1"
else
    REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
fi

# ── Collect staged files under plugins/dso/ ──────────────────────────────────
_staged=()
while IFS= read -r _f; do
    [[ -n "$_f" ]] && _staged+=("$_f")
done < <(git diff --cached --name-only --diff-filter=ACM 2>/dev/null | grep '^plugins/dso/' || true)

if [[ ${#_staged[@]} -eq 0 ]]; then
    exit 0
fi

# ── Check each staged file for plugins/dso references ────────────────────────
_violations=0
_violation_details=()

for _file in "${_staged[@]}"; do
    # Read the staged content (not the working copy)
    _line_num=0
    while IFS= read -r _line; do
        (( _line_num++ )) || true
        case "$_line" in
            *plugins/dso*)
                (( _violations++ )) || true
                _violation_details+=("  ${_file}:${_line_num}: ${_line}")
                ;;
        esac
    done < <(git show ":${_file}" 2>/dev/null || cat "$REPO_ROOT/$_file" 2>/dev/null || true)
done

if [[ $_violations -gt 0 ]]; then
    echo "check-plugin-self-ref: BLOCKED — found plugins/dso self-reference(s):" >&2
    echo "" >&2
    for _detail in "${_violation_details[@]}"; do
        echo "$_detail" >&2
    done
    echo "" >&2
    echo "Fix: replace hardcoded plugins/dso paths with _PLUGIN_ROOT (scripts)" >&2
    echo "     or \${CLAUDE_PLUGIN_ROOT}/ (markdown). Remove or rewrite the reference." >&2
    echo "" >&2
    echo "check-plugin-self-ref: $_violations violation(s) found. Commit blocked." >&2
    exit 1
fi

exit 0
