#!/usr/bin/env bash
# lib/centrality.sh — centrality scoring helpers for record-test-status
#
# Provides:
#   _is_astgrep_sg()
#   count_centrality <filepath> <repo_root>
#
# Guard: sourced at most once per shell process.
[[ -n "${_DSO_CENTRALITY_LOADED:-}" ]] && return 0
_DSO_CENTRALITY_LOADED=1

# ── Centrality scoring ───────────────────────────────────────────────────────
# the project pattern in blast-radius.sh count_fan_in() (line 226). The
# CLAUDE.md directive to prefer built-in tools over Bash grep applies to *Claude Code
# tool calls*, not to shell script logic. grep -rlE is the standard tool for recursive
# file content matching in bash — no Python subprocess is warranted for a simple count.

# _is_astgrep_sg: returns 0 only when the sg binary in PATH is ast-grep.
# Ubuntu ships shadow-utils' sg (switch-group) at /usr/bin/sg; that binary
# also satisfies `command -v sg` but is not ast-grep. We verify by checking
# that `sg --version` produces a version line starting with "sg <digit>",
# which ast-grep does and shadow-utils' sg does not.
_is_astgrep_sg() {
    command -v sg >/dev/null 2>&1 || return 1
    sg --version 2>/dev/null | grep -qE '^(sg|ast-grep) [0-9]' || return 1
}

# count_centrality: Counts files that directly reference the target file using
# grep pattern matching. Returns count on stdout (0 when no references found).
# Args: $1 = source file path (relative to repo root), $2 = repo root
# Returns: count on stdout (always a single integer, 0 on no matches)
count_centrality() {
    local filepath="$1"
    local repo_root="$2"

    local basename
    basename="$(basename "$filepath")"
    local module_name="${basename%.*}"

    # Escape regex metacharacters in module_name to prevent injection (Bug 5 fix).
    local escaped_module_name
    # shellcheck disable=SC2016  # single quotes are intentional: \& is sed syntax, not shell expansion
    escaped_module_name=$(printf '%s' "$module_name" | sed 's/[.[\*^$()+?{|\\]/\\&/g')

    # Hardcoded default patterns (fallback when no config patterns are present).
    # Patterns matched: Python import/from, bash source.
    local _hardcoded_pattern
    _hardcoded_pattern="(import[[:space:]]+${escaped_module_name}|from[[:space:]]+${escaped_module_name}[[:space:]]|source[[:space:]]+(.*/)?(${escaped_module_name}))"

    # Read test_gate.import_pattern.* keys from config.
    # Each key value may contain literal "$MODULE" which gets replaced with the escaped module name.
    local _config_file="${repo_root}/.claude/dso-config.conf"
    local _combined_pattern=""
    local _has_valid_config_pattern=false

    if [[ -f "$_config_file" ]]; then
        while IFS= read -r _cfg_line || [[ -n "$_cfg_line" ]]; do
            # Extract key and value
            local _cfg_key _cfg_val
            _cfg_key="${_cfg_line%%=*}"
            _cfg_val="${_cfg_line#*=}"

            # Skip entries with empty values
            [[ -z "$_cfg_val" ]] && continue

            # Replace literal $MODULE with the escaped module name
            local _resolved_pattern
            _resolved_pattern="${_cfg_val//\$MODULE/${escaped_module_name}}"

            # Validate pattern: pipe empty string through grep -E — exit 0 (match) or 1 (no match)
            # are both valid; any other exit code means the pattern itself is invalid.
            local _grep_rc=0
            echo '' | grep -E "$_resolved_pattern" 2>/dev/null || _grep_rc=$?
            if [[ "$_grep_rc" -ne 0 && "$_grep_rc" -ne 1 ]]; then
                echo "WARNING: invalid import pattern '${_cfg_key}': ${_resolved_pattern} — skipping" >&2
                continue
            fi

            # Append valid pattern to combined pattern
            if [[ -z "$_combined_pattern" ]]; then
                _combined_pattern="$_resolved_pattern"
            else
                _combined_pattern="${_combined_pattern}|${_resolved_pattern}"
            fi
            _has_valid_config_pattern=true
        done < <(grep '^test_gate\.import_pattern\.' "$_config_file" 2>/dev/null || true)
    fi

    # When no valid config patterns exist, fall back to hardcoded default patterns
    local _grep_pattern
    if [[ "$_has_valid_config_pattern" == "true" ]]; then
        _grep_pattern="$_combined_pattern"
    else
        # fallback to hardcoded default patterns
        _grep_pattern="$_hardcoded_pattern"
    fi

    local count
    count=$(grep -rlE \
        "$_grep_pattern" \
        "$repo_root" \
        --include='*.py' --include='*.sh' --include='*.bash' \
        --include='*.js' --include='*.ts' --include='*.tsx' \
        --include='*.rb' --include='*.java' 2>/dev/null \
        | grep -vcF "$repo_root/$filepath" 2>/dev/null) || count=0
    # Ensure single integer — grep pipelines can produce multi-line output
    # when one stage fails (e.g., "0\n0" from BSD grep exit-1 + || fallback).
    count=$(echo "$count" | tail -1 | tr -d '[:space:]')
    [[ "$count" =~ ^[0-9]+$ ]] || count=0

    echo "$count"
}
