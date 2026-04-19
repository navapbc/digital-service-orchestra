#!/usr/bin/env bash
# Shared ERR handler library for DSO plugin hooks.
#
# Provides:
#   _dso_register_hook_err_handler(hook_name)  — set _DSO_HOOK_NAME, register ERR+EXIT traps
#   _dso_hook_err_handler()                    — ERR/EXIT trap body; writes enriched JSONL; fail-open
#
# Usage (in a hook script):
#   source /path/to/hooks/lib/hook-error-handler.sh
#   _dso_register_hook_err_handler "my-hook.sh"
#
# Log path: $HOME/.claude/logs/dso-hook-errors.jsonl
# JSONL fields: ts, hook, line, repo_root, plugin_version, bash_version, os
#
# Design constraints:
#   - Lazy log directory creation (never pre-creates)
#   - Size guard: skip write if log file >1MB
#   - Fail-open: handler exits 0 (never blocks hook execution)
#   - Plugin version cached in _DSO_HOOK_PLUGIN_VERSION (read once)
#   - ERR trap registered for standard error detection (and test verification)
#   - EXIT trap registered as fallback for () || true contexts where ERR is suppressed
#   - Idempotent guard: only loaded once per shell context

# Guard: only load once
[[ "${_DSO_HOOK_ERROR_HANDLER_LOADED:-}" == "1" ]] && return 0
_DSO_HOOK_ERROR_HANDLER_LOADED=1

# Cache slot for plugin version (populated lazily on first handler invocation)
_DSO_HOOK_PLUGIN_VERSION=""

# _dso_register_hook_err_handler hook_name
# Atomically sets _DSO_HOOK_NAME and registers ERR + EXIT traps.
# The ERR trap catches errors in normal execution contexts.
# The EXIT trap catches errors in () || true contexts (where ERR is suppressed by bash).
_dso_register_hook_err_handler() {
    _DSO_HOOK_NAME="${1:-unknown-hook}"
    trap '_dso_hook_err_handler' ERR
    trap '_dso_hook_exit_handler' EXIT
}

# _dso_hook_exit_handler
# EXIT trap body. Invokes _dso_hook_err_handler when exit code is non-zero.
# Handles the case where () || true suppresses the ERR trap but the EXIT trap still fires.
_dso_hook_exit_handler() {
    local _exit_rc="$?"
    # Only act on non-zero exits (errors); skip clean exits
    [[ "$_exit_rc" -eq 0 ]] && return 0
    # exit 2 = intentional block signal from a hook (e.g., brainstorm gate, cascade breaker).
    # Pass through without logging — blocking is not an error.
    [[ "$_exit_rc" -eq 2 ]] && exit 2
    # Invoke the main error handler (which will exit 0 — fail-open)
    _dso_hook_err_handler
}

# _dso_hook_err_handler
# ERR trap body. Writes enriched JSONL to $HOME/.claude/logs/dso-hook-errors.jsonl.
# Always exits 0 (fail-open — never blocks hook execution).
_dso_hook_err_handler() {
    # Disable both traps inside body to prevent recursion
    trap - ERR EXIT

    local _log_dir _log_file _log_line _ts _hook _bash_version

    # Capture the line that triggered the ERR (set by the shell before the trap fires)
    _log_line="${BASH_LINENO[0]:-0}"
    _hook="${_DSO_HOOK_NAME:-unknown-hook}"
    _log_dir="${HOME}/.claude/logs"
    _log_file="${_log_dir}/dso-hook-errors.jsonl"

    # Lazily create log directory; exit 0 (fail-open) if mkdir fails
    if [[ ! -d "$_log_dir" ]]; then
        mkdir -p "$_log_dir" 2>/dev/null || exit 0
    fi

    # Size guard: skip write if file already exceeds 1MB (1048576 bytes)
    if [[ -f "$_log_file" ]]; then
        local _fsize
        _fsize=$(wc -c < "$_log_file" 2>/dev/null || echo 0)
        _fsize="${_fsize// /}"  # strip leading spaces from wc output
        if [[ "${_fsize:-0}" -gt 1048576 ]]; then
            exit 0
        fi
    fi

    # Epoch timestamp — printf %(%s)T is a bash builtin (bash 4.2+)
    printf -v _ts '%(%s)T' -1

    # Repo root — external command; diagnostic only
    local _repo_root
    _repo_root=$(git rev-parse --show-toplevel 2>/dev/null) || _repo_root=""

    # Plugin version — cached after first read to avoid repeated file I/O
    if [[ -z "$_DSO_HOOK_PLUGIN_VERSION" ]]; then
        local _handler_dir _ver_file
        _handler_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"
        _ver_file="${_handler_dir}/../../VERSION"
        if [[ -f "$_ver_file" ]]; then
            read -r _DSO_HOOK_PLUGIN_VERSION < "$_ver_file" 2>/dev/null || _DSO_HOOK_PLUGIN_VERSION="unknown"
        else
            _DSO_HOOK_PLUGIN_VERSION="unknown"
        fi
    fi

    # Bash version — pure builtin
    _bash_version="${BASH_VERSION:-unknown}"

    # OS — external command; diagnostic only
    local _os
    _os=$(uname -s 2>/dev/null) || _os="unknown"

    # Escape string values for safe JSONL embedding (backslash then double-quote)
    local _hook_esc _repo_root_esc _pv_esc _bv_esc _os_esc
    _hook_esc="${_hook//\\/\\\\}";           _hook_esc="${_hook_esc//\"/\\\"}"
    _repo_root_esc="${_repo_root//\\/\\\\}"; _repo_root_esc="${_repo_root_esc//\"/\\\"}"
    _pv_esc="${_DSO_HOOK_PLUGIN_VERSION//\\/\\\\}"; _pv_esc="${_pv_esc//\"/\\\"}"
    _bv_esc="${_bash_version//\\/\\\\}";     _bv_esc="${_bv_esc//\"/\\\"}"
    _os_esc="${_os//\\/\\\\}";               _os_esc="${_os_esc//\"/\\\"}"

    # Write JSONL entry (single printf — append; tolerate write errors)
    printf '{"ts":%s,"hook":"%s","line":%s,"repo_root":"%s","plugin_version":"%s","bash_version":"%s","os":"%s"}\n' \
        "$_ts" \
        "$_hook_esc" \
        "$_log_line" \
        "$_repo_root_esc" \
        "$_pv_esc" \
        "$_bv_esc" \
        "$_os_esc" \
        >> "$_log_file" 2>/dev/null || true

    # Fail-open: always exit 0 so hook execution is never blocked by the handler
    exit 0
}
