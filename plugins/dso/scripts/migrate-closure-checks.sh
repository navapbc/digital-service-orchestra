#!/usr/bin/env bash
# migrate-closure-checks.sh
# Bulk migration: add ## Closure Checks section to epic and story tickets
# that lack it in their description. Wraps ticket-migrate-closure-checks-v1.sh
# per-ticket logic for bulk processing with batching, resume, and idempotency.
#
# Schema migration sentinel: v1.2.0
#
# Usage:
#   migrate-closure-checks.sh [--target <host-project-root>] [--dry-run]
#   audit-closure-checks-migration.sh --target <repo> | migrate-closure-checks.sh --target <repo>
#
# Flags:
#   --target <path>     Path to the host project root (default: git rev-parse --show-toplevel)
#   --dry-run           Show what would change without making any changes (read-only)
#
# Input modes:
#   stdin:              Read tab-separated audit lines (<id>\t<type>\t<status>\t<title>)
#                       from stdin (e.g., piped from audit-closure-checks-migration.sh).
#                       When stdin is not a TTY, processes only the listed ticket IDs.
#   scan mode:          When stdin is a TTY (interactive), scan all tickets via
#                       audit-closure-checks-migration.sh.
#
# Exit codes:
#   0 — All tickets processed successfully (including idempotent re-run)
#   1 — One or more ticket migrations failed (partial success)
#   2 — Fatal error (e.g., .tickets-tracker not found, arg parse error)
#
# Batch processing:
#   Processes tickets in batches of 25. Creates a per-session progress file at
#   /tmp/migrate-closure-checks.<session-id>.progress for resume semantics.
#   On resume (re-run), already-processed ticket IDs are read from the progress
#   file and skipped, allowing partial batch runs to continue from where they
#   left off.
#
# Idempotency:
#   Each ticket is checked for the v1.2.0 sentinel (## Closure Checks heading)
#   before processing. Already-migrated tickets are skipped with SKIPPED:<id>.

set -uo pipefail

# ── Self-location ─────────────────────────────────────────────────────────────
_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Parse arguments ───────────────────────────────────────────────────────────
_TARGET=""
_DRYRUN=0

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
        --dry-run)
            _DRYRUN=1
            shift
            ;;
        *)
            echo "Error: unknown argument '$1'" >&2
            exit 2
            ;;
    esac
done

# Resolve target (default: git rev-parse --show-toplevel from within script context)
if [ -z "$_TARGET" ]; then
    _TARGET="$(git rev-parse --show-toplevel)"
fi

# ── Validate ticket tracker ───────────────────────────────────────────────────
_TRACKER_DIR="$_TARGET/.tickets-tracker"  # tickets-boundary-ok

if [ ! -d "$_TRACKER_DIR" ]; then
    echo "Error: no .tickets-tracker at '$_TARGET'" >&2  # tickets-boundary-ok
    exit 2
fi

# ── Helper scripts ────────────────────────────────────────────────────────────
_AUDIT_SCRIPT="$_SCRIPT_DIR/audit-closure-checks-migration.sh"
_PER_TICKET_PY="$_SCRIPT_DIR/ticket-reducer.py"

# ── Per-session progress file ─────────────────────────────────────────────────
# Unique per invocation but stable across resume calls in the same shell session.
# Uses a fixed prefix so tests can locate it, combined with a content hash of
# the target path to keep separate repos from sharing a progress file.
_TARGET_HASH=$(printf '%s' "$_TARGET" | python3 -c "import sys, hashlib; print(hashlib.sha1(sys.stdin.buffer.read()).hexdigest()[:8])")
_SESSION_FILE=$(mktemp /tmp/migrate-closure-checks.XXXXXX)
# Rename to a deterministic name for resume semantics within the same session
_PROGRESS_FILE="/tmp/migrate-closure-checks.${_TARGET_HASH}.progress"

# Clean up the mktemp placeholder (we use _PROGRESS_FILE instead)
rm -f "$_SESSION_FILE"

# ── Collect ticket IDs to process ─────────────────────────────────────────────
# Collect lines from stdin if it is not a TTY; otherwise scan via audit script.
_TICKET_LINES=()

if [ -p /dev/stdin ]; then
    # stdin mode: read tab-separated audit lines (stdin is a pipe)
    while IFS= read -r _line; do
        [[ -z "$_line" ]] && continue
        _TICKET_LINES+=("$_line")
    done
else
    # Scan mode: run audit script to find all tickets needing migration
    if [ ! -f "$_AUDIT_SCRIPT" ]; then
        echo "Error: audit-closure-checks-migration.sh not found at '$_AUDIT_SCRIPT'" >&2
        exit 2
    fi
    _audit_exit=0
    _audit_output=$(bash "$_AUDIT_SCRIPT" --target "$_TARGET" 2>/dev/null) || _audit_exit=$?
    if [ "$_audit_exit" -eq 1 ]; then
        # All already migrated
        echo "INFO: All epics/stories already have ## Closure Checks — nothing to migrate."
        exit 0
    elif [ "$_audit_exit" -eq 2 ]; then
        echo "Error: audit script failed" >&2
        exit 2
    fi
    while IFS= read -r _line; do
        [[ -z "$_line" ]] && continue
        _TICKET_LINES+=("$_line")
    done <<< "$_audit_output"
fi

if [ "${#_TICKET_LINES[@]}" -eq 0 ]; then
    echo "INFO: No tickets to migrate."
    exit 0
fi

# ── Load previously-processed tickets (resume semantics) ─────────────────────
declare -A _ALREADY_PROCESSED=()
if [ -f "$_PROGRESS_FILE" ]; then
    while IFS= read -r _id; do
        [[ -z "$_id" ]] && continue
        _ALREADY_PROCESSED["$_id"]=1
    done < "$_PROGRESS_FILE"
    echo "INFO: Resuming — ${#_ALREADY_PROCESSED[@]} tickets already processed from previous session."
fi

# ── Python migration function (inline) ────────────────────────────────────────
# Shared migration logic: check sentinel + insert ## Closure Checks section.
# Returns: MIGRATED:<id>:<fname>, SKIPPED:<id>:already-has-section, or ERROR:<id>:<msg>
_migrate_ticket() {
    local ticket_id="$1"
    local dryrun="$2"
    local tracker_dir="$3"

    python3 - "$ticket_id" "$dryrun" "$tracker_dir" <<'PYEOF'
import json, os, re, sys, time, uuid

TICKET_ID = sys.argv[1]
DRYRUN = sys.argv[2] == "1"
TRACKER = sys.argv[3]
CLOSURE_HEADING = "## Closure Checks"
SUCCESS_CRITERIA_HEADING = "## Success Criteria"


def _get_current_description(tdir):
    """Return the most up-to-date description by reading all events in order."""
    description = None
    try:
        files = sorted(f for f in os.listdir(tdir)
                       if f.endswith('.json') and not f.startswith('.'))
    except OSError:
        return None
    for fn in files:
        try:
            with open(os.path.join(tdir, fn)) as f:
                ev = json.load(f)
        except (json.JSONDecodeError, OSError):
            continue
        etype = ev.get('event_type', '')
        data = ev.get('data') or {}
        if etype == 'CREATE':
            desc = data.get('description')
            if desc is not None:
                description = desc
        elif etype == 'EDIT':
            fields = data.get('fields') or {}
            desc = fields.get('description')
            if desc is not None:
                description = desc
        elif etype == 'SNAPSHOT':
            cs = data.get('compiled_state') or {}
            desc = cs.get('description')
            if desc is not None:
                description = desc
    return description


def _is_epic_or_story(tdir):
    """Return True if the ticket is an epic or story."""
    try:
        files = sorted(f for f in os.listdir(tdir)
                       if f.endswith('.json') and not f.startswith('.'))
    except OSError:
        return False
    for fn in files:
        try:
            with open(os.path.join(tdir, fn)) as f:
                ev = json.load(f)
        except (json.JSONDecodeError, OSError):
            continue
        data = ev.get('data') or {}
        etype = ev.get('event_type', '')
        tt = data.get('ticket_type')
        if tt in ('epic', 'story'):
            return True
        if etype == 'SNAPSHOT':
            cs = data.get('compiled_state') or {}
            tt2 = cs.get('ticket_type')
            if tt2 in ('epic', 'story'):
                return True
    return False


def _insert_closure_checks(description):
    """
    Insert ## Closure Checks after ## Success Criteria (if present),
    otherwise append at the end.
    """
    closure_section = "\n## Closure Checks\n\n"
    sc_idx = description.find(SUCCESS_CRITERIA_HEADING)
    if sc_idx != -1:
        rest = description[sc_idx + len(SUCCESS_CRITERIA_HEADING):]
        next_heading = re.search(r'(?m)^## ', rest)
        if next_heading:
            insert_pos = sc_idx + len(SUCCESS_CRITERIA_HEADING) + next_heading.start()
            return description[:insert_pos] + closure_section + description[insert_pos:]
        else:
            return description + closure_section
    else:
        return description + closure_section


def write_edit_event(tdir, new_description):
    ts = time.time_ns()
    u = str(uuid.uuid4())
    fname = f"{ts}-{u}-EDIT.json"
    fpath = os.path.join(tdir, fname)
    event = {
        "timestamp": ts,
        "uuid": u,
        "event_type": "EDIT",
        "env_id": "00000000-0000-4000-8000-migration002",
        "author": "migrate-closure-checks",
        "data": {"fields": {"description": new_description}},
    }
    with open(fpath, 'w', encoding='utf-8') as f:
        json.dump(event, f, ensure_ascii=False)
    return fname


tdir = os.path.join(TRACKER, TICKET_ID)
if not os.path.isdir(tdir):
    print(f"ERROR:{TICKET_ID}:ticket directory not found")
    sys.exit(0)

if not _is_epic_or_story(tdir):
    print(f"SKIPPED:{TICKET_ID}:not-epic-or-story")
    sys.exit(0)

description = _get_current_description(tdir)
if description is None:
    print(f"SKIPPED:{TICKET_ID}:no-description")
    sys.exit(0)

if CLOSURE_HEADING in description:
    print(f"SKIPPED:{TICKET_ID}:already-has-section")
    sys.exit(0)

new_description = _insert_closure_checks(description)

if DRYRUN:
    print(f"WOULD_WRITE:{TICKET_ID}")
    sys.exit(0)

try:
    fname = write_edit_event(tdir, new_description)
    print(f"WROTE:{TICKET_ID}:{fname}")
except OSError as e:
    print(f"ERROR:{TICKET_ID}:{e}")
PYEOF
}

# ── Process tickets in batches of 25 ─────────────────────────────────────────
_BATCH_SIZE=25
_total=${#_TICKET_LINES[@]}
_batch_num=0
_migrated=0
_skipped=0
_failed=0
_batch_failed=0

_i=0
while [ "$_i" -lt "$_total" ]; do
    _batch_num=$(( _batch_num + 1 ))
    _batch_end=$(( _i + _BATCH_SIZE ))
    if [ "$_batch_end" -gt "$_total" ]; then
        _batch_end="$_total"
    fi

    _batch_count=$(( _batch_end - _i ))
    echo "INFO: Processing batch $_batch_num (tickets $(( _i + 1 ))–$_batch_end of $_total)"

    _j="$_i"
    while [ "$_j" -lt "$_batch_end" ]; do
        _line="${_TICKET_LINES[$_j]}"
        # Extract ticket ID (first tab-separated field)
        _ticket_id="${_line%%$'\t'*}"
        # Also handle space-separated (trim leading/trailing spaces)
        _ticket_id="${_ticket_id// /}"

        _j=$(( _j + 1 ))

        [[ -z "$_ticket_id" ]] && continue

        # Check progress file (resume semantics)
        if [ "${_ALREADY_PROCESSED[$_ticket_id]+_}" = "_" ]; then
            echo "RESUME-SKIP: $_ticket_id (already processed in prior session)"
            _skipped=$(( _skipped + 1 ))
            continue
        fi

        # Run per-ticket migration
        _result=$(_migrate_ticket "$_ticket_id" "$_DRYRUN" "$_TRACKER_DIR") || true

        case "$_result" in
            WROTE:*)
                _rest="${_result#WROTE:}"
                _tid="${_rest%%:*}"
                _event_name="${_rest#*:}"
                # Commit the EDIT event to the tickets branch
                if [ "$_DRYRUN" = "0" ]; then
                    git -C "$_TRACKER_DIR" add "$_tid/$_event_name" 2>/dev/null && \
                        git -C "$_TRACKER_DIR" commit -m "migration: add ## Closure Checks section to $_tid" 2>/dev/null || \
                        git -C "$_TRACKER_DIR" reset 2>/dev/null || true
                fi
                echo "MIGRATED: $_ticket_id"
                _migrated=$(( _migrated + 1 ))
                # Record in progress file for resume semantics
                if [ "$_DRYRUN" = "0" ]; then
                    echo "$_ticket_id" >> "$_PROGRESS_FILE"
                fi
                ;;
            WOULD_WRITE:*)
                echo "DRY-RUN: $_ticket_id"
                _migrated=$(( _migrated + 1 ))
                ;;
            SKIPPED:*)
                _reason="${_result#SKIPPED:*:}"
                echo "SKIPPED: $_ticket_id ($_reason)"
                _skipped=$(( _skipped + 1 ))
                # Record skipped-already-has-section in progress file (idempotency)
                if [ "$_DRYRUN" = "0" ] && [[ "$_result" == *"already-has-section"* ]]; then
                    echo "$_ticket_id" >> "$_PROGRESS_FILE"
                fi
                ;;
            ERROR:*)
                _errmsg="${_result#ERROR:*:}"
                echo "ERROR: $_ticket_id — $_errmsg" >&2
                _failed=$(( _failed + 1 ))
                _batch_failed=$(( _batch_failed + 1 ))
                ;;
            *)
                # Unexpected output from python
                echo "ERROR: $_ticket_id — unexpected output: $_result" >&2
                _failed=$(( _failed + 1 ))
                _batch_failed=$(( _batch_failed + 1 ))
                ;;
        esac
    done

    echo "BATCH_COMPLETE: batch $_batch_num — migrated: $_migrated, skipped: $_skipped, failed: $_batch_failed"
    _batch_failed=0
    _i="$_batch_end"
done

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "Migration complete: $_migrated migrated, $_skipped skipped, $_failed failed"
if [ -f "$_PROGRESS_FILE" ]; then
    echo "Progress file: $_PROGRESS_FILE"
fi

# ── Exit code ─────────────────────────────────────────────────────────────────
if [ "$_failed" -gt 0 ]; then
    exit 1
fi
exit 0
