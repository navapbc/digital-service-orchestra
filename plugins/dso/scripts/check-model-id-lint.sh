#!/usr/bin/env bash
set -uo pipefail
_PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/..}"
# scripts/check-model-id-lint.sh
# Detect hardcoded Claude model IDs in plugin source files.
#
# A 'model ID violation' is any occurrence of:
#   claude-(haiku|sonnet|opus)-[0-9]
# in source files under the scanned directory tree.
#
# Exclusions (applied by filename, regardless of path):
#   - dso-config.conf  (canonical model ID definition — intentionally hardcodes IDs)
#   - .test-index      (generated metadata, may reference IDs in RED markers)
#   - tests/           (test fixture files legitimately reference model IDs)
#   - resolve-model-id.sh  (model ID management script — contains IDs in comments/patterns)
#   - INSTALL.md       (documents model ID config keys with example values)
#
# Usage:
#   check-model-id-lint.sh [--scan-dir <dir>] [file ...]
#
# When no file arguments are given, scans:
#   ${_PLUGIN_ROOT}/ (*.yaml, *.sh, *.py, *.md)
#
# Exit codes:
#   0 — No violations found
#   1 — One or more violations found

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# SCRIPT_DIR is the scripts/ dir — one level up is the plugin root
PLUGIN_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# ── Parse arguments ───────────────────────────────────────────────────────────
_scan_dir=""
_explicit_files=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        --scan-dir)
            _scan_dir="$2"
            shift 2
            ;;
        --scan-dir=*)
            _scan_dir="${1#--scan-dir=}"
            shift
            ;;
        *)
            _explicit_files+=("$1")
            shift
            ;;
    esac
done

# ── Determine scan root ───────────────────────────────────────────────────────
if [[ -n "$_scan_dir" ]]; then
    _root="$_scan_dir"
else
    # Default: use git to resolve repo root portably
    _repo_root="$(git rev-parse --show-toplevel 2>/dev/null)" || _repo_root="$(cd "$SCRIPT_DIR" && cd "$(git rev-parse --show-toplevel)" && pwd)"
    _root="${_PLUGIN_ROOT}"
fi

# ── Scan ──────────────────────────────────────────────────────────────────────
# Pattern: hardcoded model ID pattern — claude-(haiku|sonnet|opus)-<digit>
_PATTERN='claude-(haiku|sonnet|opus)-[0-9]'

# Excluded filenames (basename matches — passed via --exclude to grep)
_EXCLUDE_FILES=(
    "dso-config.conf"
    ".test-index"
    "resolve-model-id.sh"
    "INSTALL.md"
    "bug-report-template.md"
    "CONFIGURATION-REFERENCE.md"
)

# Build grep --exclude and --exclude-dir flags
_grep_args=()
for _excl in "${_EXCLUDE_FILES[@]}"; do
    _grep_args+=(--exclude="$_excl")
done
_grep_args+=(--exclude-dir="tests")

if [[ ${#_explicit_files[@]} -gt 0 ]]; then
    # Explicit file arguments: scan only those files (apply exclusion predicate manually)
    _violations=0
    for _file in "${_explicit_files[@]}"; do
        [[ -f "$_file" ]] || continue

        # Skip excluded filenames
        _basename="$(basename "$_file")"
        _skip=0
        for _excl in "${_EXCLUDE_FILES[@]}"; do
            [[ "$_basename" == "$_excl" ]] && { _skip=1; break; }
        done
        [[ $_skip -eq 1 ]] && continue

        # Skip files under tests/
        [[ "$_file" == */tests/* || "$_file" == */tests ]] && continue

        if grep -En "$_PATTERN" "$_file" 2>/dev/null; then
            echo "check-model-id-lint: violation in $_file" >&2
            _violations=$(( _violations + 1 ))
        fi
    done
else
    # Fast path: single grep -r over the scan directory
    if [[ ! -d "$_root" ]]; then
        echo "check-model-id-lint: scan directory not found: $_root" >&2
        exit 0
    fi

    _output="$(grep -rEn "$_PATTERN" \
        --include="*.yaml" \
        --include="*.sh" \
        --include="*.py" \
        --include="*.md" \
        "${_grep_args[@]}" \
        "$_root" 2>/dev/null)"

    if [[ -z "$_output" ]]; then
        exit 0
    fi

    # Print matching lines (grep -rEn format: file:line:content)
    echo "$_output"

    # Count unique files with violations
    _violations="$(echo "$_output" | awk -F: '{print $1}' | sort -u | wc -l | tr -d ' ')"
    echo "" >&2
    echo "check-model-id-lint: violation in the above file(s)" >&2
fi

if [[ ${_violations:-0} -gt 0 ]]; then
    printf "\ncheck-model-id-lint: %d file(s) contain hardcoded model IDs.\n" "$_violations" >&2
    printf "Move model IDs to .claude/dso-config.conf and reference via _cfg().\n" >&2
    exit 1
fi

exit 0
