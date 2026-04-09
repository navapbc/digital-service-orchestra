#!/usr/bin/env bash
set -uo pipefail
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
#   plugins/dso/ (*.yaml, *.sh, *.py, *.md)
#
# Exit codes:
#   0 — No violations found
#   1 — One or more violations found

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# SCRIPT_DIR is plugins/dso/scripts/ — one level up is the plugin root (plugins/dso/)
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

# ── Determine file set ────────────────────────────────────────────────────────
# Resolve the scan root (used for finding files when no explicit targets given)
if [[ -n "$_scan_dir" ]]; then
    _root="$_scan_dir"
else
    # Default: use git to resolve repo root portably
    _repo_root="$(git rev-parse --show-toplevel 2>/dev/null)" || _repo_root="$(cd "$SCRIPT_DIR" && cd "$(git rev-parse --show-toplevel)" && pwd)"
    _root="$_repo_root"
fi

_scan_files=()
if [[ ${#_explicit_files[@]} -gt 0 ]]; then
    # Explicit file arguments: scan only those
    _scan_files=("${_explicit_files[@]}")
elif [[ -n "$_scan_dir" ]]; then
    # --scan-dir with no explicit files: find all eligible files under the dir
    while IFS= read -r _f; do
        _scan_files+=("$_f")
    done < <(find "$_scan_dir" -type f \( \
        -name "*.yaml" -o \
        -name "*.sh" -o \
        -name "*.py" -o \
        -name "*.md" \
    \) 2>/dev/null)
else
    # Default mode: scan plugins/dso/ under repo root
    _dir="$_root/plugins/dso"
    if [[ -d "$_dir" ]]; then
        while IFS= read -r _f; do
            _scan_files+=("$_f")
        done < <(find "$_dir" -type f \( \
            -name "*.yaml" -o \
            -name "*.sh" -o \
            -name "*.py" -o \
            -name "*.md" \
        \) 2>/dev/null)
    fi
fi

if [[ ${#_scan_files[@]} -eq 0 ]]; then
    echo "check-model-id-lint: no files to scan" >&2
    exit 0
fi

# ── Exclusion predicate ───────────────────────────────────────────────────────
# Returns 0 (true/exclude) if the file should be skipped, 1 (false/include) otherwise.
_should_exclude() {
    local _path="$1"
    local _basename
    _basename="$(basename "$_path")"

    # Exclude by filename
    case "$_basename" in
        dso-config.conf)       return 0 ;;
        .test-index)           return 0 ;;
        resolve-model-id.sh)   return 0 ;;  # model ID management script
        INSTALL.md)            return 0 ;;  # documents config keys with examples
        bug-report-template.md) return 0 ;; # template with example model IDs
    esac

    # Exclude files inside a tests/ directory anywhere in the path
    # Strip leading component up to tests/ to detect any depth
    if [[ "$_path" == */tests/* || "$_path" == */tests ]]; then
        return 0
    fi

    return 1
}

# ── Scan ──────────────────────────────────────────────────────────────────────
_violations=0

for _file in "${_scan_files[@]}"; do
    [[ -f "$_file" ]] || continue
    _should_exclude "$_file" && continue

    # grep for hardcoded model ID pattern: claude-(haiku|sonnet|opus)-<digit>
    # Using ERE so we can use | for alternation
    if grep -En 'claude-(haiku|sonnet|opus)-[0-9]' "$_file" 2>/dev/null; then
        echo "check-model-id-lint: violation in $_file" >&2
        _violations=$(( _violations + 1 ))
    fi
done

if [[ $_violations -gt 0 ]]; then
    printf "\ncheck-model-id-lint: %d file(s) contain hardcoded model IDs.\n" "$_violations" >&2
    printf "Move model IDs to .claude/dso-config.conf and reference via _cfg().\n" >&2
    exit 1
fi

exit 0
