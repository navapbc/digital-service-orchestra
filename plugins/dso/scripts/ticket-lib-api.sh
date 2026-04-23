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

# ── ticket_list ──────────────────────────────────────────────────────────────
# In-process replacement for ticket-list.sh.
ticket_list() {
    # Legacy escape hatch: DSO_TICKET_LEGACY=1 delegates to the original script.
    if [ "${DSO_TICKET_LEGACY:-0}" = "1" ]; then
        bash "$_TICKETLIB_DIR/ticket-list.sh" "$@"
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
        elif [ -n "${GIT_DIR:-}" ]; then
            local REPO_ROOT
            REPO_ROOT="$(dirname "$GIT_DIR")"
            TRACKER_DIR="$REPO_ROOT/.tickets-tracker"
        else
            local REPO_ROOT
            REPO_ROOT="${PROJECT_ROOT:-$(git rev-parse --show-toplevel)}"
            TRACKER_DIR="$REPO_ROOT/.tickets-tracker"
        fi

        local format="default"
        local include_archived=""
        local filter_type=""
        local filter_status=""
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
                --include-archived)
                    include_archived="true"
                    ;;
                --type=*)
                    filter_type="${arg#--type=}"
                    ;;
                --status=*)
                    filter_status="${arg#--status=}"
                    ;;
                --parent=*)
                    # --parent filter: not implemented in ticket-list.sh, silently ignore
                    ;;
                --help|-h)
                    echo "Usage: ticket list [--format=llm] [--include-archived] [--type=<type>] [--status=<status>]" >&2
                    return 0
                    ;;
                -*)
                    echo "Error: unknown option '$arg'" >&2
                    return 1
                    ;;
            esac
        done

        if [ ! -d "$TRACKER_DIR" ]; then
            echo "Error: ticket system not initialized. Run 'ticket init' first." >&2
            return 1
        fi

        if [ "$format" = "llm" ]; then
            _TRACKER_DIR="$TRACKER_DIR" _INCLUDE_ARCHIVED="$include_archived" \
            _TYPE_FILTER="$filter_type" _STATUS_FILTER="$filter_status" \
            _SCRIPT_DIR="$_TICKETLIB_DIR" python3 -c "
import sys, os, json
sys.path.insert(0, os.environ['_SCRIPT_DIR'])
from ticket_reducer import reduce_all_tickets
from ticket_reducer.llm_format import to_llm

tracker_dir = os.environ['_TRACKER_DIR']
include_archived = os.environ.get('_INCLUDE_ARCHIVED', '') == 'true'
type_filter = os.environ.get('_TYPE_FILTER', '')
status_filter = os.environ.get('_STATUS_FILTER', '')

results = reduce_all_tickets(tracker_dir, exclude_archived=not include_archived)
if status_filter not in ('error', 'fsck_needed'):
    results = [t for t in results if t.get('status') not in ('error', 'fsck_needed')]
if type_filter:
    results = [t for t in results if t.get('ticket_type') == type_filter]
if status_filter:
    status_values = {s.strip() for s in status_filter.split(',')}
    results = [t for t in results if t.get('status') in status_values]
for t in results:
    print(json.dumps(to_llm(t), ensure_ascii=False, separators=(',', ':')))
"
        else
            _TRACKER_DIR="$TRACKER_DIR" _INCLUDE_ARCHIVED="$include_archived" \
            _TYPE_FILTER="$filter_type" _STATUS_FILTER="$filter_status" \
            _SCRIPT_DIR="$_TICKETLIB_DIR" python3 -c "
import sys, os, json
sys.path.insert(0, os.environ['_SCRIPT_DIR'])
from ticket_reducer import reduce_all_tickets

tracker_dir = os.environ['_TRACKER_DIR']
include_archived = os.environ.get('_INCLUDE_ARCHIVED', '') == 'true'
type_filter = os.environ.get('_TYPE_FILTER', '')
status_filter = os.environ.get('_STATUS_FILTER', '')

results = reduce_all_tickets(tracker_dir, exclude_archived=not include_archived)
if status_filter not in ('error', 'fsck_needed'):
    results = [t for t in results if t.get('status') not in ('error', 'fsck_needed')]
if type_filter:
    results = [t for t in results if t.get('ticket_type') == type_filter]
if status_filter:
    status_values = {s.strip() for s in status_filter.split(',')}
    results = [t for t in results if t.get('status') in status_values]
print(json.dumps(results, ensure_ascii=False))

alerted_count = sum(
    1 for t in results
    if any(not a.get('resolved', False) for a in t.get('bridge_alerts', []))
)
if alerted_count > 0:
    print(
        f'WARNING: {alerted_count} ticket(s) have unresolved bridge alerts. Run: ticket bridge-status for details.',
        file=sys.stderr,
    )
"
        fi
    )
}

# ── ticket_create ─────────────────────────────────────────────────────────────
# In-process replacement for ticket-create.sh.
ticket_create() {
    # Legacy escape hatch: DSO_TICKET_LEGACY=1 delegates to the original script.
    if [ "${DSO_TICKET_LEGACY:-0}" = "1" ]; then
        bash "$_TICKETLIB_DIR/ticket-create.sh" "$@"
        return $?
    fi

    # Run the body with strict mode scoped to this subshell.
    (
        set -euo pipefail

        # Unset git hook env vars so git commands target the correct repo.
        unset GIT_DIR GIT_INDEX_FILE GIT_WORK_TREE GIT_COMMON_DIR 2>/dev/null || true

        # Source ticket-lib.sh for write_commit_event and ticket_read_status.
        # shellcheck source=/dev/null
        source "$_TICKETLIB_DIR/ticket-lib.sh"

        local TRACKER_DIR
        if [ -n "${TICKETS_TRACKER_DIR:-}" ]; then
            TRACKER_DIR="$TICKETS_TRACKER_DIR"
        else
            local REPO_ROOT
            REPO_ROOT="${PROJECT_ROOT:-$(git rev-parse --show-toplevel)}"
            TRACKER_DIR="$REPO_ROOT/.tickets-tracker"
        fi

        _usage() {
            echo "Usage: ticket create <ticket_type> <title> [--parent <id>] [--priority <n>] [--assignee <name>] [--description <text>] [--tags <tag1,tag2>]" >&2
            echo "  ticket_type: bug | epic | story | task" >&2
            echo "  --priority, -p: 0-4 (0=critical, 4=backlog; default: 2)" >&2
            return 1
        }

        if [ $# -lt 2 ]; then
            _usage
            return 1
        fi

        local ticket_type="$1"
        # shellcheck disable=SC2030  # local to this subshell; intentional scope
        local title="$2"
        shift 2

        local parent_id=""
        local priority="2"
        local assignee=""
        local description=""
        local tags=""
        while [ $# -gt 0 ]; do
            case "$1" in
                --parent)
                    parent_id="$2"
                    shift 2
                    ;;
                --parent=*)
                    parent_id="${1#--parent=}"
                    shift
                    ;;
                --priority)
                    priority="$2"
                    shift 2
                    ;;
                --priority=*)
                    priority="${1#--priority=}"
                    shift
                    ;;
                -p)
                    priority="$2"
                    shift 2
                    ;;
                --assignee)
                    assignee="$2"
                    shift 2
                    ;;
                --assignee=*)
                    assignee="${1#--assignee=}"
                    shift
                    ;;
                --description)
                    description="$2"
                    shift 2
                    ;;
                --description=*)
                    description="${1#--description=}"
                    shift
                    ;;
                -d)
                    description="$2"
                    shift 2
                    ;;
                --tags)
                    tags="$2"
                    shift 2
                    ;;
                --tags=*)
                    tags="${1#--tags=}"
                    shift
                    ;;
                *)
                    # Positional: treat as parent_id (backward-compatible)
                    parent_id="$1"
                    shift
                    ;;
            esac
        done

        # Default assignee to git user.name if not provided
        if [ -z "$assignee" ]; then
            assignee=$(git config user.name 2>/dev/null || echo "")
        fi

        # Validate ticket_type
        case "$ticket_type" in
            bug|epic|story|task) ;;
            *)
                echo "Error: invalid ticket type '$ticket_type'. Must be one of: bug, epic, story, task" >&2
                return 1
                ;;
        esac

        # Validate title is non-empty
        if [ -z "$title" ]; then
            echo "Error: title must be non-empty" >&2
            return 1
        fi

        # Validate title length <= 255 chars
        if [ "${#title}" -gt 255 ]; then
            echo "Error: title exceeds 255 characters (${#title} chars)" >&2
            return 1
        fi

        # Validate priority is 0-4
        case "$priority" in
            0|1|2|3|4) ;;
            *)
                echo "Error: invalid priority '$priority'. Must be 0-4" >&2
                return 1
                ;;
        esac

        # Unicode arrow conversion (U+2192 -> ASCII ->)
        title=$(python3 -c "import sys; print(sys.argv[1].replace('\u2192', '->'))" "$title")

        # Validate ticket system is initialized
        if [ ! -f "$TRACKER_DIR/.env-id" ]; then
            echo "Error: ticket system not initialized. Run 'ticket init' first." >&2
            return 1
        fi

        # Validate parent_id exists if provided
        if [ -n "$parent_id" ]; then
            if [ ! -d "$TRACKER_DIR/$parent_id" ]; then
                echo "Error: parent ticket '$parent_id' does not exist" >&2
                return 1
            fi
            if ! find "$TRACKER_DIR/$parent_id" -maxdepth 1 \( -name '*-CREATE.json' -o -name '*-SNAPSHOT.json' \) ! -name '.*' 2>/dev/null | grep -q .; then
                echo "Error: parent ticket '$parent_id' has no CREATE or SNAPSHOT event" >&2
                return 1
            fi
            local parent_status
            parent_status=$(ticket_read_status "$TRACKER_DIR" "$parent_id") || {
                echo "Error: could not read status for parent ticket '$parent_id'" >&2
                return 1
            }
            if [ "$parent_status" = "closed" ]; then
                echo "Error: cannot create child of closed ticket '$parent_id'. Reopen the parent first with: ticket transition $parent_id closed open" >&2
                return 1
            fi
        fi

        # Generate ticket ID and event metadata
        local env_id
        env_id=$(cat "$TRACKER_DIR/.env-id")
        local author
        author=$(git config user.name 2>/dev/null || echo "Unknown")

        local event_meta ticket_id event_uuid timestamp
        event_meta=$(python3 -c "
import uuid, time
u = str(uuid.uuid4()).replace('-', '')
ticket_id = u[:4] + '-' + u[4:8]
event_uuid = str(uuid.uuid4())
timestamp = time.time_ns()
print(ticket_id)
print(event_uuid)
print(timestamp)
")
        ticket_id=$(echo "$event_meta" | sed -n '1p')
        event_uuid=$(echo "$event_meta" | sed -n '2p')
        timestamp=$(echo "$event_meta" | sed -n '3p')

        # Build CREATE event JSON via python3
        local temp_event desc_file
        temp_event=$(mktemp "$TRACKER_DIR/.tmp-create-XXXXXX")
        desc_file=$(mktemp "$TRACKER_DIR/.tmp-desc-XXXXXX")
        # shellcheck disable=SC2064
        trap "rm -f '$temp_event' '$desc_file'" EXIT
        printf '%s' "$description" > "$desc_file"

        python3 -c "
import json, sys

tags_str = sys.argv[10]
tags_list = [t.strip() for t in tags_str.split(',') if t.strip()] if tags_str else []

with open(sys.argv[9], 'r', encoding='utf-8') as df:
    description = df.read()

data = {
    'ticket_type': sys.argv[5],
    'title': sys.argv[6],
    'parent_id': sys.argv[7] if sys.argv[7] else '',
    'description': description,
    'tags': tags_list
}
if sys.argv[8]:
    data['priority'] = int(sys.argv[8])

assignee_arg = sys.argv[11] if len(sys.argv) > 11 else ''
if assignee_arg:
    data['assignee'] = assignee_arg

event = {
    'timestamp': int(sys.argv[1]),
    'uuid': sys.argv[2],
    'event_type': 'CREATE',
    'env_id': sys.argv[3],
    'author': sys.argv[4],
    'data': data
}

with open(sys.argv[12], 'w', encoding='utf-8') as f:
    json.dump(event, f, ensure_ascii=False)
" "$timestamp" "$event_uuid" "$env_id" "$author" "$ticket_type" "$title" "$parent_id" "$priority" "$desc_file" "$tags" "$assignee" "$temp_event" || {
            rm -f "$temp_event" "$desc_file"
            echo "Error: failed to build CREATE event JSON" >&2
            return 1
        }
        rm -f "$desc_file"

        # Write and commit via ticket-lib.sh
        write_commit_event "$ticket_id" "$temp_event" || {
            rm -f "$temp_event"
            echo "Error: failed to write and commit CREATE event" >&2
            return 1
        }

        rm -f "$temp_event"

        # Output ticket ID
        echo "$ticket_id"
    )
}

# ── ticket_comment ────────────────────────────────────────────────────────────
# In-process replacement for ticket-comment.sh.
ticket_comment() {
    # Legacy escape hatch: DSO_TICKET_LEGACY=1 delegates to the original script.
    if [ "${DSO_TICKET_LEGACY:-0}" = "1" ]; then
        bash "$_TICKETLIB_DIR/ticket-comment.sh" "$@"
        return $?
    fi

    # Run the body with strict mode scoped to this function via a subshell.
    (
        set -euo pipefail

        # Unset git hook env vars so git commands target the correct repo.
        # Scoped to this subshell — does not leak to caller.
        unset GIT_DIR GIT_INDEX_FILE GIT_WORK_TREE GIT_COMMON_DIR 2>/dev/null || true

        # Source ticket-lib.sh to get write_commit_event.
        # shellcheck source=/dev/null
        source "$_TICKETLIB_DIR/ticket-lib.sh"

        local TRACKER_DIR
        if [ -n "${TICKETS_TRACKER_DIR:-}" ]; then
            TRACKER_DIR="$TICKETS_TRACKER_DIR"
        else
            local REPO_ROOT
            REPO_ROOT="${PROJECT_ROOT:-$(git rev-parse --show-toplevel)}"
            TRACKER_DIR="$REPO_ROOT/.tickets-tracker"
        fi

        if [ $# -lt 2 ]; then
            echo "Usage: ticket comment <ticket_id> <body>" >&2
            return 1
        fi

        local ticket_id="$1"
        local body="$2"

        if [ -z "$ticket_id" ]; then
            echo "Error: ticket_id must be non-empty" >&2
            return 1
        fi

        if [ -z "$body" ]; then
            echo "Error: comment body must be non-empty" >&2
            return 1
        fi

        # Ghost check: ticket directory must exist with CREATE or SNAPSHOT event.
        if [ ! -d "$TRACKER_DIR/$ticket_id" ]; then
            echo "Error: ticket '$ticket_id' does not exist" >&2
            return 1
        fi

        if ! find "$TRACKER_DIR/$ticket_id" -maxdepth 1 \( -name '*-CREATE.json' -o -name '*-SNAPSHOT.json' \) ! -name '.*' 2>/dev/null | grep -q .; then
            echo "Error: ticket $ticket_id has no CREATE or SNAPSHOT event" >&2
            return 1
        fi

        local env_id
        env_id=$(cat "$TRACKER_DIR/.env-id")
        local author
        author=$(git config user.name 2>/dev/null || echo "Unknown")

        local temp_event body_file
        temp_event=$(mktemp "$TRACKER_DIR/.tmp-comment-XXXXXX")
        # Write body to temp file to avoid ARG_MAX limits on large payloads.
        body_file=$(mktemp "$TRACKER_DIR/.tmp-body-XXXXXX")
        # shellcheck disable=SC2064
        trap "rm -f '$temp_event' '$body_file'" EXIT
        printf '%s' "$body" > "$body_file"

        python3 -c "
import json, sys, time, uuid

with open(sys.argv[3], 'r', encoding='utf-8') as bf:
    body = bf.read()

event = {
    'timestamp': time.time_ns(),
    'uuid': str(uuid.uuid4()),
    'event_type': 'COMMENT',
    'env_id': sys.argv[1],
    'author': sys.argv[2],
    'data': {
        'body': body
    }
}

with open(sys.argv[4], 'w', encoding='utf-8') as f:
    json.dump(event, f, ensure_ascii=False)
" "$env_id" "$author" "$body_file" "$temp_event" || {
            rm -f "$temp_event" "$body_file"
            echo "Error: failed to build COMMENT event JSON" >&2
            return 1
        }
        rm -f "$body_file"

        write_commit_event "$ticket_id" "$temp_event" || {
            rm -f "$temp_event"
            echo "Error: failed to write and commit COMMENT event" >&2
            return 1
        }

        rm -f "$temp_event"
    )
}

# ── ticket_tag ────────────────────────────────────────────────────────────────
# In-process replacement for ticket-tag.sh.
ticket_tag() {
    if [ "${DSO_TICKET_LEGACY:-0}" = "1" ]; then
        bash "$_TICKETLIB_DIR/ticket-tag.sh" "$@"
        return $?
    fi

    (
        set -euo pipefail
        unset GIT_DIR GIT_INDEX_FILE GIT_WORK_TREE GIT_COMMON_DIR 2>/dev/null || true

        # shellcheck source=/dev/null
        source "$_TICKETLIB_DIR/ticket-lib.sh"

        if [ $# -lt 2 ]; then
            echo "Usage: ticket tag <ticket_id> <tag>" >&2
            return 1
        fi

        local ticket_id="$1"
        local tag="$2"

        if [ -z "$ticket_id" ] || [ -z "$tag" ]; then
            echo "Error: ticket_id and tag must be non-empty" >&2
            return 1
        fi

        _tag_add_checked "$ticket_id" "$tag"
    )
}

# ── ticket_untag ──────────────────────────────────────────────────────────────
# In-process replacement for ticket-untag.sh.
ticket_untag() {
    if [ "${DSO_TICKET_LEGACY:-0}" = "1" ]; then
        bash "$_TICKETLIB_DIR/ticket-untag.sh" "$@"
        return $?
    fi

    (
        set -euo pipefail
        unset GIT_DIR GIT_INDEX_FILE GIT_WORK_TREE GIT_COMMON_DIR 2>/dev/null || true

        # shellcheck source=/dev/null
        source "$_TICKETLIB_DIR/ticket-lib.sh"

        if [ $# -lt 2 ]; then
            echo "Usage: ticket untag <ticket_id> <tag>" >&2
            return 1
        fi

        local ticket_id="$1"
        local tag="$2"

        if [ -z "$ticket_id" ] || [ -z "$tag" ]; then
            echo "Error: ticket_id and tag must be non-empty" >&2
            return 1
        fi

        _tag_remove "$ticket_id" "$tag"
    )
}

# ── ticket_edit ───────────────────────────────────────────────────────────────
# In-process replacement for ticket-edit.sh.
ticket_edit() {
    if [ "${DSO_TICKET_LEGACY:-0}" = "1" ]; then
        bash "$_TICKETLIB_DIR/ticket-edit.sh" "$@"
        return $?
    fi

    (
        set -euo pipefail
        unset GIT_DIR GIT_INDEX_FILE GIT_WORK_TREE GIT_COMMON_DIR 2>/dev/null || true

        # shellcheck source=/dev/null
        source "$_TICKETLIB_DIR/ticket-lib.sh"

        local TRACKER_DIR
        if [ -n "${TICKETS_TRACKER_DIR:-}" ]; then
            TRACKER_DIR="$TICKETS_TRACKER_DIR"
        else
            local REPO_ROOT
            REPO_ROOT="${PROJECT_ROOT:-$(git rev-parse --show-toplevel)}"
            TRACKER_DIR="$REPO_ROOT/.tickets-tracker"
        fi

        if [ $# -lt 2 ]; then
            echo "Usage: ticket edit <ticket_id> [--title=VALUE] [--priority=VALUE] [--assignee=VALUE] [--ticket_type=VALUE] [--description=VALUE] [--tags=VALUE]" >&2
            return 1
        fi

        local ticket_id="$1"
        shift

        local ALLOWED_FIELDS="title priority assignee ticket_type description tags"

        _is_allowed_field_edit() {
            local field="$1"
            local f
            for f in $ALLOWED_FIELDS; do
                if [ "$f" = "$field" ]; then
                    return 0
                fi
            done
            return 1
        }

        # Parse --field=value and --field value pairs
        # Indexed array (bash 3.2 compatible; avoid declare -A which requires bash 4+)
        local _parsed_pairs
        _parsed_pairs=()
        while [ $# -gt 0 ]; do
            local arg="$1"
            case "$arg" in
                --*=*)
                    local field_name="${arg%%=*}"
                    field_name="${field_name#--}"
                    local field_value="${arg#*=}"
                    if ! _is_allowed_field_edit "$field_name"; then
                        echo "Error: unknown field '$field_name'. Allowed: $ALLOWED_FIELDS" >&2
                        return 1
                    fi
                    _parsed_pairs+=("$field_name=$field_value")
                    shift
                    ;;
                --*)
                    local field_name="${arg#--}"
                    if ! _is_allowed_field_edit "$field_name"; then
                        echo "Error: unknown field '$field_name'. Allowed: $ALLOWED_FIELDS" >&2
                        return 1
                    fi
                    if [ $# -lt 2 ]; then
                        echo "Error: --$field_name requires a value" >&2
                        return 1
                    fi
                    shift
                    _parsed_pairs+=("$field_name=$1")
                    shift
                    ;;
                *)
                    echo "Error: unexpected argument '$arg'" >&2
                    return 1
                    ;;
            esac
        done

        if [ ${#_parsed_pairs[@]} -eq 0 ]; then
            echo "Error: at least one --field=value pair is required" >&2
            return 1
        fi

        if [ ! -f "$TRACKER_DIR/.env-id" ]; then
            echo "Error: ticket system not initialized. Run 'ticket init' first." >&2
            return 1
        fi

        if [ ! -d "$TRACKER_DIR/$ticket_id" ]; then
            echo "Error: ticket '$ticket_id' does not exist" >&2
            return 1
        fi

        if ! find "$TRACKER_DIR/$ticket_id" -maxdepth 1 \( -name '*-CREATE.json' -o -name '*-SNAPSHOT.json' \) ! -name '.*' 2>/dev/null | grep -q .; then
            echo "Error: ticket $ticket_id has no CREATE or SNAPSHOT event" >&2
            return 1
        fi

        local env_id
        env_id=$(cat "$TRACKER_DIR/.env-id")
        local author
        author=$(git config user.name 2>/dev/null || echo "Unknown")

        local temp_event
        temp_event=$(mktemp "$TRACKER_DIR/.tmp-edit-XXXXXX")
        # shellcheck disable=SC2064
        trap "rm -f '$temp_event'" EXIT

        # Delegate field parsing, unicode conversion, JSON building, and event
        # writing to python3 — consistent with sibling functions (ticket_create,
        # ticket_comment, ticket_transition). Pairs are passed as positional argv
        # ("key=value") so no bash 4+ associative-array syntax is needed.
        python3 -c "
import json, sys, time, uuid

args     = sys.argv[1:]
env_id   = args[0]
author   = args[1]
out_path = args[-1]

fields = {}
for pair in args[2:-1]:
    # partition splits on the FIRST '=' only; values may safely contain '='
    key, _, val = pair.partition('=')
    fields[key] = val

if 'title' in fields:
    fields['title'] = fields['title'].replace('\u2192', '->')

if 'priority' in fields and fields['priority'].lstrip('-').isdigit():
    fields['priority'] = int(fields['priority'])

event = {
    'timestamp': time.time_ns(),
    'uuid': str(uuid.uuid4()),
    'event_type': 'EDIT',
    'env_id': env_id,
    'author': author,
    'data': {'fields': fields}
}

with open(out_path, 'w', encoding='utf-8') as f:
    json.dump(event, f, ensure_ascii=False)
" "$env_id" "$author" "${_parsed_pairs[@]}" "$temp_event" || {
            rm -f "$temp_event"
            echo "Error: failed to build EDIT event JSON" >&2
            return 1
        }

        write_commit_event "$ticket_id" "$temp_event" || {
            rm -f "$temp_event"
            echo "Error: failed to write and commit EDIT event" >&2
            return 1
        }

        rm -f "$temp_event"
    )
}

# ── ticket_link ───────────────────────────────────────────────────────────────
# In-process replacement for the `ticket link` dispatcher case.
# Thin wrapper — delegates to ticket-graph.py for cycle detection.
ticket_link() {
    if [ "${DSO_TICKET_LEGACY:-0}" = "1" ]; then
        bash "$_TICKETLIB_DIR/ticket-link.sh" link "$@"
        return $?
    fi

    (
        set -euo pipefail
        unset GIT_DIR GIT_INDEX_FILE GIT_WORK_TREE GIT_COMMON_DIR 2>/dev/null || true

        if [ $# -lt 3 ]; then
            echo "Usage: ticket link <id1> <id2> <relation>" >&2
            return 1
        fi

        # Relation validation is delegated to ticket-graph.py (single source of truth)
        # to avoid drift if new relation types are added.
        python3 "$_TICKETLIB_DIR/ticket-graph.py" --link "$@"
    )
}

# ── ticket_transition ─────────────────────────────────────────────────────────
# In-process replacement for ticket-transition.sh.
# Thin wrapper: reads current status, validates, writes STATUS event via python3.
# Does NOT replicate epic-close logic, unblock detection, or compact-on-close.
ticket_transition() {
    # Thin wrapper: delegate to ticket-transition.sh to preserve unblock logic,
    # open-children guard, epic-close reminder, and flock-based concurrency.
    # Tracked for future in-process optimization in 161e-b2b4.
    bash "$_TICKETLIB_DIR/ticket-transition.sh" "$@"
    return $?
}

