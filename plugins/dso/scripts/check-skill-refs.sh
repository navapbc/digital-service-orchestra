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
# bug 34b2: host-portable REPO_ROOT resolution. Prior `$SCRIPT_DIR/..` resolved
# to the plugin cache root when invoked on a host project via the shim, so the
# script silently inspected the plugin's CLAUDE.md instead of the host's —
# giving operators a false PASS even when their CLAUDE.md had unqualified
# `/skill` references. Established pattern from check-rule-anchors.sh:48 and
# audit-skill-resolution.sh:25.
REPO_ROOT="${PROJECT_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null)}"
if [[ -z "$REPO_ROOT" ]]; then
  echo "ERROR: cannot resolve REPO_ROOT (not in a git repo and PROJECT_ROOT unset)" >&2
  exit 1
fi

# ── Canonical skill list ───────────────────────────────────────────────────────
# Single source of truth, auto-discovered from the filesystem by file-presence:
#   - skills/<name>/SKILL.md  (excluding skills/shared and skills/ui-designer —
#     `shared` is a prompt-library directory, `ui-designer` is an agent dispatch
#     directory, neither is a user-invocable skill)
#   - commands/<name>.md      (Claude Code slash commands; resolved via /dso:<name>
#     before the skills/ namespace)
#
# qualify-skill-refs.sh (dso-0isl) consumes DSO_SKILLS by sourcing this file with
# DSO_SKILL_REFS_NO_SCAN=1 to skip the scan logic below.
#
# Fail-loud: an empty allowlist would silently pass every typo, strictly worse
# than the pre-2026-05-19 stale-but-non-empty hardcoded list. Refuse to run if
# either source directory yields zero entries.
_skills_from_fs=$(find "${_PLUGIN_ROOT}/skills" -maxdepth 2 -name SKILL.md \
    -not -path '*/shared/*' -not -path '*/ui-designer/*' 2>/dev/null \
    | while IFS= read -r _f; do dirname "$_f" | xargs basename; done \
    | sort -u | tr '\n' ' ')
_commands_from_fs=$(find "${_PLUGIN_ROOT}/commands" -maxdepth 1 -name '*.md' 2>/dev/null \
    | while IFS= read -r _f; do basename "$_f" .md; done \
    | sort -u | tr '\n' ' ')

if [[ -z "${_skills_from_fs// /}" ]]; then
    echo "check-skill-refs: FATAL: no skills found under ${_PLUGIN_ROOT}/skills/ — refusing to run with empty allowlist" >&2
    exit 2
fi
if [[ -z "${_commands_from_fs// /}" ]]; then
    echo "check-skill-refs: FATAL: no commands found under ${_PLUGIN_ROOT}/commands/ — refusing to run with empty allowlist" >&2
    exit 2
fi

# DSO_SKILLS line kept in literal form on a single line so qualify-skill-refs.sh
# (and any other line-grep consumer) sees the expected `^DSO_SKILLS="..."` shape
# after command substitution evaluates. Final sort -u dedupes across the
# skills/commands boundary (e.g., debug-everything has both a skill and a command).
DSO_SKILLS="$(printf '%s %s' "${_skills_from_fs% }" "${_commands_from_fs% }" | tr ' ' '\n' | sort -u | tr '\n' ' ' | sed 's/^ //; s/ $//')"

# ── Sourceable early-return ────────────────────────────────────────────────────
# When sourced with DSO_SKILL_REFS_NO_SCAN=1, the caller obtains DSO_SKILLS in
# its shell without triggering the scan or the exit below. The `2>/dev/null`
# swallows the no-op error if accidentally set during a direct invocation.
if [[ "${DSO_SKILL_REFS_NO_SCAN:-}" == "1" ]]; then
    return 0 2>/dev/null
fi

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
