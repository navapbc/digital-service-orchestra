#!/usr/bin/env bash
# check-contract-schemas.sh
# Validate structural schema of contract documents in ${CLAUDE_PLUGIN_ROOT}/docs/contracts/.
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
# When no arguments are given, scans ${CLAUDE_PLUGIN_ROOT}/docs/contracts/*.md.
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
    # Default: scan ${CLAUDE_PLUGIN_ROOT}/docs/contracts/*.md
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
# Uses python3 for fast buffered I/O instead of bash while-read (which takes
# ~6s/file on macOS due to per-line syscalls).
_section_has_content() {
    local _file="$1" _heading="$2"
    python3 -c "
import sys
heading = sys.argv[1]
level = len(heading) - len(heading.lstrip('#'))
in_section = False
with open(sys.argv[2]) as f:
    for line in f:
        line = line.rstrip('\n')
        if in_section:
            if line.startswith('#'):
                hashes = len(line) - len(line.lstrip('#'))
                if 1 <= hashes <= level:
                    break
            trimmed = line.strip()
            if trimmed and trimmed != '---':
                sys.exit(0)
        if line == heading or line.rstrip() == heading:
            in_section = True
sys.exit(1)
" "$_heading" "$_file" 2>/dev/null
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
