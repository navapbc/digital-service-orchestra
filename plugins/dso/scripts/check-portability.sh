#!/usr/bin/env bash
# check-portability.sh
# Detect hardcoded home-directory paths that break portability.
#
# Flags lines containing:
#   /Users/<username>/   (macOS home directories)
#   /home/<username>/    (Linux home directories)
#
# Inline suppression: append  # portability-ok  to a line to exempt it.
#
# Usage:
#   check-portability.sh [file ...]
#
# When no file arguments are given, discovers staged files via:
#   git diff --cached --name-only --diff-filter=ACM
#
# Exit codes:
#   0 — No violations found
#   1 — One or more violations found
#
# Violations are printed to stderr in  file:line  format.

set -uo pipefail

# ── Regex patterns (marked portability-ok so this file does not flag itself) ──
_MACOS_PAT='/Users/[a-zA-Z][a-zA-Z0-9._-]*/' # portability-ok
_LINUX_PAT='/home/[a-zA-Z][a-zA-Z0-9._-]*/'  # portability-ok

# ── Determine file list ────────────────────────────────────────────────────────
_files=()
if [[ $# -gt 0 ]]; then
    _files=("$@")
else
    # No args — discover staged files
    while IFS= read -r _f; do
        [[ -n "$_f" ]] && _files+=("$_f")
    done < <(git diff --cached --name-only --diff-filter=ACM 2>/dev/null || true)
fi

if [[ ${#_files[@]} -eq 0 ]]; then
    exit 0
fi

# ── Scan ──────────────────────────────────────────────────────────────────────
_violations=0

_scan_file() {
    local _file="$1"
    [[ -f "$_file" ]] || return 0

    local _linenum=0
    # grep -I skips binary files; -n gives line numbers; -E for extended regex
    # We combine both patterns in one grep pass.
    # Lines containing "# portability-ok" are excluded after matching.
    local _matches
    _matches=$(grep -InE "${_MACOS_PAT}|${_LINUX_PAT}" "$_file" 2>/dev/null || true) # portability-ok
    while IFS= read -r _match; do
        [[ -z "$_match" ]] && continue
        # Extract the line content (after the linenum: prefix)
        local _content="${_match#*:}"
        # Skip lines suppressed with # portability-ok
        if [[ "$_content" == *"# portability-ok"* ]]; then
            continue
        fi
        echo "$_file:${_match}" >&2
        (( _violations++ )) || true
    done <<< "$_matches"
}

for _f in "${_files[@]}"; do
    _scan_file "$_f"
done

# ── Result ────────────────────────────────────────────────────────────────────
if [[ $_violations -gt 0 ]]; then
    exit 1
fi

exit 0
