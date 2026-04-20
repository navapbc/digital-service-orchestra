#!/usr/bin/env bash
# preconditions-record.sh
# Record an immutable PRECONDITIONS event JSON into .tickets-tracker/<ticket_id>/
# on the tickets orphan branch using Python fcntl.flock (following ticket-flock-contract.md).
#
# Usage:
#   preconditions-record.sh --ticket-id <id> --gate-name <name> \
#       --session-id <id> --tier <tier> \
#       [--worktree-id <id>] [--data <json-object>]
#
# Required:
#   --ticket-id <id>     Ticket to attach this event to (e.g., "dso-abc1")
#   --gate-name <name>   Name of the gate being recorded (e.g., "story_gate")
#   --session-id <id>    Session identifier
#   --tier <tier>        Review tier (e.g., "light", "standard", "deep")
#
# Optional:
#   --worktree-id <id>   Worktree branch identifier (defaults to current git branch)
#   --data <json>        JSON object with additional data (defaults to {})
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
        --help|-h)
            echo "Usage: preconditions-record.sh --ticket-id <id> --gate-name <name> --session-id <id> --tier <tier>" >&2
            echo "       [--worktree-id <id>] [--data <json>]" >&2
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

# ── Delegate to _write_preconditions ────────────────────────────────────────
_write_preconditions \
    "$ticket_id_arg" \
    "$gate_name_arg" \
    "$session_id_arg" \
    "$WORKTREE_ID" \
    "$tier_arg" \
    "${data_arg:-{}}"
