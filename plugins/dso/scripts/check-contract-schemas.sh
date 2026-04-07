#!/usr/bin/env bash
# plugins/dso/scripts/check-contract-schemas.sh
# Validate structural schema of contract documents in plugins/dso/docs/contracts/.
#
# Adaptive validation rules:
#   Universal (all contracts):
#     1. Level-1 heading starts with "# Contract:"
#     2. "## Purpose" section present with non-empty content
#   Signal-contract-specific (file contains "## Signal Format" or "## Signal Name"):
#     3. "### Canonical parsing prefix" section present with non-empty content
#
# Usage:
#   check-contract-schemas.sh [file-or-dir ...]
#
# When no arguments are given, scans plugins/dso/docs/contracts/*.md.
# Accepts explicit file args for staged-file mode, or a directory to scan all *.md within it.
#
# Exit codes:
#   0 — All contracts pass validation
#   1 — One or more contracts fail validation

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# ── Determine file list ──────────────────────────────────────────────────────
_files=()
if [[ $# -gt 0 ]]; then
    for _arg in "$@"; do
        if [[ -d "$_arg" ]]; then
            # Directory arg: scan all *.md files within
            while IFS= read -r _f; do
                [[ -n "$_f" ]] && _files+=("$_f")
            done < <(find "$_arg" -maxdepth 1 -name '*.md' -type f 2>/dev/null | sort)
        elif [[ -f "$_arg" ]] || [[ -p "$_arg" ]] || [[ "$_arg" == /dev/* ]]; then
            _files+=("$_arg")
        fi
    done
else
    # Default: scan plugins/dso/docs/contracts/*.md
    local_contracts="$PLUGIN_DIR/docs/contracts"
    if [[ -d "$local_contracts" ]]; then
        while IFS= read -r _f; do
            [[ -n "$_f" ]] && _files+=("$_f")
        done < <(find "$local_contracts" -maxdepth 1 -name '*.md' -type f 2>/dev/null | sort)
    fi
fi

if [[ ${#_files[@]} -eq 0 ]]; then
    echo "check-contract-schemas: no contract files to validate" >&2
    exit 0
fi

# ── Validation ───────────────────────────────────────────────────────────────
_failures=0

# _has_section file heading
# Returns 0 if the file contains a line matching ^heading (exact markdown heading).
_has_section() {
    local _file="$1" _heading="$2"
    grep -q "^${_heading}$" "$_file" 2>/dev/null || \
    grep -q "^${_heading} *$" "$_file" 2>/dev/null || \
    grep -q "^${_heading}$" "$_file" 2>/dev/null
}

# _section_has_content file heading
# Returns 0 if the section has non-empty content between the heading and the
# next heading of equal or higher level (or EOF).
_section_has_content() {
    local _file="$1" _heading="$2"
    local _level _in_section=0 _found_content=0

    # Determine heading level from prefix (count leading #)
    _level="${_heading%%[^#]*}"
    local _level_len=${#_level}

    while IFS= read -r _line; do
        if [[ $_in_section -eq 1 ]]; then
            # Check if we hit another heading of equal or higher level
            local _line_hashes="${_line%%[^#]*}"
            if [[ ${#_line_hashes} -ge 1 && ${#_line_hashes} -le $_level_len && "$_line" == "#"* ]]; then
                # Reached next section at same or higher level — stop
                break
            fi
            # Check for non-empty, non-whitespace content
            local _trimmed="${_line//[[:space:]]/}"
            if [[ -n "$_trimmed" && "$_trimmed" != "---" ]]; then
                _found_content=1
                break
            fi
        fi
        # Match the heading (with optional trailing whitespace)
        if [[ "$_line" == "${_heading}" || "$_line" == "${_heading} "* ]]; then
            _in_section=1
        fi
    done < "$_file"

    [[ $_found_content -eq 1 ]]
}

_validate_file() {
    local _file="$1"
    local _name
    _name="$(basename "$_file")"
    local _file_failed=0

    # Rule 1: Level-1 heading starts with "# Contract:"
    if ! grep -q "^# Contract:" "$_file" 2>/dev/null; then
        echo "FAIL: $_name: missing '# Contract:' level-1 heading" >&2
        _file_failed=1
    fi

    # Rule 2: ## Purpose section present with non-empty content
    if ! grep -q "^## Purpose" "$_file" 2>/dev/null; then
        echo "FAIL: $_name: missing '## Purpose' section" >&2
        _file_failed=1
    elif ! _section_has_content "$_file" "## Purpose"; then
        echo "FAIL: $_name: '## Purpose' section has no content" >&2
        _file_failed=1
    fi

    # Signal-contract detection: file contains "## Signal Format" or "## Signal Name"
    local _is_signal=0
    if grep -q "^## Signal Format" "$_file" 2>/dev/null || \
       grep -q "^## Signal Name" "$_file" 2>/dev/null; then
        _is_signal=1
    fi

    # Rule 3 (signal contracts only): ### Canonical parsing prefix with content
    if [[ $_is_signal -eq 1 ]]; then
        if ! grep -q "^### Canonical parsing prefix" "$_file" 2>/dev/null; then
            echo "FAIL: $_name: signal contract missing '### Canonical parsing prefix' section" >&2
            _file_failed=1
        elif ! _section_has_content "$_file" "### Canonical parsing prefix"; then
            echo "FAIL: $_name: '### Canonical parsing prefix' section has no content" >&2
            _file_failed=1
        fi
    fi

    if [[ $_file_failed -gt 0 ]]; then
        (( _failures++ )) || true
    fi
}

for _f in "${_files[@]}"; do
    _validate_file "$_f"
done

# ── Result ───────────────────────────────────────────────────────────────────
if [[ $_failures -gt 0 ]]; then
    echo "" >&2
    echo "check-contract-schemas: $_failures contract(s) failed validation." >&2
    exit 1
fi

exit 0
