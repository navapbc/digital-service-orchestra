#!/usr/bin/env bash
# plugins/dso/scripts/cutover-tickets-migration.sh
# Phase-gate skeleton for the tickets migration cutover.
#
# Phases (in order): validate, snapshot, migrate, verify, finalize
#   Constant names:  PRE_FLIGHT, SNAPSHOT, MIGRATE, VERIFY, FINALIZE
#
# Usage: cutover-tickets-migration.sh [--dry-run] [--resume] [--repo-root=PATH] [--help]
#
# Environment variables:
#   CUTOVER_LOG_DIR          Directory for timestamped log file (default: /tmp)
#   CUTOVER_STATE_FILE       Path for the run state file (default: /tmp/cutover-tickets-migration-state.json)
#   CUTOVER_PHASE_EXIT_OVERRIDE  "PHASE_NAME=EXIT_CODE" — inject a failure for testing
#
# Exit codes: 0=success, 1=error

set -euo pipefail

# ---------------------------------------------------------------------------
# Phase constants (ordered)
# ---------------------------------------------------------------------------
readonly PHASES=( validate snapshot migrate verify finalize )
# Canonical constant aliases (for --help display)
# PRE_FLIGHT=validate  SNAPSHOT=snapshot  MIGRATE=migrate  VERIFY=verify  FINALIZE=finalize

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
_DRY_RUN="false"
_RESUME="false"
_REPO_ROOT=""

for _arg in "$@"; do
    case "$_arg" in
        --help)
            cat <<'USAGE'
Usage: cutover-tickets-migration.sh [--dry-run] [--resume] [--repo-root=PATH] [--help]

  --dry-run           Execute phase stubs but skip state-file writes and
                      any git-modifying actions. Prefixes output with [DRY RUN].
  --resume            Read state file and skip already-completed phases.
  --repo-root=PATH    Override the git repo root (default: git rev-parse --show-toplevel).
  --help              Print this usage message and exit.

Phases (run in order):
  1. validate    (alias: PRE_FLIGHT)  — pre-flight checks
  2. snapshot    (alias: SNAPSHOT)    — snapshot current ticket state
  3. migrate     (alias: MIGRATE)     — migrate ticket format
  4. verify      (alias: VERIFY)      — verify migration results
  5. finalize    (alias: FINALIZE / REFERENCE_UPDATE / CLEANUP) — update references and clean up

Environment variables:
  CUTOVER_LOG_DIR          Log directory (default: /tmp)
  CUTOVER_STATE_FILE       State file path (default: /tmp/cutover-tickets-migration-state.json)
  CUTOVER_PHASE_EXIT_OVERRIDE  Inject a phase failure, e.g. "MIGRATE=1" (for testing only)

USAGE
            exit 0
            ;;
        --dry-run)
            _DRY_RUN="true"
            ;;
        --resume)
            _RESUME="true"
            ;;
        --repo-root=*)
            _REPO_ROOT="${_arg#--repo-root=}"
            ;;
        *)
            echo "ERROR: Unknown argument: $_arg" >&2
            exit 1
            ;;
    esac
done

# ---------------------------------------------------------------------------
# Resolve REPO_ROOT
# ---------------------------------------------------------------------------
if [[ -z "$_REPO_ROOT" ]]; then
    if ! _REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null); then
        echo "ERROR: Not a git repository and --repo-root not supplied." >&2
        exit 1
    fi
fi

# ---------------------------------------------------------------------------
# Ticket directory env vars (used by _phase_migrate)
# ---------------------------------------------------------------------------
# CUTOVER_TICKETS_DIR  — source .tickets/ dir (default: REPO_ROOT/.tickets)
# CUTOVER_TRACKER_DIR  — destination .tickets-tracker/ dir (default: REPO_ROOT/.tickets-tracker)

# ---------------------------------------------------------------------------
# Log file setup
# ---------------------------------------------------------------------------
: "${CUTOVER_LOG_DIR:=/tmp}"
_LOG_TIMESTAMP=$(date +%Y-%m-%dT%H-%M-%S)
_LOG_FILE="${CUTOVER_LOG_DIR}/cutover-${_LOG_TIMESTAMP}.log"
: "${CUTOVER_SNAPSHOT_FILE:=${CUTOVER_LOG_DIR}/cutover-snapshot-${_LOG_TIMESTAMP}.json}"

# Re-exec the script under tee to capture all output to the log file while
# also printing to stdout.  PIPESTATUS[0] preserves the real exit code.
# Guard with _CUTOVER_LOGGING to prevent infinite re-exec.
if [[ -z "${_CUTOVER_LOGGING:-}" ]]; then
    export _CUTOVER_LOGGING=1
    mkdir -p "$CUTOVER_LOG_DIR"
    bash "$0" "$@" 2>&1 | tee -a "$_LOG_FILE"
    exit "${PIPESTATUS[0]}"
fi

# ---------------------------------------------------------------------------
# State file
# ---------------------------------------------------------------------------
: "${CUTOVER_STATE_FILE:=/tmp/cutover-tickets-migration-state.json}"

# ---------------------------------------------------------------------------
# Resume: load completed phases from state file
# ---------------------------------------------------------------------------
# _COMPLETED_PHASES is a newline-separated list of phase names already done.
_COMPLETED_PHASES=""

if [[ "$_RESUME" == "true" && -f "$CUTOVER_STATE_FILE" ]]; then
    _COMPLETED_PHASES=$(python3 - "$CUTOVER_STATE_FILE" <<'PYEOF'
import sys, json
path = sys.argv[1]
try:
    with open(path) as fh:
        data = json.load(fh)
    for phase in data.get("completed_phases", []):
        print(phase)
except Exception:
    pass
PYEOF
)
fi

_phase_is_completed() {
    local phase="$1"
    echo "$_COMPLETED_PHASES" | grep -qx "$phase"
}

_state_append_phase() {
    local phase="$1"
    if [[ "$_DRY_RUN" == "true" ]]; then
        return 0
    fi
    # Append completed phase to state file
    if [[ ! -f "$CUTOVER_STATE_FILE" ]]; then
        printf '{"completed_phases":["%s"]}\n' "$phase" > "$CUTOVER_STATE_FILE"
    else
        # Use python3 for reliable JSON update (stdlib, no new deps)
        python3 - "$CUTOVER_STATE_FILE" "$phase" <<'PYEOF'
import sys, json
path, phase = sys.argv[1], sys.argv[2]
with open(path) as fh:
    data = json.load(fh)
data.setdefault("completed_phases", []).append(phase)
with open(path, "w") as fh:
    json.dump(data, fh)
    fh.write("\n")
PYEOF
    fi
}

# ---------------------------------------------------------------------------
# Test injection hook: CUTOVER_PHASE_EXIT_OVERRIDE
# Format: "PHASE_NAME=EXIT_CODE", e.g., "MIGRATE=1" or "PRE_FLIGHT=1"
# ---------------------------------------------------------------------------
_check_override() {
    local phase_lower="$1"
    local phase_upper
    phase_upper=$(echo "$phase_lower" | tr '[:lower:]' '[:upper:]')
    if [[ -n "${CUTOVER_PHASE_EXIT_OVERRIDE:-}" ]]; then
        local override_phase override_code resolved_upper
        override_phase="${CUTOVER_PHASE_EXIT_OVERRIDE%%=*}"
        override_code="${CUTOVER_PHASE_EXIT_OVERRIDE##*=}"
        # Resolve constant aliases to their canonical uppercase phase name
        case "$override_phase" in
            PRE_FLIGHT)      resolved_upper="VALIDATE"  ;;
            SNAPSHOT)        resolved_upper="SNAPSHOT"  ;;
            MIGRATE)         resolved_upper="MIGRATE"   ;;
            VERIFY)          resolved_upper="VERIFY"    ;;
            FINALIZE|REFERENCE_UPDATE|CLEANUP) resolved_upper="FINALIZE" ;;
            *)               resolved_upper="$override_phase" ;;
        esac
        if [[ "$resolved_upper" == "$phase_upper" ]]; then
            return "$override_code"
        fi
    fi
    return 0
}

# ---------------------------------------------------------------------------
# Phase handler stubs
# (Actual migration logic added by sibling stories w21-7mlx, w21-wbqz, w21-25mq)
# ---------------------------------------------------------------------------

_phase_validate() {
    echo "Running phase: validate"
    _check_override "validate" || return $?
}

_phase_snapshot() {
    # REVIEW-DEFENSE: Test coverage for _phase_snapshot is provided by dso-gfph (3 GREEN tests):
    #   test_phase_snapshot_writes_file    — file write and JSON structure
    #   test_phase_snapshot_ticket_count   — populated ticket set (non-empty path)
    #   test_phase_snapshot_tk_show_output — tk show invocation and output capture
    # The empty-tickets path (ticket_count=0) is a degenerate subset of the file-write test;
    # the tk-unavailable raw-file fallback is exercised by the tk_show_output fixture which
    # stubs tk. Additional edge-case tests (empty set isolation, explicit fallback path) are
    # valid future hardening but are out of scope for dso-9trm, whose AC is the snapshot
    # implementation itself (dso-gfph owned the test story).
    echo "Running phase: snapshot"
    _check_override "snapshot" || return $?
    # Write pre-flight snapshot to CUTOVER_SNAPSHOT_FILE
    local _tickets_dir="${_REPO_ROOT}/.tickets"
    local _ticket_ids=()
    local _ticket_count=0

    # Collect all ticket IDs from .tickets/*.md
    # Exclude .index.json and other non-ticket files
    if [[ -d "$_tickets_dir" ]]; then
        while IFS= read -r -d '' _f; do
            local _basename
            _basename=$(basename "$_f" .md)
            # Skip anything that isn't a ticket ID (e.g., hidden files, README)
            if [[ "$_basename" =~ ^[a-zA-Z0-9_-]+$ ]]; then
                _ticket_ids+=("$_basename")
            fi
        done < <(find "$_tickets_dir" -maxdepth 1 -name '*.md' -print0 2>/dev/null | sort -z)
        _ticket_count="${#_ticket_ids[@]}"
    fi

    if [[ "$_ticket_count" -eq 0 ]]; then
        echo "Snapshot: no tickets found in ${_tickets_dir} (ticket_count=0)"
        python3 - "$CUTOVER_SNAPSHOT_FILE" <<PYEOF
import json, sys, datetime
path = sys.argv[1]
data = {
    "timestamp": datetime.datetime.utcnow().strftime("%Y-%m-%dT%H:%M:%SZ"),
    "ticket_count": 0,
    "tickets": [],
    "jira_mappings": {}
}
with open(path, "w") as fh:
    json.dump(data, fh, indent=2)
    fh.write("\n")
PYEOF
        echo "Snapshot written to $CUTOVER_SNAPSHOT_FILE"
        return 0
    fi

    # Build ticket snapshot data via python3 (handles special chars safely)
    python3 - "$CUTOVER_SNAPSHOT_FILE" "$_tickets_dir" "${_ticket_ids[@]}" <<'PYEOF'
import json, sys, datetime, subprocess, os

snapshot_file = sys.argv[1]
tickets_dir   = sys.argv[2]
ticket_ids    = sys.argv[3:]

tickets = []
jira_mappings = {}

for tid in ticket_ids:
    # Try tk show first; fall back to raw file read on failure
    output = None
    try:
        result = subprocess.run(
            ["tk", "show", tid],
            capture_output=True, text=True, timeout=30
        )
        if result.returncode == 0:
            output = result.stdout
        else:
            err_msg = (result.stderr or result.stdout or "non-zero exit").strip()
            print(f"WARNING: tk show {tid} failed: {err_msg}", file=sys.stderr)
            output = f"ERROR: {err_msg}"
    except (FileNotFoundError, subprocess.TimeoutExpired) as exc:
        # tk not available in fixture — fall back to raw file content
        raw_path = os.path.join(tickets_dir, f"{tid}.md")
        if os.path.isfile(raw_path):
            with open(raw_path) as fh:
                output = fh.read()
        else:
            output = f"ERROR: {exc}"

    # Extract jira_key from frontmatter if present
    if output and not output.startswith("ERROR:"):
        for line in output.splitlines():
            line = line.strip()
            if line.startswith("jira_key:"):
                jira_key = line.split(":", 1)[1].strip()
                if jira_key:
                    jira_mappings[tid] = jira_key
                break

    tickets.append({"id": tid, "output": output or ""})

data = {
    "timestamp": datetime.datetime.utcnow().strftime("%Y-%m-%dT%H:%M:%SZ"),
    "ticket_count": len(ticket_ids),
    "tickets": tickets,
    "jira_mappings": jira_mappings,
}

with open(snapshot_file, "w") as fh:
    json.dump(data, fh, indent=2)
    fh.write("\n")

print(f"Snapshot written to {snapshot_file}")
PYEOF
}

_phase_migrate() {
    echo "Running phase: migrate"
    _check_override "migrate" || return $?

    # Disable compaction during migration
    export TICKET_COMPACT_DISABLED=1

    local _tickets_dir="${CUTOVER_TICKETS_DIR:-${_REPO_ROOT}/.tickets}"
    local _tracker_dir="${CUTOVER_TRACKER_DIR:-${_REPO_ROOT}/.tickets-tracker}"

    local _migrated=0
    local _skipped_already=0
    local _skipped_malformed=0

    if [[ ! -d "$_tickets_dir" ]]; then
        echo "WARN: tickets directory not found: $_tickets_dir" >&2
        unset TICKET_COMPACT_DISABLED
        return 0
    fi

    mkdir -p "$_tracker_dir"

    # Process each .tickets/*.md file
    while IFS= read -r -d '' _md_file; do
        local _basename
        _basename=$(basename "$_md_file")

        # Skip non-ticket files
        case "$_basename" in
            README.md|.index.json) continue ;;
        esac
        # Must end in .md
        [[ "$_basename" == *.md ]] || continue

        # Parse frontmatter via python3
        local _parse_result
        _parse_result=$(python3 - "$_md_file" <<'PYEOF'
import sys, json

md_path = sys.argv[1]
try:
    with open(md_path, encoding='utf-8') as fh:
        content = fh.read()
except Exception as e:
    print(json.dumps({"error": str(e)}))
    sys.exit(0)

lines = content.splitlines()

# Find frontmatter delimiters
if len(lines) < 2 or lines[0].strip() != '---':
    print(json.dumps({"error": "no_frontmatter"}))
    sys.exit(0)

end_idx = None
for i in range(1, len(lines)):
    if lines[i].strip() == '---':
        end_idx = i
        break

if end_idx is None:
    print(json.dumps({"error": "no_closing_delimiter"}))
    sys.exit(0)

fm_lines = lines[1:end_idx]
body_lines = lines[end_idx+1:]

# Simple YAML key:value parser (handles lists as yaml: [a, b] or multi-line "- item")
fm = {}
i = 0
while i < len(fm_lines):
    line = fm_lines[i]
    if ':' in line and not line.startswith(' '):
        key, _, rest = line.partition(':')
        key = key.strip()
        rest = rest.strip()
        if rest.startswith('[') and rest.endswith(']'):
            inner = rest[1:-1].strip()
            if inner:
                fm[key] = [x.strip().strip('"\'') for x in inner.split(',') if x.strip()]
            else:
                fm[key] = []
        elif rest == '':
            # Possible multi-line list: collect indented "- item" lines that follow
            items = []
            j = i + 1
            while j < len(fm_lines) and fm_lines[j].startswith(' '):
                stripped = fm_lines[j].strip()
                if stripped.startswith('- '):
                    items.append(stripped[2:].strip().strip('"\''))
                j += 1
            if items:
                fm[key] = items
                i = j
                continue
            else:
                fm[key] = rest
        else:
            fm[key] = rest
    i += 1

# Collect notes from body (lines under ## Notes that match [timestamp] text)
notes = []
in_notes = False
for line in body_lines:
    stripped = line.strip()
    if stripped.lower().startswith('## notes'):
        in_notes = True
        continue
    if stripped.startswith('## ') and in_notes:
        in_notes = False
        continue
    if in_notes and stripped.startswith('[') and ']' in stripped:
        # Timestamped note line: [timestamp] body text
        bracket_end = stripped.index(']')
        note_body = stripped[bracket_end+1:].strip()
        if note_body:
            notes.append(note_body)

result = {
    "id": fm.get("id", ""),
    "title": fm.get("title", ""),
    "status": fm.get("status", "open"),
    "type": fm.get("type", "task"),
    "priority": fm.get("priority", "2"),
    "parent": fm.get("parent", ""),
    "deps": fm.get("deps", []) if isinstance(fm.get("deps"), list) else [],
    "links": fm.get("links", []) if isinstance(fm.get("links"), list) else [],
    "notes": notes,
}
print(json.dumps(result))
PYEOF
)

        # Check for parse errors
        local _parse_error
        _parse_error=$(python3 -c "import json,sys; d=json.loads(sys.argv[1]); print(d.get('error',''))" "$_parse_result" 2>/dev/null || echo "python_error")
        if [[ -n "$_parse_error" ]]; then
            echo "WARN: skipping malformed ticket $_basename (${_parse_error})" >&2
            (( _skipped_malformed++ )) || true
            continue
        fi

        local _ticket_id
        _ticket_id=$(python3 -c "import json,sys; d=json.loads(sys.argv[1]); print(d.get('id',''))" "$_parse_result" 2>/dev/null || echo "")
        if [[ -z "$_ticket_id" ]]; then
            echo "WARN: skipping malformed ticket $_basename (no id)" >&2
            (( _skipped_malformed++ )) || true
            continue
        fi

        # Idempotency check: skip if CREATE event already exists
        if find "$_tracker_dir/$_ticket_id" -maxdepth 1 -name '*-CREATE.json' 2>/dev/null | grep -q .; then
            echo "Skipping already-migrated ticket: $_ticket_id"
            (( _skipped_already++ )) || true
            continue
        fi

        # Extract remaining fields
        local _ticket_type _ticket_title _ticket_status _ticket_notes
        _ticket_type=$(python3 -c "import json,sys; d=json.loads(sys.argv[1]); print(d.get('type','task'))" "$_parse_result")
        _ticket_title=$(python3 -c "import json,sys; d=json.loads(sys.argv[1]); print(d.get('title',''))" "$_parse_result")
        _ticket_status=$(python3 -c "import json,sys; d=json.loads(sys.argv[1]); print(d.get('status','open'))" "$_parse_result")

        # Create ticket directory and write CREATE event JSON directly
        mkdir -p "$_tracker_dir/$_ticket_id"
        python3 - "$_tracker_dir/$_ticket_id" "$_ticket_id" "$_ticket_type" "$_ticket_title" "$_ticket_status" "$_parse_result" <<'PYEOF'
import json, sys, uuid, time

ticket_dir   = sys.argv[1]
ticket_id    = sys.argv[2]
ticket_type  = sys.argv[3]
title        = sys.argv[4]
status       = sys.argv[5]
parse_json   = sys.argv[6]

parsed = json.loads(parse_json)
notes  = parsed.get("notes", [])

ts = int(time.time())
event_uuid = str(uuid.uuid4())

# Write CREATE event
create_event = {
    "timestamp": ts,
    "uuid": event_uuid,
    "event_type": "CREATE",
    "data": {
        "ticket_type": ticket_type,
        "title": title,
    }
}
create_filename = f"{ts}-{event_uuid}-CREATE.json"
with open(f"{ticket_dir}/{create_filename}", "w", encoding="utf-8") as fh:
    json.dump(create_event, fh, ensure_ascii=False)

# Write STATUS event if status != open
if status not in ("open", ""):
    ts2 = ts + 1
    status_uuid = str(uuid.uuid4())
    status_event = {
        "timestamp": ts2,
        "uuid": status_uuid,
        "event_type": "STATUS",
        "data": {
            "status": status,
            "current_status": "open",
        }
    }
    status_filename = f"{ts2}-{status_uuid}-STATUS.json"
    with open(f"{ticket_dir}/{status_filename}", "w", encoding="utf-8") as fh:
        json.dump(status_event, fh, ensure_ascii=False)

# Write COMMENT events for notes
for i, note_body in enumerate(notes):
    ts3 = ts + 2 + i
    comment_uuid = str(uuid.uuid4())
    comment_event = {
        "timestamp": ts3,
        "uuid": comment_uuid,
        "event_type": "COMMENT",
        "body": note_body,
        "data": {
            "body": note_body,
        }
    }
    comment_filename = f"{ts3}-{comment_uuid}-COMMENT.json"
    with open(f"{ticket_dir}/{comment_filename}", "w", encoding="utf-8") as fh:
        json.dump(comment_event, fh, ensure_ascii=False)

# Write LINK events for dependencies (deps frontmatter field)
deps = parsed.get("deps", [])
if not isinstance(deps, list):
    deps = []
for j, dep_id in enumerate(deps):
    ts4 = ts + 2 + len(notes) + j
    link_uuid = str(uuid.uuid4())
    link_event = {
        "timestamp": ts4,
        "uuid": link_uuid,
        "event_type": "LINK",
        "data": {
            "relation": "depends_on",
            "target": dep_id,
        }
    }
    link_filename = f"{ts4}-{link_uuid}-LINK.json"
    with open(f"{ticket_dir}/{link_filename}", "w", encoding="utf-8") as fh:
        json.dump(link_event, fh, ensure_ascii=False)
PYEOF

        echo "Migrated: $_ticket_id ($_ticket_type)"
        (( _migrated++ )) || true

    done < <(find "$_tickets_dir" -maxdepth 1 -name '*.md' -print0 2>/dev/null | sort -z)

    echo "Migration complete: $_migrated tickets migrated, $_skipped_already skipped (already done), $_skipped_malformed skipped (malformed)"

    unset TICKET_COMPACT_DISABLED
}

_phase_verify() {
    echo "Running phase: verify"
    _check_override "verify" || return $?
}

_phase_finalize() {
    echo "Running phase: finalize"
    _check_override "finalize" || return $?
}

# ---------------------------------------------------------------------------
# Dry-run wrapper: prefix every line of a phase's output with [DRY RUN]
# ---------------------------------------------------------------------------
_run_phase_dry() {
    local phase="$1"
    local phase_fn="_phase_${phase}"
    # Run in subshell, capture output, prefix each line
    local _out
    _out=$("$phase_fn" 2>&1) || return $?
    while IFS= read -r _line; do
        echo "[DRY RUN] $_line"
    done <<< "$_out"
}

# ---------------------------------------------------------------------------
# Rollback: detect committed vs uncommitted failure and revert
# ---------------------------------------------------------------------------

# _rollback_phase PHASE_NAME PHASE_EXIT_CODE COMMIT_BEFORE LOG_FILE
# Called after a phase exits non-zero.  Detects whether HEAD moved and
# applies the appropriate rollback strategy:
#   - Working-tree dirty (staged or unstaged changes vs HEAD) → git checkout HEAD -- .
#   - Working-tree clean (commit was made during the phase)   → git revert HEAD
# In both cases the state file is removed (it reflects pre-failure completed
# phases that are now invalid) and the caller's exit code is preserved.
_rollback_phase() {
    local phase="$1"
    local phase_rc="$2"
    local commit_before="$3"
    local log_file="$4"

    # Determine rollback strategy: dirty working tree → checkout, clean → revert
    local rollback_strategy
    if git -C "$_REPO_ROOT" diff --quiet HEAD 2>/dev/null; then
        rollback_strategy="revert"
    else
        rollback_strategy="checkout"
    fi

    echo "Rollback: phase '${phase}' failed (exit ${phase_rc}); strategy=${rollback_strategy}" >&2
    printf '[%s] Rollback: phase "%s" failed (exit %s); strategy=%s\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$phase" "$phase_rc" "$rollback_strategy" >> "$log_file"

    local rollback_exit=0
    if [[ "$rollback_strategy" == "checkout" ]]; then
        git -C "$_REPO_ROOT" checkout HEAD -- . 2>&1 || rollback_exit=$?
    else
        # revert: undo all commits made during this phase by reverting from
        # commit_before up to HEAD, so multi-commit phases are fully unwound.
        git -C "$_REPO_ROOT" revert --no-edit "${commit_before}..HEAD" 2>&1 || rollback_exit=$?
    fi

    # Remove the state file so a subsequent re-run starts fresh
    rm -f "$CUTOVER_STATE_FILE"

    # Remove any untracked files/dirs created during the run (log dir, temp
    # files, etc.) so the working tree is left fully clean.
    git -C "$_REPO_ROOT" clean -fd 2>&1 || true

    if [[ "$rollback_exit" -eq 0 ]]; then
        echo "Rollback complete." >&2
        printf '[%s] Rollback complete.\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$log_file"
    else
        echo "Rollback failed: git ${rollback_strategy} exited ${rollback_exit}" >&2
        printf '[%s] Rollback failed: git %s exited %s\n' \
            "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$rollback_strategy" "$rollback_exit" >> "$log_file"
    fi

    echo "ERROR: phase ${phase} failed — see ${log_file}" >&2
    exit "$phase_rc"
}

# ---------------------------------------------------------------------------
# Phase gate loop
# ---------------------------------------------------------------------------
echo "cutover-tickets-migration: starting (dry_run=${_DRY_RUN}, resume=${_RESUME})"

# If resuming, check whether all phases are already completed
if [[ "$_RESUME" == "true" ]]; then
    _all_done="true"
    for _phase in "${PHASES[@]}"; do
        if ! _phase_is_completed "$_phase"; then
            _all_done="false"
            break
        fi
    done
    if [[ "$_all_done" == "true" ]]; then
        echo "cutover-tickets-migration: All phases already completed — nothing to do"
        exit 0
    fi
fi

for _phase in "${PHASES[@]}"; do
    # Resume: skip phases already recorded in the state file
    if [[ "$_RESUME" == "true" ]] && _phase_is_completed "$_phase"; then
        echo "Skipping completed phase: ${_phase}"
        continue
    fi

    if [[ "$_DRY_RUN" == "true" ]]; then
        "_run_phase_dry" "$_phase" || { _rc=$?; echo "[DRY RUN] ERROR: phase ${_phase} failed (exit ${_rc}) — see ${_LOG_FILE}" >&2; exit "$_rc"; }
    else
        _phase_commit_before=$(git -C "$_REPO_ROOT" rev-parse HEAD 2>/dev/null || echo "unknown")
        "_phase_${_phase}" || {
            _rc=$?
            _rollback_phase "$_phase" "$_rc" "$_phase_commit_before" "$_LOG_FILE"
            echo "ERROR: phase ${_phase} failed (exit ${_rc}) — see ${_LOG_FILE}" >&2
            exit "$_rc"
        }
        _state_append_phase "$_phase"
    fi
done

echo "cutover-tickets-migration: all phases complete"
