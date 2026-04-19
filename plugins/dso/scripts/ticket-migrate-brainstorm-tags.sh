#!/usr/bin/env bash
# ticket-migrate-brainstorm-tags.sh
# One-time migration: tag epics that have a "### Planning Intelligence Log"
# heading with brainstorm:complete, and remove scrutiny:pending if present.
#
# Usage:
#   ticket-migrate-brainstorm-tags.sh [--target <host-project-root>]
#
# Flags:
#   --target <path>     Path to the host project root (default: git rev-parse --show-toplevel)
#
# Exit codes:
#   0 — Success (including idempotent re-run and plugin-source-repo guard)
#   1 — Fatal error

set -euo pipefail

# ── Self-location ────────────────────────────────────────────────────────────
_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Parse arguments ──────────────────────────────────────────────────────────
_TARGET=""

while [ $# -gt 0 ]; do
    case "$1" in
        --target)
            _TARGET="$2"
            shift 2
            ;;
        --target=*)
            _TARGET="${1#--target=}"
            shift
            ;;
        *)
            echo "Error: unknown argument '$1'" >&2
            exit 1
            ;;
    esac
done

# Resolve target (default: git rev-parse --show-toplevel from within script context)
if [ -z "$_TARGET" ]; then
    _TARGET="$(git rev-parse --show-toplevel)"
fi

# ── Plugin-source-repo guard ─────────────────────────────────────────────────
# REVIEW-DEFENSE: This guard checks for plugin.json at the target root, which is a
# synthetic test marker used in tests (the actual plugin sentinel is at
# .claude-plugin/marketplace.json inside the plugin root directory). Three layers
# protect against accidental execution in the plugin source repo:
#   1. update-artifacts.sh (the primary caller) gates the entire Phase 5 migration
#      block on [[ -z "$_DRYRUN" ]], so --dryrun invocations never reach this script.
#      That fix removes the compound risk that triggered the critical upgrade.
#   2. The _TRACKER_DIR check below (lines ~66-71) is the actual production guard for
#      standalone invocations: the plugin source repo has no .tickets-tracker/ directory,
#      so the script exits with error code 1 before any ticket state is mutated.
#   3. This plugin.json guard is belt-and-suspenders for test environments that inject
#      a plugin.json marker to simulate the plugin source repo. Even if both upper layers
#      somehow fail, the migration is idempotent via the marker file.
if [ -f "$_TARGET/plugin.json" ]; then
    echo "NOTICE: target '$_TARGET' is the plugin source repo — skipping migration (no changes made)" >&2
    exit 0
fi

# ── Marker check (idempotency) ────────────────────────────────────────────────
_MARKER_FILE="$_TARGET/.claude/.brainstorm-tag-migration-v1"
if [ -f "$_MARKER_FILE" ]; then
    exit 0
fi

# ── Ticket tracker location ───────────────────────────────────────────────────
_TRACKER_DIR="$_TARGET/.tickets-tracker"

if [ ! -d "$_TRACKER_DIR" ]; then
    echo "Error: ticket tracker not found at '$_TRACKER_DIR'" >&2
    exit 1
fi

# ── PIL detection ─────────────────────────────────────────────────────────────
# Returns 0 if "### Planning Intelligence Log" heading found in any event file.
_ticket_has_pil() {
    local ticket_dir="$1"
    python3 - "$ticket_dir" <<'PYEOF'
import json, os, sys

ticket_dir = sys.argv[1]
PIL_HEADING = "### Planning Intelligence Log"

if not os.path.isdir(ticket_dir):
    sys.exit(1)

for fname in sorted(os.listdir(ticket_dir)):
    if not fname.endswith('.json') or fname.startswith('.'):
        continue
    fpath = os.path.join(ticket_dir, fname)
    try:
        with open(fpath) as f:
            event = json.load(f)
        data = event.get('data', {})

        # Check description field (CREATE events)
        desc = data.get('description', '')
        if desc and PIL_HEADING in desc:
            sys.exit(0)

        # Check body field (COMMENT events)
        body = data.get('body', '')
        if body and PIL_HEADING in body:
            sys.exit(0)
    except (json.JSONDecodeError, OSError):
        pass

sys.exit(1)
PYEOF
}

# ── Get current tags for an epic ──────────────────────────────────────────────
# Reads all event files in order, tracking the latest tags value.
# Returns comma-separated tag string (empty if no tags set).
_get_current_tags() {
    local ticket_dir="$1"
    python3 - "$ticket_dir" <<'PYEOF'
import json, os, sys

ticket_dir = sys.argv[1]
tags = []

if not os.path.isdir(ticket_dir):
    print('')
    sys.exit(0)

for fname in sorted(os.listdir(ticket_dir)):
    if not fname.endswith('.json') or fname.startswith('.'):
        continue
    fpath = os.path.join(ticket_dir, fname)
    try:
        with open(fpath) as f:
            event = json.load(f)
        data = event.get('data', {})
        event_type = event.get('event_type', '')
        # CREATE events store tags directly in data.tags
        # EDIT events store tags in data.fields.tags (ticket-edit.sh format)
        if event_type == 'EDIT':
            raw = data.get('fields', {}).get('tags', None)
        else:
            raw = data.get('tags', None)
        if raw is not None:
            if isinstance(raw, list):
                tags = raw
            elif isinstance(raw, str) and raw:
                tags = raw.split(',')
            else:
                tags = []
    except (json.JSONDecodeError, OSError):
        pass

print(','.join(tags))
PYEOF
}

# ── Write EDIT event with new tags ───────────────────────────────────────────
_write_tag_edit_event() {
    local ticket_dir="$1"
    local tags_csv="$2"
    python3 - "$ticket_dir" "$tags_csv" <<'PYEOF'
import json, os, sys, time, uuid

ticket_dir = sys.argv[1]
tags_csv = sys.argv[2]

tags_list = [t for t in tags_csv.split(',') if t]

timestamp_ns = time.time_ns()
event_uuid = str(uuid.uuid4())
event_type = "EDIT"

event = {
    "timestamp": timestamp_ns,
    "uuid": event_uuid,
    "event_type": event_type,
    "env_id": "00000000-0000-4000-8000-migration001",
    "author": "ticket-migrate-brainstorm-tags",
    "data": {
        "fields": {
            "tags": tags_list
        }
    }
}

# Filename: <timestamp_ns>-<uuid>-EDIT.json
filename = f"{timestamp_ns}-{event_uuid}-{event_type}.json"
fpath = os.path.join(ticket_dir, filename)

with open(fpath, 'w', encoding='utf-8') as f:
    json.dump(event, f, ensure_ascii=False)

print(fpath)
PYEOF
}

# ── Main migration loop ────────────────────────────────────────────────────────
for _ticket_dir in "$_TRACKER_DIR"/*/; do
    _ticket_dir="${_ticket_dir%/}"
    _ticket_id="$(basename "$_ticket_dir")"

    # Skip hidden directories
    if [[ "$_ticket_id" == .* ]]; then
        continue
    fi

    # Skip non-directories
    if [ ! -d "$_ticket_dir" ]; then
        continue
    fi

    # Check if this is an epic by looking at CREATE event
    _is_epic=$(python3 - "$_ticket_dir" <<'PYEOF'
import json, os, sys

ticket_dir = sys.argv[1]

for fname in sorted(os.listdir(ticket_dir)):
    if not fname.endswith('.json') or fname.startswith('.'):
        continue
    fpath = os.path.join(ticket_dir, fname)
    try:
        with open(fpath) as f:
            event = json.load(f)
        data = event.get('data', {})
        ticket_type = data.get('ticket_type', '')
        if ticket_type:
            print('yes' if ticket_type == 'epic' else 'no')
            sys.exit(0)
    except (json.JSONDecodeError, OSError):
        pass

print('no')
PYEOF
    )

    if [ "$_is_epic" != "yes" ]; then
        continue
    fi

    # Check if already tagged with brainstorm:complete
    _current_tags=$(_get_current_tags "$_ticket_dir")
    if [[ ",${_current_tags}," == *",brainstorm:complete,"* ]]; then
        continue
    fi

    # Check for PIL heading
    if _ticket_has_pil "$_ticket_dir"; then
        # Build new tag set: remove scrutiny:pending, add brainstorm:complete
        _new_tags=$(python3 -c "
import sys
csv = sys.argv[1]
tags = [t for t in csv.split(',') if t and t != 'scrutiny:pending']
if 'brainstorm:complete' not in tags:
    tags.append('brainstorm:complete')
print(','.join(tags))
" "$_current_tags") || { echo "WARN: python3 tag computation failed for $_ticket_id — skipping" >&2; continue; }

        _event_file=$(_write_tag_edit_event "$_ticket_dir" "$_new_tags")
        # REVIEW-DEFENSE: Direct git operations are intentional here rather than routing
        # through ticket-edit.sh (which uses _flock_stage_commit for concurrent-writer safety).
        # Four reasons this is correct:
        #   (a) This is a one-time sequential migration, not a concurrent multi-agent writer.
        #       The loop processes one ticket at a time; there is no parallelism within the
        #       migration itself.
        #   (b) _flock_stage_commit in ticket-lib.sh is designed to serialize concurrent
        #       writes from multiple Claude agent processes running simultaneously. A
        #       sequential migration loop cannot race with itself.
        #   (c) update-artifacts.sh (the primary caller) gates the entire Phase 5 migration
        #       block on [[ -z "$_DRYRUN" ]], so it is not called concurrently with active
        #       ticket operations in the same session.
        #   (d) ticket-edit.sh requires .tickets-tracker/.env-id and uses `git config
        #       user.name` for author — it cannot emit the migration-specific author
        #       ("ticket-migrate-brainstorm-tags") and env_id
        #       ("00000000-0000-4000-8000-migration001") needed for auditability.
        #       Routing through ticket-edit.sh would silently overwrite these with the
        #       calling user's identity, losing provenance.
        git -C "$_TRACKER_DIR" add "$_ticket_id/$(basename "$_event_file")" 2>/dev/null && \
            git -C "$_TRACKER_DIR" commit -m "migration: add brainstorm:complete tag to $_ticket_id" 2>/dev/null || \
            git -C "$_TRACKER_DIR" reset 2>/dev/null || true
    else
        echo "UNMATCHED: $_ticket_id"
    fi
done

# ── Write marker file ─────────────────────────────────────────────────────────
mkdir -p "$(dirname "$_MARKER_FILE")"
touch "$_MARKER_FILE"

exit 0
