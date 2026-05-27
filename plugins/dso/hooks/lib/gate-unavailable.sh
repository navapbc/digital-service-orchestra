#!/usr/bin/env bash
# shellcheck disable=SC2317  # exit 0 fallback for non-sourced invocation is intentional
# hooks/lib/gate-unavailable.sh
# F-02: shared helper for the gate-tier doctrine.
#
# Provides two functions for safety-critical (Tier A) and advisory (Tier C)
# gates to signal infrastructure failure to the rest of the workflow without
# silently passing. See HOOKS-REFERENCE.md (in the plugin docs dir) for the tier
# classification and the paired-env-var bypass envelope.
#
# Functions:
#   _dso_gate_unavailable <gate_name> <reason>
#       Records a GATE_UNAVAILABLE event for the named gate. Writes a JSONL
#       audit record to $HOME/.claude/logs/dso-gate-unavailable.jsonl and an
#       event-log entry (via the existing event-log channel if available).
#       Audit record fields: timestamp, gate_name, reason, session_id,
#       ticket_id, actor.
#
#       Tier A semantics: callers should `return 2` (block) after the call
#       (unless _dso_gate_bypass_active returns 0).
#       Tier C semantics: callers proceed with their existing degradation
#       path; the audit entry is the only side-effect.
#
#   _dso_gate_bypass_active <gate_name>
#       Returns 0 when BOTH env vars are set:
#         DSO_GATE_BYPASS_<UPPER_GATE_NAME>=1
#         DSO_GATE_BYPASS_<UPPER_GATE_NAME>_REASON=<non-empty>
#       When active, emits an audit record so the bypass is discoverable in
#       retrospectives. Returns non-zero when bypass is not active.
#
# Library mode: source-only. Do not execute directly.

# Avoid double-sourcing.
if [[ -n "${_DSO_GATE_UNAVAILABLE_LIB:-}" ]]; then
    return 0 2>/dev/null || exit 0
fi
_DSO_GATE_UNAVAILABLE_LIB=1

# ── Internal helper: resolve session_id / ticket_id from environment ─────────
# These fields propagate through the event-log helper convention; when
# unavailable, log as "unknown" rather than crashing.
_dso_gate_resolve_session_id() {
    if [[ -n "${DSO_SESSION_ID:-}" ]]; then
        printf '%s' "$DSO_SESSION_ID"
    elif [[ -n "${SPRINT_SESSION_ID:-}" ]]; then
        printf '%s' "$SPRINT_SESSION_ID"
    elif [[ -n "${CLAUDE_SESSION_ID:-}" ]]; then
        printf '%s' "$CLAUDE_SESSION_ID"
    else
        printf 'unknown'
    fi
}

_dso_gate_resolve_ticket_id() {
    if [[ -n "${DSO_TICKET_ID:-}" ]]; then
        printf '%s' "$DSO_TICKET_ID"
    elif [[ -n "${TICKET_ID:-}" ]]; then
        printf '%s' "$TICKET_ID"
    elif [[ -n "${PRIMARY_TICKET_ID:-}" ]]; then
        printf '%s' "$PRIMARY_TICKET_ID"
    else
        printf 'unknown'
    fi
}

# ── Internal helper: JSON-escape a string value ──────────────────────────────
# Escapes the five characters that produce invalid JSON if left raw inside a
# string value: backslash, double-quote, newline, carriage return, tab.
# Other control characters (NUL, vertical tab, form feed, etc.) are not handled
# explicitly — they should not appear in any documented caller's reason text.
# Stdout: the escaped string. Always succeeds.
_dso_gate_json_escape() {
    local _s="${1-}"
    _s="${_s//\\/\\\\}"          # backslash first (so we don't double-escape our own escapes)
    _s="${_s//\"/\\\"}"          # double-quote
    _s="${_s//$'\n'/\\n}"        # newline
    _s="${_s//$'\r'/\\r}"        # carriage return
    _s="${_s//$'\t'/\\t}"        # tab
    printf '%s' "$_s"
}

# ── Internal helper: validate a gate name ────────────────────────────────────
# Gate names are used both as JSON values and as the suffix of bypass env vars
# (DSO_GATE_BYPASS_<UPPER_GATE_NAME>). Bash env-var names must match
# [A-Za-z_][A-Za-z0-9_]* — hyphens, dots, and other punctuation produce invalid
# identifiers that `${!var}` cannot read, silently breaking the bypass. Enforce
# the constraint at the helper boundary so future callers get a clear error
# instead of a silent contract violation. Returns 0 on valid; 1 on invalid.
_dso_gate_name_valid() {
    local _name="${1-}"
    [[ "$_name" =~ ^[a-z_][a-z0-9_]*$ ]]
}

# ── Public: _dso_gate_unavailable ────────────────────────────────────────────
_dso_gate_unavailable() {
    local _gate_name="${1:-unknown_gate}"
    local _reason="${2:-no_reason}"
    local _log_dir="${HOME}/.claude/logs"
    local _log_file="${_log_dir}/dso-gate-unavailable.jsonl"
    local _ts _session _ticket _actor _line

    _ts=$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "unknown")
    _session=$(_dso_gate_resolve_session_id)
    _ticket=$(_dso_gate_resolve_ticket_id)
    _actor="${USER:-unknown}"

    # JSON-escape every field that could contain caller-provided text.
    # gate_name is validated at the bypass boundary; the unavailable path also
    # accepts arbitrary callers, so we escape here defensively rather than
    # assuming validation upstream.
    local _gate_escaped _reason_escaped _session_escaped _ticket_escaped _actor_escaped
    _gate_escaped=$(_dso_gate_json_escape "$_gate_name")
    _reason_escaped=$(_dso_gate_json_escape "$_reason")
    _session_escaped=$(_dso_gate_json_escape "$_session")
    _ticket_escaped=$(_dso_gate_json_escape "$_ticket")
    _actor_escaped=$(_dso_gate_json_escape "$_actor")

    _line=$(printf '{"timestamp":"%s","gate_name":"%s","reason":"%s","session_id":"%s","ticket_id":"%s","actor":"%s"}' \
        "$_ts" "$_gate_escaped" "$_reason_escaped" "$_session_escaped" "$_ticket_escaped" "$_actor_escaped")

    # Best-effort write — never block the gate on log-write failure.
    mkdir -p "$_log_dir" 2>/dev/null || true
    printf '%s\n' "$_line" >> "$_log_file" 2>/dev/null || true

    # Mirror to stderr so the operator sees the event in the current session.
    printf 'GATE_UNAVAILABLE: gate=%s reason=%s session=%s ticket=%s\n' \
        "$_gate_name" "$_reason" "$_session" "$_ticket" >&2

    return 0
}

# ── Public: _dso_gate_bypass_active ──────────────────────────────────────────
_dso_gate_bypass_active() {
    local _gate_name="${1:-unknown_gate}"

    # Validate gate name. The bypass mechanism uses DSO_GATE_BYPASS_<UPPER_NAME>
    # as a bash env var; names with hyphens, dots, or other non-identifier
    # characters produce an invalid env-var name that the indirect lookup
    # cannot read, silently breaking the bypass. Fail loudly at the contract
    # boundary instead.
    if ! _dso_gate_name_valid "$_gate_name"; then
        printf 'BYPASS_REJECTED: gate name %q is not a valid bash identifier (must match [a-z_][a-z0-9_]*).\n' \
            "$_gate_name" >&2
        return 1
    fi

    # Upper-case the gate name for env-var lookup (DSO_GATE_BYPASS_<UPPER>).
    local _upper
    _upper=$(printf '%s' "$_gate_name" | tr '[:lower:]' '[:upper:]')
    local _flag_var="DSO_GATE_BYPASS_${_upper}"
    local _reason_var="DSO_GATE_BYPASS_${_upper}_REASON"

    # Indirect lookup (bash ${!var} form).
    local _flag="${!_flag_var:-}"
    local _reason="${!_reason_var:-}"

    if [[ "$_flag" != "1" ]]; then
        return 1
    fi

    if [[ -z "$_reason" ]]; then
        printf 'BYPASS_REJECTED: %s=1 set but %s is empty. Set %s="<one-line justification>" to authorize.\n' \
            "$_flag_var" "$_reason_var" "$_reason_var" >&2
        return 1
    fi

    # Bypass is active — emit an audit record so it's retrospectively visible.
    local _log_dir="${HOME}/.claude/logs"
    local _log_file="${_log_dir}/dso-gate-unavailable.jsonl"
    local _ts _session _ticket _actor _line

    _ts=$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "unknown")
    _session=$(_dso_gate_resolve_session_id)
    _ticket=$(_dso_gate_resolve_ticket_id)
    _actor="${USER:-unknown}"

    local _gate_escaped _reason_escaped _session_escaped _ticket_escaped _actor_escaped
    _gate_escaped=$(_dso_gate_json_escape "$_gate_name")
    _reason_escaped=$(_dso_gate_json_escape "$_reason")
    _session_escaped=$(_dso_gate_json_escape "$_session")
    _ticket_escaped=$(_dso_gate_json_escape "$_ticket")
    _actor_escaped=$(_dso_gate_json_escape "$_actor")

    _line=$(printf '{"timestamp":"%s","event":"bypass_active","gate_name":"%s","reason":"%s","session_id":"%s","ticket_id":"%s","actor":"%s"}' \
        "$_ts" "$_gate_escaped" "$_reason_escaped" "$_session_escaped" "$_ticket_escaped" "$_actor_escaped")
    mkdir -p "$_log_dir" 2>/dev/null || true
    printf '%s\n' "$_line" >> "$_log_file" 2>/dev/null || true

    printf 'BYPASS_ACTIVE: gate=%s reason=%s session=%s ticket=%s\n' \
        "$_gate_name" "$_reason" "$_session" "$_ticket" >&2

    return 0
}
