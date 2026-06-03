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

set -euo pipefail

# ── Self-location ─────────────────────────────────────────────────────────────
_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Parse arguments ───────────────────────────────────────────────────────────
_TARGET=""
_DRYRUN=0
_CLASSIFY=0

while [ $# -gt 0 ]; do
    case "$1" in
        --target)
            if [ $# -lt 2 ]; then echo "Error: --target requires a value" >&2; exit 2; fi
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
        --classify)
            # Phase 2 classifier pass — see story ad70-f38a-7684-4e00.
            # Augments the structural Phase 1 migration with a haiku classifier
            # pass per item, per-item ack flow, and audit comment write.
            # Estimated cost per --classify run: at ~12 items per epic and ~80
            # brainstorm:complete-tagged epics, ~960 haiku dispatches total.
            _CLASSIFY=1
            shift
            ;;
        *)
            echo "Error: unknown argument '$1'" >&2
            exit 2
            ;;
    esac
done

# ── Classify-mode state ───────────────────────────────────────────────────────
# Migration run identifier (recorded in every audit comment for cross-ticket
# correlation of one classify run).
_MIGRATION_RUN_ID=""
_CLASSIFIER_BUDGET=25  # DD5: 25-item batch cap (cumulative across the session)
_CLASSIFIER_CONSUMED=0
_CLASSIFIER_HELPER=""
# Epic-count cap for --classify mode: prevents unbounded loops under auto-approve.
# Override via DSO_CLASSIFY_MAX_EPICS env var.
_CLASSIFY_MAX_EPICS="${DSO_CLASSIFY_MAX_EPICS:-20}"
# Wall-time guard for --classify mode: breaks cleanly if elapsed time exceeds limit.
# Override via DSO_CLASSIFY_WALL_TIME_SECS env var.
_CLASSIFY_WALL_TIME_SECS="${DSO_CLASSIFY_WALL_TIME_SECS:-3600}"
if [ "$_CLASSIFY" = "1" ]; then
    _MIGRATION_RUN_ID="$(python3 -c 'import uuid; print(uuid.uuid4())' 2>/dev/null)"
    if [ -z "$_MIGRATION_RUN_ID" ]; then
        echo "Error: could not generate migration_run_id (python3 + uuid required)" >&2
        exit 2
    fi
    _CLASSIFIER_HELPER="$_SCRIPT_DIR/closure-checks-classifier-pass.sh"
    if [ ! -x "$_CLASSIFIER_HELPER" ]; then
        echo "Error: --classify requires closure-checks-classifier-pass.sh at '$_CLASSIFIER_HELPER'" >&2
        exit 2
    fi
fi

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
# ── Per-session progress file ─────────────────────────────────────────────────
# Stable across resume calls — uses a hash of the target path so separate repos
# don't share a progress file.
_TARGET_HASH=$(printf '%s' "$_TARGET" | python3 -c "import sys, hashlib; print(hashlib.sha1(sys.stdin.buffer.read()).hexdigest()[:8])")
_PROGRESS_FILE="/tmp/migrate-closure-checks.${_TARGET_HASH}.progress"

# ── Collect ticket IDs to process ─────────────────────────────────────────────
# Collect lines from stdin if it is not a TTY; otherwise scan via audit script.
_TICKET_LINES=()

if [ -p /dev/stdin ] || { [ -f /dev/stdin ] && [ -s /dev/stdin ]; }; then
    # stdin mode: read tab-separated audit lines (stdin is a pipe)
    while IFS= read -r _line; do
        [[ -z "$_line" ]] && continue
        _TICKET_LINES+=("$_line")
    done
elif [ "$_CLASSIFY" = "1" ]; then
    # --classify scan mode: enumerate ALL brainstorm:complete-tagged epics
    # (not just those needing structural migration). The classifier pass needs
    # to evaluate every brainstorm:complete-tagged epic's SC/DD/AC items even
    # when the Closure Checks section already exists — items in SC may need
    # to move SC→CC based on the classifier's verdict.
    echo "INFO: --classify mode — enumerating brainstorm:complete-tagged epics for classifier pass."
    # Use ticket list --format=llm to get canonical IDs (list-epics column 1
    # can be an alias, and aliases don't resolve via ticket show today — see
    # bug 9894-a463-090a-43e5). The llm format emits one JSON line per ticket
    # with stable ticket_id, ticket_type, status, title, and tags fields.
    # `ticket list` does not accept --has-tag, so we enumerate by type+status
    # and filter by tag in python.
    _epic_list=$({
        "$_TARGET/.claude/scripts/dso" ticket list --type=epic --status=open --format=llm 2>/dev/null
        "$_TARGET/.claude/scripts/dso" ticket list --type=epic --status=in_progress --format=llm 2>/dev/null
        "$_TARGET/.claude/scripts/dso" ticket list --type=epic --status=closed --format=llm 2>/dev/null
    } | python3 -c '
import json, sys
for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    try:
        t = json.loads(line)
    except json.JSONDecodeError:
        continue
    tags = t.get("tg") or t.get("tags") or []
    if "brainstorm:complete" not in tags:
        continue
    tid = t.get("ticket_id") or t.get("id")
    if not tid:
        continue
    title = (t.get("ttl") or t.get("title") or "").replace("\t", " ")
    status = t.get("st") or t.get("status") or "open"
    print(f"{tid}\tepic\t{status}\t{title}")
' 2>/dev/null)
    while IFS= read -r _line; do
        [[ -z "$_line" ]] && continue
        _TICKET_LINES+=("$_line")
    done <<< "$_epic_list"
    if [ "${#_TICKET_LINES[@]}" -eq 0 ]; then
        echo "INFO: No brainstorm:complete-tagged epics found — nothing to classify."
        exit 0
    fi
    echo "INFO: ${#_TICKET_LINES[@]} brainstorm:complete-tagged epic(s) queued for classifier pass."
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

# ── Epic-count cap (--classify mode only) ────────────────────────────────────
# Applies after all input modes so it works for both scan and stdin-piped runs.
# Prevents unbounded single-run execution under auto-approve. Truncate to
# _CLASSIFY_MAX_EPICS and emit a clear re-run message naming the deferred count.
if [ "$_CLASSIFY" = "1" ] && [ "${#_TICKET_LINES[@]}" -gt "$_CLASSIFY_MAX_EPICS" ]; then
    _deferred=$(( ${#_TICKET_LINES[@]} - _CLASSIFY_MAX_EPICS ))
    echo "INFO: Epic-count cap reached (DSO_CLASSIFY_MAX_EPICS=$_CLASSIFY_MAX_EPICS). Processing first $_CLASSIFY_MAX_EPICS epic(s); $_deferred deferred — re-run to continue."
    _TICKET_LINES=("${_TICKET_LINES[@]:0:$_CLASSIFY_MAX_EPICS}")
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

# ── Python annotation-rewrite function (inline) ───────────────────────────────
# After migrating an epic, rewrite child-story "← Satisfies: <text>" annotations
# to "← Validates Closure Check: <text>" when <text> matches a Closure Checks item.
# Returns one line per child processed: ANNOTATE:<id>:rewritten N or ANNOTATE:<id>:skipped
_rewrite_annotations_for_epic() {
    local epic_id="$1"
    local tracker_dir="$2"
    local dryrun="$3"

    python3 - "$epic_id" "$tracker_dir" "$dryrun" <<'PYEOF'
import json, os, re, sys, time, uuid

EPIC_ID = sys.argv[1]
TRACKER = sys.argv[2]
DRYRUN = sys.argv[3] == "1"
CLOSURE_HEADING = "## Closure Checks"
SATISFIES_PATTERN = re.compile(r'← Satisfies:\s*"([^"]+)"')
ALREADY_REWRITTEN_PATTERN = re.compile(r'← Validates Closure Check:\s*"')


def _read_events(tdir):
    """Return list of (filename, event_dict) sorted chronologically."""
    try:
        files = sorted(f for f in os.listdir(tdir)
                       if f.endswith('.json') and not f.startswith('.'))
    except OSError:
        return []
    results = []
    for fn in files:
        try:
            with open(os.path.join(tdir, fn)) as f:
                ev = json.load(f)
            results.append((fn, ev))
        except (json.JSONDecodeError, OSError):
            continue
    return results


def _get_current_description(tdir):
    """Return the most up-to-date description by reducing events in order."""
    description = None
    for _fn, ev in _read_events(tdir):
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


def _get_ticket_type(tdir):
    """Return ticket_type string for the ticket directory."""
    for _fn, ev in _read_events(tdir):
        data = ev.get('data') or {}
        etype = ev.get('event_type', '')
        tt = data.get('ticket_type')
        if tt:
            return tt
        if etype == 'SNAPSHOT':
            cs = data.get('compiled_state') or {}
            tt2 = cs.get('ticket_type')
            if tt2:
                return tt2
    return None


def _get_parent_id(tdir):
    """Return parent_id for the ticket, or None."""
    parent_id = None
    for _fn, ev in _read_events(tdir):
        data = ev.get('data') or {}
        etype = ev.get('event_type', '')
        if etype == 'CREATE':
            p = data.get('parent_id')
            if p is not None:
                parent_id = p
        elif etype == 'EDIT':
            fields = data.get('fields') or {}
            p = fields.get('parent_id')
            if p is not None:
                parent_id = p
        elif etype == 'SNAPSHOT':
            cs = data.get('compiled_state') or {}
            p = cs.get('parent_id')
            if p is not None:
                parent_id = p
    return parent_id


def _extract_closure_checks_items(description):
    """
    Extract normalized items from the ## Closure Checks section.
    Returns a list of lowercase strings (stripped of leading list markers).
    """
    if not description:
        return []
    m = re.search(r'## Closure Checks\n(.*?)(?=\n## |\Z)', description, re.DOTALL)
    if not m:
        return []
    section = m.group(1)
    items = []
    for line in section.splitlines():
        stripped = re.sub(r'^[-*+]\s*', '', line).strip()
        if stripped:
            items.append(stripped.lower())
    return items


def write_edit_event(tdir, new_description):
    ts = time.time_ns()
    u = str(uuid.uuid4())
    fname = f"{ts}-{u}-EDIT.json"
    fpath = os.path.join(tdir, fname)
    event = {
        "timestamp": ts,
        "uuid": u,
        "event_type": "EDIT",
        "env_id": "00000000-0000-4000-8000-migration003",
        "author": "migrate-closure-checks/annotate",
        "data": {"fields": {"description": new_description}},
    }
    with open(fpath, 'w', encoding='utf-8') as f:
        json.dump(event, f, ensure_ascii=False)
    return fname


# 1. Read the epic's current Closure Checks items
epic_tdir = os.path.join(TRACKER, EPIC_ID)
epic_desc = _get_current_description(epic_tdir)
cc_items = _extract_closure_checks_items(epic_desc)

if not cc_items:
    print(f"[ANNOTATE] {EPIC_ID}: no Closure Checks items — skipping annotation rewrite")
    sys.exit(0)

# 2. Scan all tickets in the tracker for children of this epic
try:
    all_ticket_dirs = [d for d in os.listdir(TRACKER)
                       if os.path.isdir(os.path.join(TRACKER, d))
                       and not d.startswith('.')]
except OSError as e:
    print(f"[ANNOTATE] {EPIC_ID}: error scanning tracker — {e}", file=sys.stderr)
    sys.exit(1)

for ticket_id in sorted(all_ticket_dirs):
    tdir = os.path.join(TRACKER, ticket_id)
    parent_id = _get_parent_id(tdir)
    if parent_id != EPIC_ID:
        continue

    desc = _get_current_description(tdir)
    if not desc:
        print(f"[ANNOTATE] {ticket_id}: skipped — 0 matches")
        continue

    # Idempotency: check if already-rewritten annotation exists for any CC item
    # Count how many '← Satisfies: "X"' where X is a CC item
    def _make_replacement(cc_set):
        def replacer(m):
            text = m.group(1)
            if text.lower() in cc_set:
                return f'← Validates Closure Check: "{text}"'
            return m.group(0)
        return replacer

    cc_set = set(cc_items)
    new_desc = SATISFIES_PATTERN.sub(_make_replacement(cc_set), desc)

    # Count rewrites
    rewrites = 0
    for match in SATISFIES_PATTERN.finditer(desc):
        if match.group(1).lower() in cc_set:
            rewrites += 1

    if rewrites == 0:
        print(f"[ANNOTATE] {ticket_id}: skipped — 0 matches")
        continue

    if DRYRUN:
        print(f"[ANNOTATE] {ticket_id}: would rewrite {rewrites} annotation(s)")
        continue

    try:
        fname = write_edit_event(tdir, new_desc)
        print(f"[ANNOTATE] {ticket_id}: rewrote {rewrites} annotation(s) fname={fname}")
    except OSError as e:
        print(f"[ANNOTATE] {ticket_id}: ERROR — {e}", file=sys.stderr)
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
_batch_migrated=0
_batch_skipped=0
# Wall-time guard start timestamp (--classify mode only; harmless in other modes)
_CLASSIFY_START_SECONDS=$SECONDS
_WALL_TIME_EXCEEDED=0

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

        # Wall-time guard (--classify mode): break cleanly if elapsed time exceeds limit.
        if [ "$_CLASSIFY" = "1" ] && (( SECONDS - _CLASSIFY_START_SECONDS >= _CLASSIFY_WALL_TIME_SECS )); then
            echo "WALL_TIME_EXCEEDED: elapsed $((SECONDS - _CLASSIFY_START_SECONDS))s >= limit ${_CLASSIFY_WALL_TIME_SECS}s — stopping cleanly; re-run to continue."
            _WALL_TIME_EXCEEDED=1
            break 2
        fi

        # Check progress file (resume semantics) — only for the structural
        # migration pass. The --classify pass uses snapshot-based idempotency
        # in the helper, so it re-evaluates every ticket.
        if [ "${_ALREADY_PROCESSED[$_ticket_id]+_}" = "_" ] && [ "$_CLASSIFY" = "0" ]; then
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
                # Commit the EDIT event to the tickets branch. Track commit
                # success — a failed add+commit must NOT count as MIGRATED,
                # because the resume file would then suppress retry next run.
                _commit_ok=1
                if [ "$_DRYRUN" = "0" ]; then
                    _commit_ok=0
                    if git -C "$_TRACKER_DIR" add "$_tid/$_event_name" 2>/dev/null \
                        && git -C "$_TRACKER_DIR" commit -m "migration: add ## Closure Checks section to $_tid" 2>/dev/null; then
                        _commit_ok=1
                    else
                        # Clean up the staged add so the working tree stays
                        # consistent for retry on the next run.
                        git -C "$_TRACKER_DIR" reset 2>/dev/null || true
                        rm -f "$_TRACKER_DIR/$_tid/$_event_name" 2>/dev/null || true
                    fi
                fi
                if [ "$_commit_ok" = "1" ]; then
                    echo "MIGRATED: $_ticket_id"
                    _migrated=$(( _migrated + 1 ))
                    _batch_migrated=$(( _batch_migrated + 1 ))
                    if [ "$_DRYRUN" = "0" ]; then
                        echo "$_ticket_id" >> "$_PROGRESS_FILE"
                    fi
                else
                    echo "ERROR: $_ticket_id — git add/commit failed; not recorded as MIGRATED; will retry next run" >&2
                    _failed=$(( _failed + 1 ))
                    _batch_failed=$(( _batch_failed + 1 ))
                    # Skip annotation-rewrite when commit failed.
                    _j=$(( _j ))
                    continue
                fi
                # Run annotation-rewrite pass for epics (stories don't have child stories)
                # Check ticket type: only run for epics
                _ticket_type=$(python3 -c "
import json, os, sys
tdir = os.path.join(sys.argv[1], sys.argv[2])
files = sorted(f for f in os.listdir(tdir) if f.endswith('.json') and not f.startswith('.'))
for fn in files:
    try:
        ev = json.load(open(os.path.join(tdir, fn)))
    except Exception:
        continue
    data = ev.get('data') or {}
    tt = data.get('ticket_type')
    if tt:
        print(tt)
        sys.exit(0)
    if ev.get('event_type') == 'SNAPSHOT':
        cs = data.get('compiled_state') or {}
        tt2 = cs.get('ticket_type')
        if tt2:
            print(tt2)
            sys.exit(0)
print('')
" "$_TRACKER_DIR" "$_ticket_id" 2>/dev/null || echo "")
                if [ "$_ticket_type" = "epic" ]; then
                    _rewrite_annotations_for_epic "$_ticket_id" "$_TRACKER_DIR" "$_DRYRUN" | while IFS= read -r _annotate_line; do
                        _display_line=$(echo "$_annotate_line" | sed 's/ fname=[^ ]*$//')
                        echo "$_display_line"
                        # Commit annotation EDIT events for each child ticket
                        if [ "$_DRYRUN" = "0" ] && echo "$_annotate_line" | grep -q '^\[ANNOTATE\].*rewrote'; then
                            _child_id=$(echo "$_annotate_line" | sed 's/\[ANNOTATE\] \([^:]*\):.*/\1/')
                            _edit_fname=$(echo "$_annotate_line" | sed 's/.*fname=\([^ ]*\).*/\1/')
                            if [ -n "$_edit_fname" ] && [ "$_edit_fname" != "$_annotate_line" ]; then
                                git -C "$_TRACKER_DIR" add "$_child_id/$_edit_fname" 2>/dev/null && \
                                    git -C "$_TRACKER_DIR" commit -m "migration: rewrite annotation(s) in $_child_id" 2>/dev/null || \
                                    git -C "$_TRACKER_DIR" reset 2>/dev/null || true
                            fi
                        fi
                    done
                fi
                ;;
            WOULD_WRITE:*)
                echo "DRY-RUN: $_ticket_id"
                _migrated=$(( _migrated + 1 ))
                _batch_migrated=$(( _batch_migrated + 1 ))
                ;;
            SKIPPED:*)
                _reason="${_result#SKIPPED:*:}"
                echo "SKIPPED: $_ticket_id ($_reason)"
                _skipped=$(( _skipped + 1 ))
                _batch_skipped=$(( _batch_skipped + 1 ))
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

        # ── Phase 2 classifier pass (story ad70 DD1–DD8) ─────────────────
        # Invoke the per-ticket classifier helper when --classify is set AND
        # the structural pass left the ticket in a classifiable state
        # (WROTE, WOULD_WRITE, or SKIPPED:already-has-section). ERROR tickets
        # are NOT classified — fix the structural pass first.
        if [ "$_CLASSIFY" = "1" ]; then
            case "$_result" in
                WROTE:*|WOULD_WRITE:*|SKIPPED:*)
                    _remaining=$(( _CLASSIFIER_BUDGET - _CLASSIFIER_CONSUMED ))
                    if [ "$_remaining" -le "0" ]; then
                        echo "BATCH_PAUSE: classifier budget exhausted ($_CLASSIFIER_CONSUMED/$_CLASSIFIER_BUDGET acknowledgments). Re-run to continue."
                        # Exit the main loop; the outer `while [ "$_i" -lt "$_total" ]` will also exit.
                        break 2
                    fi
                    _classify_dryrun_arg=""
                    [ "$_DRYRUN" = "1" ] && _classify_dryrun_arg="--dry-run"
                    _classify_exit=0
                    _classify_out=$("$_CLASSIFIER_HELPER" \
                        --ticket-id "$_ticket_id" \
                        --target "$_TARGET" \
                        --session-id "$_TARGET_HASH" \
                        --migration-run-id "$_MIGRATION_RUN_ID" \
                        --remaining-budget "$_remaining" \
                        $_classify_dryrun_arg 2>&1) || _classify_exit=$?
                    # Echo helper output so the operator sees ITEM: / AUDIT_WRITTEN: / etc lines
                    printf '%s\n' "$_classify_out"
                    # Update cumulative budget from BUDGET_CONSUMED line
                    _consumed_this=$(printf '%s' "$_classify_out" | grep '^BUDGET_CONSUMED:' | tail -1 | sed 's|^BUDGET_CONSUMED: *||')
                    if [ -n "$_consumed_this" ]; then
                        _CLASSIFIER_CONSUMED=$(( _CLASSIFIER_CONSUMED + _consumed_this ))
                    fi
                    # On BATCH_PAUSE return (exit 2), break out of both loops
                    if [ "$_classify_exit" = "2" ]; then
                        echo "BATCH_PAUSE: classifier helper signaled budget exhausted mid-ticket. Re-run to continue."
                        break 2
                    fi
                    if [ "$_classify_exit" = "1" ]; then
                        echo "ERROR: $_ticket_id — classifier helper failed" >&2
                    fi
                    ;;
                *)
                    # ERROR or unexpected — skip classifier for this ticket
                    ;;
            esac
        fi
    done

    echo "BATCH_COMPLETE: batch $_batch_num — migrated_this_batch: $_batch_migrated, skipped_this_batch: $_batch_skipped, failed: $_batch_failed (total so far: migrated=$_migrated skipped=$_skipped)"
    _batch_failed=0
    _batch_migrated=0
    _batch_skipped=0
    _i="$_batch_end"
done

# ── Annotation-rewrite pass (global, independent of migration) ────────────────
# Runs for ALL epics that have ## Closure Checks content, including those
# that were already migrated before this run (skipped by main migration).
# This pass is idempotent: already-rewritten annotations are skipped.
if [ "$_DRYRUN" = "0" ] || [ "$_DRYRUN" = "1" ]; then
    echo ""
    echo "INFO: Running annotation-rewrite pass for all epics with Closure Checks..."
    _annotate_rewrites=0

    # Enumerate all epic tickets with ## Closure Checks
    for _epic_dir in "$_TRACKER_DIR"/*/; do
        _epic_id=$(basename "$_epic_dir")
        [[ "$_epic_id" == .* ]] && continue
        [ ! -d "$_epic_dir" ] && continue

        # Check if this is an epic with Closure Checks
        _is_epic_with_cc=$(python3 -c "
import json, os, re, sys
tdir = sys.argv[1]
try:
    files = sorted(f for f in os.listdir(tdir) if f.endswith('.json') and not f.startswith('.'))
except OSError:
    print('0')
    sys.exit(0)
ticket_type = None
description = None
for fn in files:
    try:
        ev = json.load(open(os.path.join(tdir, fn)))
    except Exception:
        continue
    data = ev.get('data') or {}
    etype = ev.get('event_type', '')
    tt = data.get('ticket_type')
    if tt:
        ticket_type = tt
    if etype == 'CREATE':
        d = data.get('description')
        if d is not None:
            description = d
    elif etype == 'EDIT':
        d = (data.get('fields') or {}).get('description')
        if d is not None:
            description = d
    elif etype == 'SNAPSHOT':
        cs = data.get('compiled_state') or {}
        d = cs.get('description')
        if d is not None:
            description = d
        tt2 = cs.get('ticket_type')
        if tt2:
            ticket_type = tt2
if ticket_type == 'epic' and description and '## Closure Checks' in description:
    print('1')
else:
    print('0')
" "$_epic_dir" 2>/dev/null || echo "0")

        [ "$_is_epic_with_cc" != "1" ] && continue

        # Run annotation-rewrite for this epic
        _rewrite_annotations_for_epic "$_epic_id" "$_TRACKER_DIR" "$_DRYRUN" | while IFS= read -r _annotate_line; do
            # Strip fname= trailer for display
            _display_line=$(echo "$_annotate_line" | sed 's/ fname=[^ ]*$//')
            echo "$_display_line"
            # Commit annotation EDIT events for each child ticket
            if [ "$_DRYRUN" = "0" ] && echo "$_annotate_line" | grep -q '^\[ANNOTATE\].*rewrote'; then
                _child_id=$(echo "$_annotate_line" | sed 's/\[ANNOTATE\] \([^:]*\):.*/\1/')
                _edit_fname=$(echo "$_annotate_line" | sed 's/.*fname=\([^ ]*\).*/\1/')
                if [ -n "$_edit_fname" ] && [ "$_edit_fname" != "$_annotate_line" ]; then
                    git -C "$_TRACKER_DIR" add "$_child_id/$_edit_fname" 2>/dev/null && \
                        git -C "$_TRACKER_DIR" commit -m "migration: rewrite annotation(s) in $_child_id" 2>/dev/null || \
                        git -C "$_TRACKER_DIR" reset 2>/dev/null || true
                fi
            fi
        done
    done
fi

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
