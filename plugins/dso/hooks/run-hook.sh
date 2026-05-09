#!/usr/bin/env bash
# hooks/run-hook.sh
# Parse-error resilient wrapper for hook scripts.
# All hooks in hooks.json should be invoked through this wrapper.
#
# Usage: run-hook.sh <hook-script> [args...]
#
# How it works:
#   1. Syntax-checks the target hook with `bash -n`
#   2. If syntax is valid: runs it, passes through exit code and stderr
#   3. If syntax is broken: logs the error, exits 0 (fail-open)
#
# This ensures a broken hook degrades to no enforcement rather than
# bricking the session with a parse error that bypasses ERR traps.
#
# CLAUDE_PLUGIN_ROOT: When running as a plugin, Claude Code sets
# CLAUDE_PLUGIN_ROOT to the plugin installation directory. This fallback
# guard resolves it from the script's location when running standalone
# (e.g., in tests or CI without Claude Code).

if [[ -z "${CLAUDE_PLUGIN_ROOT:-}" || ! -d "${CLAUDE_PLUGIN_ROOT:-}/hooks/lib" ]]; then
    CLAUDE_PLUGIN_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
fi

HOOK="$1"
shift

# Resolve relative paths against the hooks/ directory (e.g., "dispatchers/pre-bash.sh").
# This allows plugin.json to use relative dispatcher paths, reducing
# ${CLAUDE_PLUGIN_ROOT} occurrences in error messages (bug e724-31a3).
if [[ -n "$HOOK" && "${HOOK:0:1}" != "/" && ! -f "$HOOK" ]]; then
    HOOK="$CLAUDE_PLUGIN_ROOT/hooks/$HOOK"
fi

if [[ -z "$HOOK" || ! -f "$HOOK" ]]; then
    # No hook specified or file doesn't exist — fail-open
    exit 0
fi

# macOS-compatible millisecond timestamp (date +%s%N unavailable on macOS)
# Guarantees a numeric result — falls back to python3, then 0.
_get_ms() {
    local _ns
    _ns=$(date +%s%N 2>/dev/null) || _ns=""
    if [[ -n "$_ns" && "$_ns" != *N* ]]; then
        echo $(( _ns / 1000000 ))
    else
        python3 -c 'import time;print(int(time.time()*1e3))' 2>/dev/null || echo 0
    fi
}

# --- Hook timing instrumentation ---
# Logs wall-clock duration of each hook dispatcher to a timing file.
# Enable: touch ~/.claude/hook-timing-enabled
# View:   cat /tmp/hook-timing.log | column -t -s $'\t'
# Disable: rm ~/.claude/hook-timing-enabled
_HOOK_TIMING_LOG="/tmp/hook-timing.log"
_HOOK_TIMING_ENABLED=""
if [[ -f "$HOME/.claude/hook-timing-enabled" ]]; then
    _HOOK_TIMING_ENABLED=1
    _HOOK_START_MS=$(_get_ms)
fi

SYNTAX_ERR_LOG=$(mktemp /tmp/claude-hook-syntax-err.XXXXXX)
_HOOK_STDERR_TMP=""  # set later; declared here so _cleanup can always reference it
# shellcheck disable=SC2329  # invoked via trap EXIT below
_cleanup() {
    local _exit_code=$?
    rm -f "$SYNTAX_ERR_LOG" "${_HOOK_STDERR_TMP:-}"
    # Log timing on exit (covers both exec and non-exec paths)
    if [[ -n "$_HOOK_TIMING_ENABLED" ]]; then
        local _end_ms
        _end_ms=$(_get_ms)
        local _elapsed_ms=$((_end_ms - _HOOK_START_MS))
        printf '%s\t%s\t%dms\texit=%d\n' \
            "$(date +%H:%M:%S)" \
            "$(basename "$HOOK")" \
            "$_elapsed_ms" \
            "$_exit_code" \
            >> "$_HOOK_TIMING_LOG" 2>/dev/null
    fi
}
trap '_cleanup' EXIT

if ! bash -n "$HOOK" 2>"$SYNTAX_ERR_LOG"; then
    # Parse error detected — log it and fail-open
    HOOK_ERROR_LOG="$HOME/.claude/logs/dso-hook-errors.jsonl"
    mkdir -p "$HOME/.claude/logs" 2>/dev/null || true
    SYNTAX_ERR=$(cat "$SYNTAX_ERR_LOG" 2>/dev/null || echo "unknown")
    printf '{"ts":"%s","hook":"%s","error":"syntax","detail":"%s"}\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        "$(basename "$HOOK")" \
        "$(echo "$SYNTAX_ERR" | tr '"' "'" | tr '\n' ' ')" \
        >> "$HOOK_ERROR_LOG" 2>/dev/null
    exit 0
fi

# Run the hook and capture stderr so we can annotate BLOCKED output with the
# resolved CLAUDE_PLUGIN_ROOT path. Claude Code's error formatter uses the raw
# command string from plugin.json (which contains the literal
# '${CLAUDE_PLUGIN_ROOT}'), so agents see an unexpanded variable in the error
# prefix. By appending the resolved path to blocked-hook stderr, agents get an
# actionable location even when the harness prefix is unresolved (bug 8c3d-b5ac).
#
# Note: this replaces `exec "$HOOK"` (zero-overhead fast path) with a subprocess
# + stderr-capture. The EXIT trap still fires on the outer process exit, so hook
# timing instrumentation (when enabled) continues to work correctly.
_HOOK_STDERR_TMP=$(mktemp /tmp/claude-hook-stderr.XXXXXX)
"$HOOK" "$@" 2>"$_HOOK_STDERR_TMP"
_hook_exit=$?

# Flush captured stderr to actual stderr.
# On BLOCKED (exit 2), append the resolved plugin root so the agent can locate
# the hook source even when the harness shows '${CLAUDE_PLUGIN_ROOT}'.
cat "$_HOOK_STDERR_TMP" >&2
if [[ "$_hook_exit" -eq 2 ]]; then
    printf '[hook location: %s/hooks/run-hook.sh]\n' "$CLAUDE_PLUGIN_ROOT" >&2
fi
rm -f "$_HOOK_STDERR_TMP"
exit "$_hook_exit"
