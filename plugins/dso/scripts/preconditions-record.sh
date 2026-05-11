#!/usr/bin/env bash
# preconditions-record.sh
# Record an immutable PRECONDITIONS event JSON into .tickets-tracker/<ticket_id>/  # tickets-boundary-ok
# on the tickets orphan branch using Python fcntl.flock (following ticket-flock-contract.md).
#
# Usage:
#   preconditions-record.sh --ticket-id <id> --gate-name <name> \
#       --session-id <id> --tier <tier> \
#       [--worktree-id <id>] [--data <json-object>] \
#       [--degradation] [--degradation-type <value>] [--condition-text <text>]
#
# Required:
#   --ticket-id <id>     Ticket to attach this event to (e.g., "dso-abc1")
#   --gate-name <name>   Name of the gate being recorded (e.g., "story_gate")
#   --session-id <id>    Session identifier
#   --tier <tier>        Review tier (e.g., "light", "standard", "deep")
#
# Optional:
#   --worktree-id <id>         Worktree branch identifier (defaults to current git branch)
#   --data <json>              JSON object with additional data (defaults to {})
#   --degradation              Sets data.degradation=true in the event data
#   --degradation-type <value> Sets data.degradation_type=<value> (valid: inferred_decision, unresolved_question)
#   --condition-text <text>    Sets data.condition_text=<text> in the event data
#
# Exit codes:
#   0  — success: file written and committed
#   1  — error: missing arguments, tracker not initialized, or lock exhaustion

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source the shared flock library
# shellcheck source=${_PLUGIN_ROOT}/scripts/ticket-lib.sh
source "$SCRIPT_DIR/ticket-lib.sh"

# ── Argument parsing ─────────────────────────────────────────────────────────
ticket_id_arg=""
gate_name_arg=""
session_id_arg=""
tier_arg=""
worktree_id_arg=""
data_arg=""
_degradation=""
_degradation_type=""
_condition_text=""

while [ $# -gt 0 ]; do
    case "$1" in
        --ticket-id)
            ticket_id_arg="$2"; shift 2 ;;
        --ticket-id=*)
            ticket_id_arg="${1#--ticket-id=}"; shift ;;
        --gate-name)
            gate_name_arg="$2"; shift 2 ;;
        --gate-name=*)
            gate_name_arg="${1#--gate-name=}"; shift ;;
        --session-id)
            session_id_arg="$2"; shift 2 ;;
        --session-id=*)
            session_id_arg="${1#--session-id=}"; shift ;;
        --tier)
            tier_arg="$2"; shift 2 ;;
        --tier=*)
            tier_arg="${1#--tier=}"; shift ;;
        --worktree-id)
            worktree_id_arg="$2"; shift 2 ;;
        --worktree-id=*)
            worktree_id_arg="${1#--worktree-id=}"; shift ;;
        --data)
            data_arg="$2"; shift 2 ;;
        --data=*)
            data_arg="${1#--data=}"; shift ;;
        --degradation)
            _degradation="true"; shift ;;
        --degradation-type)
            _degradation_type="$2"
            if [[ "$_degradation_type" != "inferred_decision" && "$_degradation_type" != "unresolved_question" ]]; then
                echo "Error: --degradation-type must be one of: inferred_decision, unresolved_question" >&2
                exit 1
            fi
            shift 2 ;;
        --degradation-type=*)
            _degradation_type="${1#--degradation-type=}"
            if [[ "$_degradation_type" != "inferred_decision" && "$_degradation_type" != "unresolved_question" ]]; then
                echo "Error: --degradation-type must be one of: inferred_decision, unresolved_question" >&2
                exit 1
            fi
            shift ;;
        --condition-text)
            _condition_text="$2"; shift 2 ;;
        --condition-text=*)
            _condition_text="${1#--condition-text=}"; shift ;;
        --help|-h)
            echo "Usage: preconditions-record.sh --ticket-id <id> --gate-name <name> --session-id <id> --tier <tier>" >&2
            echo "       [--worktree-id <id>] [--data <json>] [--degradation] [--degradation-type <value>] [--condition-text <text>]" >&2
            exit 0
            ;;
        -*)
            echo "Error: unknown option '$1'" >&2
            exit 1
            ;;
        *)
            echo "Error: unexpected argument '$1'" >&2
            exit 1
            ;;
    esac
done

# ── Validate required arguments ──────────────────────────────────────────────
missing_args=()
[ -z "$ticket_id_arg" ]  && missing_args+=("--ticket-id")
[ -z "$gate_name_arg" ]  && missing_args+=("--gate-name")
[ -z "$session_id_arg" ] && missing_args+=("--session-id")
[ -z "$tier_arg" ]       && missing_args+=("--tier")

if [ "${#missing_args[@]}" -gt 0 ]; then
    echo "Error: missing required arguments: ${missing_args[*]}" >&2
    echo "Usage: preconditions-record.sh --ticket-id <id> --gate-name <name> --session-id <id> --tier <tier>" >&2
    echo "       [--worktree-id <id>] [--data <json>]" >&2
    exit 1
fi

# ── Resolve worktree_id ──────────────────────────────────────────────────────
if [ -n "$worktree_id_arg" ]; then
    WORKTREE_ID="$worktree_id_arg"
else
    WORKTREE_ID=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown")
fi

# ── Merge degradation/condition fields into data JSON ───────────────────────
# Only perform merge when at least one of the new flags is provided.
# The base data_json defaults to {} if --data was not supplied.
_data_json="${data_arg}"
[ -z "$_data_json" ] && _data_json="{}"
if [[ "${_degradation:-}" == "true" ]] || [[ -n "${_degradation_type:-}" ]] || [[ -n "${_condition_text:-}" ]]; then
    _data_json=$(python3 -c "
import json, sys
d = json.loads(sys.argv[1])
if sys.argv[2] == 'true':
    d['degradation'] = True
if sys.argv[3]:
    d['degradation_type'] = sys.argv[3]
if sys.argv[4]:
    d['condition_text'] = sys.argv[4]
print(json.dumps(d))
" "$_data_json" "${_degradation:-false}" "${_degradation_type:-}" "${_condition_text:-}")
fi

# ── Delegate to _write_preconditions ────────────────────────────────────────
_write_preconditions \
    "$ticket_id_arg" \
    "$gate_name_arg" \
    "$session_id_arg" \
    "$WORKTREE_ID" \
    "$tier_arg" \
    "${_data_json}"
