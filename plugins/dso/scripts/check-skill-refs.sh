#!/usr/bin/env bash
set -uo pipefail
_PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/..}"
# scripts/check-skill-refs.sh
# Detect unqualified DSO skill references in workflow files.
#
# An 'unqualified reference' is /<skill-name> that is:
#   - NOT preceded by dso: (already qualified)
#   - NOT inside a URL (http:// or https:// context)
#
# Usage:
#   scripts/check-skill-refs.sh [file|dir ...]
#
# When no arguments are given, scans the default in-scope file set:
#   skills/, docs/, hooks/, commands/ (recursively, no symlinks) + CLAUDE.md
#
# Exit codes:
#   0 — No violations found
#   1 — One or more violations found
#
# Shared canonical skill list (sourceable by qualify-skill-refs.sh via dso-0isl):
#   DSO_SKILLS — space-separated list of canonical skill names

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# ── Canonical skill list ───────────────────────────────────────────────────────
# Single source of truth. qualify-skill-refs.sh (dso-0isl) sources this file
# and reads DSO_SKILLS to avoid drift.
DSO_SKILLS="sprint commit review end implementation-plan preplanning debug-everything brainstorm plan-review interface-contracts resolve-conflicts retro roadmap oscillation-check design-review ui-discover validate-work tickets-health playwright-debug dryrun quick-ref fix-cascade-recovery onboarding architect-foundation fix-bug verification-before-completion"

# ── Build alternation pattern ─────────────────────────────────────────────────
_skill_alternation=""
for _skill in $DSO_SKILLS; do
    if [[ -z "$_skill_alternation" ]]; then
        _skill_alternation="$_skill"
    else
        _skill_alternation="${_skill_alternation}|${_skill}"
    fi
done

# Perl regex pattern (applied after URL stripping):
#   (?<![a-zA-Z0-9_\/])(?<!dso:)/(<skill>)(?![a-zA-Z0-9_:-])
# - (?<![a-zA-Z0-9_\/])  — not preceded by word char or slash (excludes filesystem paths)
#                           Note: \/ escapes / so it doesn't terminate the // match operator
# - (?<!dso:)             — not preceded by dso: (excludes /dso:sprint)
# - (?![a-zA-Z0-9_:-])   — not followed by word chars/hyphen/colon (excludes /sprint-extra)
# URLs are stripped via s|https?://\S+||g before pattern matching.
_PERL_PATTERN="(?<![a-zA-Z0-9_\\/])(?<!dso:)\\/($_skill_alternation)(?![a-zA-Z0-9_:-])"

# ── Determine file set ────────────────────────────────────────────────────────
_scan_targets=()
if [[ $# -gt 0 ]]; then
    # Explicit targets provided (used for test isolation)
    _scan_targets=("$@")
else
    # Default in-scope set: ${CLAUDE_PLUGIN_ROOT}/{skills,docs,hooks,commands} (no symlinks) + CLAUDE.md
    _PLUGIN_DIR="${_PLUGIN_ROOT}"
    for _dir in skills docs hooks commands; do
        if [[ -d "$_PLUGIN_DIR/$_dir" ]]; then
            _scan_targets+=("$_PLUGIN_DIR/$_dir")
        fi
    done
    if [[ -f "$REPO_ROOT/CLAUDE.md" ]]; then
        _scan_targets+=("$REPO_ROOT/CLAUDE.md")
    fi
fi

if [[ ${#_scan_targets[@]} -eq 0 ]]; then
    echo "check-skill-refs: no files to scan" >&2
    exit 0
fi

# ── Scan ─────────────────────────────────────────────────────────────────────
_violations=0

_scan_file() {
    local _file="$1"
    # Use perl to:
    #   1. Strip URLs (http:// and https://) so URL paths are not flagged
    #   2. Match unqualified /skill-name references
    # -n: loop over lines, -e: inline script
    local _matches
    _matches=$(perl -ne "
        s|https?://\S+||g;
        s/\`[^\`]*\`//g;
        if (/($_PERL_PATTERN)/) {
            print \"\$.\t\$_\";
        }
    " "$_file" 2>/dev/null || true)

    if [[ -n "$_matches" ]]; then
        while IFS=$'\t' read -r _linenum _content; do
            echo "UNQUALIFIED: $_file:$_linenum: $_content"
            (( _violations++ )) || true
        done <<< "$_matches"
    fi
}

_scan_path() {
    local _path="$1"
    if [[ -f "$_path" ]]; then
        _scan_file "$_path"
    elif [[ -d "$_path" ]]; then
        # Recurse, no symlinks (-P = physical, don't follow symlinks)
        while IFS= read -r -d '' _f; do
            _scan_file "$_f"
        done < <(find -P "$_path" -type f -print0 2>/dev/null)
    fi
}

for _target in "${_scan_targets[@]}"; do
    _scan_path "$_target"
done

# ── Summary ───────────────────────────────────────────────────────────────────
if [[ $_violations -gt 0 ]]; then
    echo ""
    echo "check-skill-refs: $_violations unqualified skill reference(s) found." >&2
    echo "  Qualify them as /dso:<skill-name> (e.g., /sprint → /dso:sprint)" >&2
    exit 1
fi

exit 0
