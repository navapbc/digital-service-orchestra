#!/usr/bin/env bash
set -uo pipefail
# scripts/check-shim-refs.sh
# Detect direct plugin script references that should use the ${_PLUGIN_ROOT}/scripts/shim.
#
# A 'shim violation' is any of:
#   1. Literal path:  ${_PLUGIN_ROOT}/scripts/
#   2. Variable path: $PLUGIN_SCRIPTS/ or ${PLUGIN_SCRIPTS}/
#   3. Variable path: ${CLAUDE_PLUGIN_ROOT}/scripts/ or $CLAUDE_PLUGIN_ROOT/scripts/
#
# Exclusions:
#   - source commands targeting ${CLAUDE_PLUGIN_ROOT}/hooks/lib/ (legitimate internal sourcing)
#   - Files within ${_PLUGIN_ROOT}/scripts/ (script-to-script references are valid)
#   - Lines with # shim-exempt: <reason> annotation (case-insensitive)
#   - Files outside ${CLAUDE_PLUGIN_ROOT}/ (out of scope)
#
# Usage:
#   scripts/check-shim-refs.sh [file ...]
#
# When no arguments are given, scans the default in-scope file set:
#   ${CLAUDE_PLUGIN_ROOT}/{skills,agents,docs/workflows,docs/prompts} (recursively, no symlinks)
#
# Exit codes:
#   0 — No violations found
#   1 — One or more violations found

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# SCRIPT_DIR is ${_PLUGIN_ROOT}/scripts/ — one level up is the plugin root (${CLAUDE_PLUGIN_ROOT}/)
PLUGIN_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# ── Determine file set ────────────────────────────────────────────────────────
_scan_targets=()
if [[ $# -gt 0 ]]; then
    # Explicit targets provided (used for pre-commit hook and test isolation)
    _scan_targets=("$@")
elif [[ -n "${PRE_COMMIT:-}" ]]; then
    # Pre-commit hook context: scan only staged files under ${CLAUDE_PLUGIN_ROOT}/ (not scripts/)
    # to avoid the full 183-file corpus scan that causes timeouts on larger changesets.
    # _scan_file already filters out scripts/ files, so we pass all staged ${CLAUDE_PLUGIN_ROOT}/ files.
    _repo_root="$(git rev-parse --show-toplevel 2>/dev/null || (cd "$PLUGIN_DIR" && git rev-parse --show-toplevel 2>/dev/null))"
    mapfile -t _scan_targets < <(git diff --cached --name-only -- plugins/dso/ 2>/dev/null | while IFS= read -r _f; do
        [[ -f "$_repo_root/$_f" ]] && echo "$_repo_root/$_f"
    done)
else
    # Default in-scope set: ${CLAUDE_PLUGIN_ROOT}/{skills,agents,docs/workflows,docs/prompts}
    for _dir in skills agents docs/workflows docs/prompts; do
        if [[ -d "$PLUGIN_DIR/$_dir" ]]; then
            _scan_targets+=("$PLUGIN_DIR/$_dir")
        fi
    done
fi

if [[ ${#_scan_targets[@]} -eq 0 ]]; then
    echo "check-shim-refs: no files to scan" >&2
    exit 0
fi

# ── Scan ─────────────────────────────────────────────────────────────────────
_violations=0

_is_in_scope() {
    local _file="$1"
    # Only files within ${CLAUDE_PLUGIN_ROOT}/ are in scope
    # Use realpath-free approach: check if path contains ${CLAUDE_PLUGIN_ROOT}/
    local _real_file
    _real_file="$(cd "$(dirname "$_file")" 2>/dev/null && pwd)/$(basename "$_file")" || true
    if [[ -z "$_real_file" ]]; then
        _real_file="$_file"
    fi
    [[ "$_real_file" == */plugins/dso/* ]]
}

_is_in_scripts_dir() {
    local _file="$1"
    local _real_file
    _real_file="$(cd "$(dirname "$_file")" 2>/dev/null && pwd)/$(basename "$_file")" || true
    if [[ -z "$_real_file" ]]; then
        _real_file="$_file"
    fi
    [[ "$_real_file" == */plugins/dso/scripts/* ]]
}

_scan_file() {
    local _file="$1"

    # Skip files within ${_PLUGIN_ROOT}/scripts/ — script-to-script refs are valid
    if _is_in_scripts_dir "$_file"; then
        return
    fi

    # Determine if this file is inside the ${CLAUDE_PLUGIN_ROOT}/ tree.
    # For files outside ${CLAUDE_PLUGIN_ROOT}/, backtick-quoted references (markdown inline
    # code) are excluded from violation detection — those are documentation
    # references to plugin paths, which are valid in host-project docs.
    # For files inside ${CLAUDE_PLUGIN_ROOT}/, ALL matching patterns are violations because
    # instruction files must direct users to the ${_PLUGIN_ROOT}/scripts/shim.
    local _in_plugin_tree=0
    _is_in_scope "$_file" && _in_plugin_tree=1 || true

    # Use perl to detect violations:
    #   Pattern 1: ${_PLUGIN_ROOT}/scripts/ (literal path, not hooks/lib)
    #   Pattern 2: $PLUGIN_SCRIPTS/ or ${PLUGIN_SCRIPTS}/
    #   Pattern 3: ${CLAUDE_PLUGIN_ROOT}/scripts/ or $CLAUDE_PLUGIN_ROOT/scripts/
    #
    # Exclusions applied per-line:
    #   - Lines matching # shim-exempt: (case-insensitive) are skipped
    #   - source ... ${CLAUDE_PLUGIN_ROOT}/hooks/lib/ lines are skipped
    #   - For out-of-plugin-tree files: backtick-quoted occurrences are stripped
    #     before matching (markdown doc references are not violations)
    local _matches
    _matches=$(perl -ne "
        # Skip lines with shim-exempt annotation (case-insensitive)
        next if /\\#\\s*shim-exempt:/i;

        # Skip source commands targeting hooks/lib/
        next if /^\\s*(?:source|\\.)\\s+(?:\\S+\\/)?plugins\\/dso\\/hooks\\/lib\\//;

        # For files outside ${CLAUDE_PLUGIN_ROOT}/, strip backtick-quoted content so that
        # inline markdown code references are not treated as violations.
        my \$check_line = \$_;
        if (!$_in_plugin_tree) {
            \$check_line =~ s/\\\`[^\\\`]*\\\`//g;
        }

        # Check for violation patterns on the (possibly stripped) line
        my \$linenum = $.;
        my \$matched = 0;

        # Pattern 1: literal \${_PLUGIN_ROOT}/scripts/
        if (\$check_line =~ /plugins\\/dso\\/scripts\\//) {
            \$matched = 1;
        }

        # Pattern 2: \$PLUGIN_SCRIPTS/ or \${PLUGIN_SCRIPTS}/
        if (\$check_line =~ /\\\$\\{?PLUGIN_SCRIPTS\\}?\\//) {
            \$matched = 1;
        }

        # Pattern 3: \${CLAUDE_PLUGIN_ROOT}/scripts/ or \$CLAUDE_PLUGIN_ROOT/scripts/
        if (\$check_line =~ /\\\$\\{?CLAUDE_PLUGIN_ROOT\\}?\\/scripts\\//) {
            \$matched = 1;
        }

        if (\$matched) {
            chomp(my \$content = \$_);
            print \"\$linenum\\t\$content\\n\";
        }
    " "$_file" 2>/dev/null || true)

    if [[ -n "$_matches" ]]; then
        while IFS=$'\t' read -r _linenum _content; do
            echo "VIOLATION: $_file:$_linenum: $_content"
            (( _violations++ )) || true
        done <<< "$_matches"
    fi
}

_scan_path() {
    local _path="$1"
    if [[ -d "$_path" ]]; then
        # Recurse, no symlinks (-P = physical, don't follow symlinks)
        while IFS= read -r -d '' _f; do
            _scan_file "$_f"
        done < <(find -P "$_path" -type f -print0 2>/dev/null)
    elif [[ -r "$_path" ]]; then
        # Handle regular files, symlinks (like /dev/stdin), and other readable paths
        _scan_file "$_path"
    fi
}

for _target in "${_scan_targets[@]}"; do
    _scan_path "$_target"
done

# ── Summary ───────────────────────────────────────────────────────────────────
if [[ $_violations -gt 0 ]]; then
    echo "" >&2
    echo "check-shim-refs: $_violations shim violation(s) found." >&2
    echo "  Use the .claude/scripts/dso shim instead of direct plugin script paths." >&2
    echo "  To exempt a line: append  # shim-exempt: <reason>" >&2
    exit 1
fi

exit 0
