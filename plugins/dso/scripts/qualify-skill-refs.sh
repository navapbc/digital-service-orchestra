#!/usr/bin/env bash
set -uo pipefail
# scripts/qualify-skill-refs.sh
# Rewrite unqualified DSO skill references to fully-qualified form.
#
# Transforms /skill-name → /dso:skill-name in all in-scope files:
#   skills/, docs/, hooks/, commands/ (recursively, no symlinks) + CLAUDE.md
#
# NOT in scope: scripts/ (per dso-8qvu epic spec)
#
# Safety rules:
#   - Whole-word match only: /sprint matches, /sprint-extra does not
#   - Skips URL context: https://example.com/sprint is NOT rewritten
#   - Idempotent: /dso:sprint is not rewritten to /dso:dso:sprint
#   - Skips binary files (perl -T text-file check)
#
# Canonical skill list is read from check-skill-refs.sh (single source of truth).
#
# Usage:
#   scripts/qualify-skill-refs.sh
#
# Exit codes:
#   0 — Always (this is a fixer, not a checker)

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# ── Read canonical skill list from check-skill-refs.sh ───────────────────────
# check-skill-refs.sh is the single source of truth for DSO_SKILLS.
# We extract the value directly rather than sourcing (sourcing triggers the scan
# and exits with a non-zero code when violations are present).
DSO_SKILLS=$(grep '^DSO_SKILLS=' "$SCRIPT_DIR/check-skill-refs.sh" | head -1 | sed 's/^DSO_SKILLS="//' | sed 's/"$//')

if [[ -z "$DSO_SKILLS" ]]; then
    echo "qualify-skill-refs: ERROR: Could not read DSO_SKILLS from check-skill-refs.sh" >&2
    exit 1
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

# ── Build in-scope file set ───────────────────────────────────────────────────
_scan_targets=()
for _dir in skills docs hooks commands; do
    if [[ -d "$REPO_ROOT/$_dir" ]]; then
        _scan_targets+=("$REPO_ROOT/$_dir")
    fi
done
if [[ -f "$REPO_ROOT/CLAUDE.md" ]]; then
    _scan_targets+=("$REPO_ROOT/CLAUDE.md")
fi

if [[ ${#_scan_targets[@]} -eq 0 ]]; then
    echo "qualify-skill-refs: no files to process" >&2
    exit 0
fi

# ── Perl substitution ─────────────────────────────────────────────────────────
# URL-aware alternation approach (dso-gir2):
#   The regex matches EITHER a full URL (https?://\S+) OR an unqualified skill ref.
#   When a URL matches, it is kept unchanged ($1 is defined → return $1).
#   When a skill ref matches, it is qualified ($2 is defined → return /dso:$2).
#
#   This correctly handles multi-segment URL paths like:
#     https://example.com/foo--/sprint
#   where the character before "/sprint" is "-" (not in the simple lookbehind set).
#   The URL alternation arm matches the entire URL first, preventing the skill-ref
#   arm from ever seeing the path segments inside the URL.
#
# Skill ref arm explanation:
#   (?<![a-zA-Z0-9_/])     — negative lookbehind: not preceded by word char or slash
#                             (prevents matching inside filesystem paths like skills/debug-everything/)
#   (?<!dso:)               — negative lookbehind: not already qualified as /dso:skill
#   /                       — literal slash
#   ($alternation)          — one of the canonical skill names (captured in $2)
#   (?![a-zA-Z0-9_:-])      — not followed by word chars, hyphen, or colon
#                             (ensures whole-word match; /sprint-extra won't match)
#
# Together these handle:
#   https://foo.com/sprint          → unchanged (URL arm matches, $1 returned)
#   https://example.com/foo--/sprint → unchanged (URL arm matches, $1 returned)
#   /dso:sprint                     → unchanged (preceded by dso:)
#   /sprint                         → rewritten to /dso:sprint
#   skills/debug-everything/        → unchanged (preceded by path char)
#   commit/review                   → unchanged (preceded by word char)
#   prompts/tickets-health.md       → unchanged (preceded by path char)

_perl_script='s{(https?://\S+)|(?<![a-zA-Z0-9_/])(?<!dso:)/('"${_skill_alternation}"')(?![a-zA-Z0-9_:-])}{ defined $1 ? $1 : "/dso:$2" }ge'

_qualify_file() {
    local _file="$1"
    # Skip binary files using the 'file' command (or perl's -B heuristic via a pre-check).
    # Use perl -e with -B (binary) file test to detect binaries before in-place edit.
    if perl -e 'exit(-B $ARGV[0] ? 0 : 1)' "$_file" 2>/dev/null; then
        return  # binary file — skip
    fi
    # -i.bak: in-place rewrite with .bak backup (macOS requires backup extension for -i)
    # Remove the backup after successful rewrite.
    if perl -i.bak -pe "$_perl_script" "$_file" 2>/dev/null; then
        rm -f "${_file}.bak"
    fi
}

_qualify_path() {
    local _path="$1"
    if [[ -f "$_path" ]]; then
        _qualify_file "$_path"
    elif [[ -d "$_path" ]]; then
        # -P: physical traversal, no symlinks
        while IFS= read -r -d '' _f; do
            _qualify_file "$_f"
        done < <(find -P "$_path" -type f -print0 2>/dev/null)
    fi
}

echo "qualify-skill-refs: processing in-scope files..."
for _target in "${_scan_targets[@]}"; do
    _qualify_path "$_target"
done
echo "qualify-skill-refs: done."

exit 0
