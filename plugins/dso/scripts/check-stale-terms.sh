#!/usr/bin/env bash
set -uo pipefail
# scripts/check-stale-terms.sh
# Detect stale "skeleton/placeholder/walking-skeleton" vocabulary in
# production source files.
#
# Production scripts that self-describe as "skeleton implementation",
# "walking skeleton", "lands in Task N", or "placeholder implementation"
# create an integrity hazard: agents read source comments as execution
# guidance, and a comment claiming the code is incomplete will lead
# future maintainers (human or agent) to underweight the code's
# production role.
#
# Vocabulary detected (phrase-based to avoid single-word false positives
# like "placeholder" used as a noun for a runtime sentinel value):
#   - "skeleton implementation"
#   - "walking skeleton" / "walking-skeleton" (case-insensitive)
#   - "placeholder implementation"
#   - "lands in Task" (proper-noun reference to future work)
#   - "TODO before production"
#   - "this skeleton" / "this is a skeleton" (self-reference)
#   - "(skeleton)" as a parenthetical descriptor
#
# In-scope file types under $PLUGIN_DIR/scripts/ and $PLUGIN_DIR/hooks/:
#   *.sh, *.py
#
# Excluded paths (anywhere under these):
#   tests/, docs/designs/, docs/adr/, docs/archive/, fixtures/, CHANGELOG*
#
# Per-line escape: append "# stale-term-ok" to a line to suppress the
# check for that specific line (mirrors the # tickets-boundary-ok
# convention elsewhere in the codebase).
#
# Usage:
#   check-stale-terms.sh [--scan-dir <dir>] [file ...]
#
# Exit codes:
#   0 — no violations found
#   1 — one or more violations found

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_ROOT="$(git rev-parse --show-toplevel)"

# ── Parse arguments ──────────────────────────────────────────────────────────
_scan_dir=""
_explicit_files=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --scan-dir) _scan_dir="$2"; shift 2 ;;
        --scan-dir=*) _scan_dir="${1#--scan-dir=}"; shift ;;
        --help|-h)
            sed -n '4,/^$/p' "$0" | sed 's/^# \?//'
            exit 0
            ;;
        *) _explicit_files+=("$1"); shift ;;
    esac
done

# ── Patterns (extended regex, used with grep -E -i) ──────────────────────────
_PATTERNS=(
    'skeleton implementation'
    'walking[ -]skeleton'
    'placeholder implementation'
    'lands in Task'
    'TODO before production'
    '(this|this is a) skeleton'
    '\(skeleton\)'
)

# Combined alternation pattern
_COMBINED=''
for _p in "${_PATTERNS[@]}"; do
    if [[ -z "$_COMBINED" ]]; then
        _COMBINED="$_p"
    else
        _COMBINED="$_COMBINED|$_p"
    fi
done

# ── Determine target file list ───────────────────────────────────────────────
_files=()
if [[ ${#_explicit_files[@]} -gt 0 ]]; then
    _files=("${_explicit_files[@]}")
elif [[ -n "$_scan_dir" ]]; then
    while IFS= read -r -d '' _f; do _files+=("$_f"); done < <(
        find "$_scan_dir" -type f \( -name '*.sh' -o -name '*.py' \) -print0
    )
else
    # Default: scan $PLUGIN_DIR/scripts and $PLUGIN_DIR/hooks
    for _root in "$PLUGIN_DIR/scripts" "$PLUGIN_DIR/hooks"; do
        [[ -d "$_root" ]] || continue
        while IFS= read -r -d '' _f; do _files+=("$_f"); done < <(
            find "$_root" -type f \( -name '*.sh' -o -name '*.py' \) -print0
        )
    done
fi

# ── Excluded path patterns (any path component match excludes the file) ──────
# The lint script itself is excluded because it documents and pattern-matches
# the stale vocabulary it detects (mirrors check-model-id-lint.sh's exclusion
# of resolve-model-id.sh).
_is_excluded() {
    local _p="$1"
    case "$_p" in
        */tests/*|*/test/*) return 0 ;;
        */docs/designs/*|*/docs/adr/*|*/docs/archive/*) return 0 ;;
        */fixtures/*|*/fixture/*) return 0 ;;
        */CHANGELOG*) return 0 ;;
        */check-stale-terms.sh) return 0 ;;
    esac
    return 1
}

# ── Scan ─────────────────────────────────────────────────────────────────────
_violations=0
_violation_lines=()
for _f in "${_files[@]}"; do
    [[ -f "$_f" ]] || continue
    if _is_excluded "$_f"; then continue; fi

    # Read line-by-line; report any line matching a stale-term pattern
    # UNLESS the line ends with the escape annotation.
    while IFS= read -r _line_with_num; do
        _lineno="${_line_with_num%%:*}"
        _content="${_line_with_num#*:}"
        # Skip if the line carries the per-line escape annotation
        case "$_content" in
            *'# stale-term-ok'*) continue ;;
        esac
        printf '%s:%s: %s\n' "$_f" "$_lineno" "$_content"
        _violations=$((_violations + 1))
    done < <(grep -niE "$_COMBINED" "$_f" 2>/dev/null || true)
done

# ── Report ───────────────────────────────────────────────────────────────────
if [[ "$_violations" -gt 0 ]]; then
    echo "" >&2
    echo "check-stale-terms: $_violations stale-term occurrence(s) found." >&2
    echo "" >&2
    echo "Production scripts must not self-describe with vocabulary that" >&2
    echo "implies the code is incomplete. Either:" >&2
    echo "  (a) rewrite the comment/docstring to describe current behavior, or" >&2
    echo "  (b) append '# stale-term-ok' to the line if the match is a legitimate" >&2
    echo "      reference (e.g., a code comment quoting a historical term)." >&2
    echo "" >&2
    echo "Patterns detected: ${_PATTERNS[*]}" >&2
    exit 1
fi

echo "check-stale-terms: no violations found."
exit 0
