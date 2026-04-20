#!/usr/bin/env bash
# ticket-lib-api.sh
# Sourceable library exposing in-process implementations of ticket subcommands.
# Replaces per-call `exec bash ticket-<cmd>.sh` subprocesses from the dispatcher.
#
# SOURCEABILITY CONTRACT (strict):
#   - No file-scope `set -euo pipefail` (would leak into caller).
#   - No file-scope `exit` (would kill caller).
#   - No file-scope `trap` (would clobber caller traps).
#   - No file-scope mutation of GIT_DIR / GIT_INDEX_FILE / GIT_WORK_TREE / GIT_COMMON_DIR.
#   - Functions use `ticket_` / `_ticketlib_` namespace.
#   - Idempotent source guard (re-sourcing is a no-op).

# ── Source guard ─────────────────────────────────────────────────────────────
if declare -f _ticketlib_dispatch >/dev/null 2>&1; then
    return 0 2>/dev/null
fi

# Resolve library directory (used to find sibling scripts + python package).
_TICKETLIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Dispatch helper ──────────────────────────────────────────────────────────
# Wraps each call in a subshell so per-call set -e / traps / var mutations
# cannot leak back into the caller's shell state.
_ticketlib_dispatch() {
    local op="$1"
    shift
    ( "$op" "$@" )
}

# ── ticket_show ──────────────────────────────────────────────────────────────
# In-process replacement for ticket-show.sh.
ticket_show() {
    # Legacy escape hatch: DSO_TICKET_LEGACY=1 delegates to the original script.
    if [ "${DSO_TICKET_LEGACY:-0}" = "1" ]; then
        bash "$_TICKETLIB_DIR/ticket-show.sh" "$@"
        return $?
    fi

    # Run the body with strict mode scoped to this function via a subshell.
    (
        set -euo pipefail

        # Unset git hook env vars so git commands target the correct repo.
        # Scoped to this subshell — does not leak to caller.
        unset GIT_DIR GIT_INDEX_FILE GIT_WORK_TREE GIT_COMMON_DIR 2>/dev/null || true

        local TRACKER_DIR
        if [ -n "${TICKETS_TRACKER_DIR:-}" ]; then
            TRACKER_DIR="$TICKETS_TRACKER_DIR"
        else
            local REPO_ROOT
            REPO_ROOT="${PROJECT_ROOT:-$(git rev-parse --show-toplevel)}"
            TRACKER_DIR="$REPO_ROOT/.tickets-tracker"
        fi

        _usage() {
            echo "Usage: ticket show [--format=llm] <ticket_id>" >&2
            return 1
        }

        local format="default"
        local ticket_id=""
        local arg
        for arg in "$@"; do
            case "$arg" in
                --format=llm)
                    format="llm"
                    ;;
                --format=*)
                    echo "Error: unsupported format '${arg#--format=}'. Supported: llm" >&2
                    return 1
                    ;;
                -*)
                    echo "Error: unknown option '$arg'" >&2
                    _usage
                    return 1
                    ;;
                *)
                    if [ -z "$ticket_id" ]; then
                        ticket_id="$arg"
                    fi
                    ;;
            esac
        done

        if [ -z "$ticket_id" ]; then
            _usage
            return 1
        fi

        if [ ! -d "$TRACKER_DIR/$ticket_id" ]; then
            echo "Error: Ticket '$ticket_id' not found" >&2
            return 1
        fi

        _TICKET_DIR="$TRACKER_DIR/$ticket_id" _TICKET_ID="$ticket_id" \
        _FORMAT="$format" _SCRIPT_DIR="$_TICKETLIB_DIR" python3 -c "
import sys, os, json
sys.path.insert(0, os.environ['_SCRIPT_DIR'])
from ticket_reducer import reduce_ticket

ticket_dir = os.environ['_TICKET_DIR']
ticket_id = os.environ['_TICKET_ID']
fmt = os.environ.get('_FORMAT', 'default')

state = reduce_ticket(ticket_dir)
if state is None:
    print(f'Error: ticket \"{ticket_id}\" has no CREATE or SNAPSHOT event', file=sys.stderr)
    sys.exit(1)
if state.get('status') in ('error', 'fsck_needed'):
    print(json.dumps(state, ensure_ascii=False))
    print(f'Error: ticket \"{ticket_id}\" has status \"{state[\"status\"]}\"', file=sys.stderr)
    sys.exit(1)

if fmt == 'llm':
    from ticket_reducer.llm_format import to_llm
    print(json.dumps(to_llm(state), ensure_ascii=False, separators=(',', ':')))
else:
    print(json.dumps(state, indent=2, ensure_ascii=False))
    alerts = state.get('bridge_alerts', [])
    unresolved = sum(1 for a in alerts if not a.get('resolved', False))
    if unresolved > 0:
        print(
            f'WARNING: ticket {ticket_id} has {unresolved} unresolved bridge alert(s).'
            ' Run: ticket bridge-status for details.',
            file=sys.stderr,
        )
"
    )
}
