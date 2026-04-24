#!/usr/bin/env bash
# ticket-edit.sh
# Append an EDIT event to a ticket and auto-commit it.
#
# Usage: ticket-edit.sh <ticket_id> [--title=VALUE] [--priority=VALUE] [--assignee=VALUE] [--ticket_type=VALUE] [--description=VALUE]
#   ticket_id: the ticket directory name (e.g., w21-ablv)
#   At least one --field=value pair is required.
#
# Ghost prevention: verifies CREATE or SNAPSHOT event exists before writing EDIT.
# Exits 0 on success, 1 on validation failure.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=${_PLUGIN_ROOT}/scripts/ticket-lib.sh
source "$SCRIPT_DIR/ticket-lib.sh"

REPO_ROOT="${PROJECT_ROOT:-$(git rev-parse --show-toplevel)}"
TRACKER_DIR="${TICKETS_TRACKER_DIR:-$REPO_ROOT/.tickets-tracker}"

# ── Usage ─────────────────────────────────────────────────────────────────────
_usage() {
    echo "Usage: ticket edit <ticket_id> [--title=VALUE] [--priority=VALUE] [--assignee=VALUE] [--ticket_type=VALUE] [--description=VALUE] [--tags=VALUE]" >&2
    echo "  ticket_id: ticket directory name" >&2
    echo "  At least one --field=value pair is required." >&2
    exit 1
}

# ── Allowed fields ────────────────────────────────────────────────────────────
ALLOWED_FIELDS="title priority assignee ticket_type description tags"

_is_allowed_field() {
    local field="$1"
    for f in $ALLOWED_FIELDS; do
        if [ "$f" = "$field" ]; then
            return 0
        fi
    done
    return 1
}

# ── Step 1: Parse arguments ──────────────────────────────────────────────────
if [ $# -lt 2 ]; then
    _usage
fi

ticket_id="$1"
shift

# Parse --field=value and --field value pairs
# Use indexed array (bash 3.2 compatible; avoid declare -A which requires bash 4+)
_parsed_pairs=()
while [ $# -gt 0 ]; do
    arg="$1"
    case "$arg" in
        --*=*)
            field_name="${arg%%=*}"
            field_name="${field_name#--}"
            field_value="${arg#*=}"
            if ! _is_allowed_field "$field_name"; then
                echo "Error: unknown field '$field_name'. Allowed: $ALLOWED_FIELDS" >&2
                exit 1
            fi
            _parsed_pairs+=("$field_name=$field_value")
            shift
            ;;
        --*)
            field_name="${arg#--}"
            if ! _is_allowed_field "$field_name"; then
                echo "Error: unknown field '$field_name'. Allowed: $ALLOWED_FIELDS" >&2
                exit 1
            fi
            if [ $# -lt 2 ]; then
                echo "Error: --$field_name requires a value" >&2
                exit 1
            fi
            shift
            _parsed_pairs+=("$field_name=$1")
            shift
            ;;
        *)
            echo "Error: unexpected argument '$arg'" >&2
            exit 1
            ;;
    esac
done

# ── Step 2: Validate at least one field ──────────────────────────────────────
if [ ${#_parsed_pairs[@]} -eq 0 ]; then
    echo "Error: at least one --field=value pair is required" >&2
    exit 1
fi

# ── Validate ticket system is initialized ─────────────────────────────────────
if [ ! -f "$TRACKER_DIR/.env-id" ]; then
    echo "Error: ticket system not initialized. Run 'ticket init' first." >&2
    exit 1
fi

# ── Step 3: Ghost check ─────────────────────────────────────────────────────
if [ ! -d "$TRACKER_DIR/$ticket_id" ]; then
    echo "Error: ticket '$ticket_id' does not exist" >&2
    exit 1
fi

if ! find "$TRACKER_DIR/$ticket_id" -maxdepth 1 \( -name '*-CREATE.json' -o -name '*-SNAPSHOT.json' \) ! -name '.*' 2>/dev/null | grep -q .; then
    echo "Error: ticket $ticket_id has no CREATE or SNAPSHOT event" >&2
    exit 1
fi

# ── Step 4: Build EDIT event JSON via python3 ────────────────────────────────
env_id=$(cat "$TRACKER_DIR/.env-id")
author=$(git config user.name 2>/dev/null || echo "Unknown")

temp_event=$(mktemp "$TRACKER_DIR/.tmp-edit-XXXXXX")

# Python3 handles field parsing, unicode conversion, JSON building, and event writing.
# _parsed_pairs elements are "key=value"; partition('=') splits on the FIRST '=' only
# so values that themselves contain '=' are preserved intact.
python3 -c "
import json, sys, time, uuid
args     = sys.argv[1:]
env_id   = args[0]
author   = args[1]
out_path = args[-1]
fields = {}
for pair in args[2:-1]:
    key, _, val = pair.partition('=')
    fields[key] = val
if 'title' in fields:
    fields['title'] = fields['title'].replace('\\u2192', '->')
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
    exit 1
}

# ── Step 5: Write and commit via ticket-lib.sh ──────────────────────────────
write_commit_event "$ticket_id" "$temp_event" || {
    rm -f "$temp_event"
    echo "Error: failed to write and commit EDIT event" >&2
    exit 1
}

# Clean up temp file
rm -f "$temp_event"

exit 0
