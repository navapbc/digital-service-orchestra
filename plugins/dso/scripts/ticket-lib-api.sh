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

# ── Platform capability detection ────────────────────────────────────────────
# Detect flock(1) availability at source-time so callers and internal functions
# can branch without repeated command -v calls.
command -v flock >/dev/null 2>&1 && _ticketlib_has_flock=1 || _ticketlib_has_flock=0

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
# Uses bash+jq event reduction — zero python3 subprocess spawns on the default path.
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
            # REVIEW-DEFENSE: 2>/dev/null suppresses git error noise; REPO_ROOT-empty is pre-existing behavior
            # (empty REPO_ROOT → TRACKER_DIR="/.tickets-tracker" → file ops fail downstream with clear errors).
            # A hard return 1 here breaks callers (e.g., test setups using isolated $tmp repos) that supply
            # GIT_DIR directly or rely on subshell fall-through. GIT_DISCOVERY_ACROSS_FILESYSTEM=1 is the
            # real fix for alpine volume-mount git discovery; the empty-guard adds no safety value.
            REPO_ROOT="${PROJECT_ROOT:-$(GIT_DISCOVERY_ACROSS_FILESYSTEM=1 git rev-parse --show-toplevel 2>/dev/null)}"
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

        local TICKET_DIR="$TRACKER_DIR/$ticket_id"

        # ── Collect and sort main event files ────────────────────────────────
        # Exclude: .cache.json, PRECONDITIONS files (handled separately below).
        # Sort key: (timestamp, event_type_order, basename).
        # LINK=0, UNLINK=1, all others=99 — preserves LINK-before-UNLINK invariant
        # at same Unix-second timestamp (mirrors Python _sort.py event_sort_key).
        local sorted_files=()
        while IFS= read -r f; do
            [ -n "$f" ] && sorted_files+=("$f")
        done < <(
            # shellcheck disable=SC2012
            # SC2012 suppressed: glob expansion is used; ls is for alphanumeric-safe
            # event filenames (timestamps + UUIDs + event_type — no spaces or special chars).
            ls "$TICKET_DIR"/*.json 2>/dev/null | \
            while IFS= read -r fp; do
                local base
                base="$(basename "$fp")"
                [[ "$base" == ".cache.json" ]] && continue
                [[ "$base" == *-PRECONDITIONS.json ]] && continue
                [[ "$base" == *-PRECONDITIONS-SNAPSHOT.json ]] && continue
                echo "$fp"
            done | \
            while IFS= read -r fp; do
                local base ts stem etype order
                base="$(basename "$fp")"
                ts="${base%%-*}"
                stem="${base%.json}"
                etype="${stem##*-}"
                # bash 3.2: case patterns inside <(...) process substitutions
                # cause parse errors (`)` is mistaken for closing paren).
                # Use if/elif instead.
                if [ "$etype" = "LINK" ]; then
                    order=0
                elif [ "$etype" = "UNLINK" ]; then
                    order=1
                else
                    order=99
                fi
                printf '%s\t%02d\t%s\t%s\n' "$ts" "$order" "$base" "$fp"
            done | sort -t$'\t' -k1,1 -k2,2n -k3,3 | cut -f4
        )

        # ── jq event-reducer program ──────────────────────────────────────────
        # Implements the same event-sourcing logic as ticket_reducer/_api.py.
        # Supports: CREATE, STATUS, COMMENT, LINK, UNLINK, EDIT, ARCHIVED,
        # BRIDGE_ALERT, REVERT, SNAPSHOT. Unknown types are silently ignored.
        # REVIEW-DEFENSE: jq is used here as the zero-python3 JSON processor for
        # the ticket show bash-native path (epic 78fc-3858, story 564c-e391).
        # shellcheck disable=SC2016
        # SC2016 suppressed: single quotes intentional — _JQ_REDUCE is a jq program
        # where $-references are jq variables (not shell), not shell expansions.
        local _JQ_REDUCE='
def initial_state($tid):
  {
    ticket_id: $tid,
    ticket_type: null,
    title: null,
    status: "open",
    author: null,
    created_at: null,
    env_id: null,
    parent_id: null,
    priority: null,
    assignee: null,
    description: "",
    tags: [],
    comments: [],
    deps: [],
    bridge_alerts: [],
    reverts: [],
    file_impact: [],
    preconditions_summary: {status: "pre-manifest"}
  };

def _editable_keys:
  ["ticket_id","ticket_type","title","status","author","created_at","env_id",
   "parent_id","priority","assignee","description","tags","comments","deps",
   "bridge_alerts","reverts"];

def apply_event(ev):
  if ev.event_type == "CREATE" then
    . + {
      ticket_type: ev.data.ticket_type,
      title: ev.data.title,
      author: ev.author,
      created_at: ev.timestamp,
      env_id: ev.env_id,
      parent_id: (if (ev.data.parent_id? // "") == "" then null
                  else ev.data.parent_id end),
      priority:    (ev.data.priority?  // null),
      assignee:    (ev.data.assignee?  // null),
      description: (ev.data.description? // ""),
      tags:        (ev.data.tags? // [])
    }
  elif ev.event_type == "STATUS" then
    .status = ev.data.status
  elif ev.event_type == "COMMENT" then
    .comments += [{
      body: (if ev.data.body == null then ""
             elif (ev.data.body | type) == "string" then ev.data.body
             else (ev.data.body | tostring)
             end),
      author:    ev.author,
      timestamp: ev.timestamp
    }]
  elif ev.event_type == "LINK" then
    .deps += [{
      target_id: ((ev.data.target_id? // ev.data.target?) // ""),
      relation:  (ev.data.relation? // ""),
      link_uuid:  ev.uuid
    }]
  elif ev.event_type == "UNLINK" then
    .deps = [.deps[] | select(.link_uuid != ev.data.link_uuid)]
  elif ev.event_type == "EDIT" then
    reduce ((ev.data.fields? // {}) | to_entries[]) as $field (.;
      if $field.key == "tags" then
        if   ($field.value | type) == "array"  then .tags = $field.value
        elif ($field.value | type) == "string" then
          .tags = [($field.value | split(","))[] |
                   gsub("^\\s+|\\s+$"; "") | select(length > 0)]
        else .tags = []
        end
      elif ([_editable_keys[] == $field.key] | any) then
        .[$field.key] = $field.value
      else .
      end
    )
  elif ev.event_type == "ARCHIVED" then
    .archived = true
  elif ev.event_type == "BRIDGE_ALERT" then
    ((ev.data.alert_type? // ev.data.reason? // ev.data.detail?) // "") as $reason |
    if ev.data.resolved? // false then
      ((ev.data.resolves_uuid? // ev.data.alert_uuid?) // "") as $target |
      if ([.bridge_alerts[] | select(.uuid == $target)] | length) > 0 then
        .bridge_alerts = [.bridge_alerts[] |
          if .uuid == $target then .resolved = true else . end]
      else
        .bridge_alerts += [{uuid: ev.uuid, reason: $reason,
                            timestamp: ev.timestamp, resolved: true}]
      end
    else
      .bridge_alerts += [{uuid: ev.uuid, reason: $reason,
                          timestamp: ev.timestamp, resolved: false}]
    end
  elif ev.event_type == "REVERT" then
    .reverts += [{
      uuid:              ev.uuid,
      target_event_uuid: (ev.data.target_event_uuid? // null),
      target_event_type: (ev.data.target_event_type? // null),
      reason:            (ev.data.reason? // ""),
      timestamp:          ev.timestamp,
      author:             ev.author
    }]
  elif ev.event_type == "SNAPSHOT" then
    reduce ((ev.data.compiled_state? // {}) | to_entries[]) as $field (.;
      .[$field.key] = $field.value
    )
  elif ev.event_type == "FILE_IMPACT" then
    .file_impact = (ev.data.file_impact // [])
  else .
  end;

reduce $_events[] as $ev (initial_state($TID); apply_event($ev))
'

        # ── Validate and reduce event files (skip corrupt JSON gracefully) ────
        # Pipe each file through `jq -c .` first to pre-validate; corrupt files
        # produce no output and are silently excluded (mirrors Python try/except).
        local state
        if [ "${#sorted_files[@]}" -eq 0 ]; then
            echo "Error: ticket \"$ticket_id\" has no events" >&2
            return 1
        fi

        # Write validated events to a temp file; jq --slurpfile reads multiple
        # top-level JSON values and wraps them in an array as $_events.
        local _valid_tmp
        _valid_tmp=$(mktemp)
        # shellcheck disable=SC2064
        trap "rm -f '$_valid_tmp'" EXIT
        local f
        for f in "${sorted_files[@]}"; do
            jq -c '.' "$f" 2>/dev/null >> "$_valid_tmp" || true
        done

        if [ ! -s "$_valid_tmp" ]; then
            echo "Error: ticket \"$ticket_id\" has no CREATE or SNAPSHOT event" >&2
            return 1
        fi

        # Run reducer: $_events is the array of all validated events (from --slurpfile)
        state=$(jq -n --arg TID "$ticket_id" --slurpfile _events "$_valid_tmp" "$_JQ_REDUCE" \
                2>/dev/null)
        local _jq_exit=$?
        rm -f "$_valid_tmp"
        if [ "$_jq_exit" -ne 0 ] || [ -z "$state" ]; then
            echo "Error: failed to reduce ticket \"$ticket_id\"" >&2
            return 1
        fi

        # Verify CREATE event was present (ticket_type must be non-null after reduction)
        local _ttype
        _ttype=$(printf '%s' "$state" | jq -r '.ticket_type // empty' 2>/dev/null)
        if [ -z "$_ttype" ]; then
            echo "Error: ticket \"$ticket_id\" has no CREATE or SNAPSHOT event" >&2
            return 1
        fi

        # ── Compute preconditions_summary ─────────────────────────────────────
        # Scan *-PRECONDITIONS.json files separately (not part of main event replay).
        # Skips corrupt files gracefully; skips PRECONDITIONS-SNAPSHOT files
        # (handled in the same pass via -PRECONDITIONS-SNAPSHOT.json pattern).
        local _precond_summary='{"status":"pre-manifest"}'
        local _precond_files=()
        while IFS= read -r _pf; do
            [ -n "$_pf" ] && _precond_files+=("$_pf")
        done < <(
            # Use find to avoid ls|grep (SC2010); exclude PRECONDITIONS-SNAPSHOT files.
            find "$TICKET_DIR" -maxdepth 1 -name '*-PRECONDITIONS.json' \
                ! -name '*-PRECONDITIONS-SNAPSHOT.json' 2>/dev/null | sort || true
        )
        # Also check for PRECONDITIONS-SNAPSHOT (compacted form)
        local _precond_snap
        _precond_snap=$(
            find "$TICKET_DIR" -maxdepth 1 -name '*-PRECONDITIONS-SNAPSHOT.json' \
                ! -name '*.retired' 2>/dev/null | sort | tail -1 || true
        )
        if [ -n "$_precond_snap" ]; then
            # Compacted PRECONDITIONS snapshot — read directly
            _precond_summary=$(jq -c '
                .data // . |
                {status: "present",
                 manifest_depth: (.manifest_depth? // 0),
                 gate_verdicts:  (.gate_verdicts?  // {}),
                 source_count:   (.source_count?   // 1),
                 compacted:      true}
            ' "$_precond_snap" 2>/dev/null) || _precond_summary='{"status":"pre-manifest"}'
        elif [ "${#_precond_files[@]}" -gt 0 ]; then
            # Flat PRECONDITIONS events — LWW-merge by (gate_name,session_id,worktree_id)
            _precond_summary=$(
                for _pf in "${_precond_files[@]}"; do
                    jq -c '.' "$_pf" 2>/dev/null || true
                done | jq -n '
                reduce inputs as $ev (
                    {};
                    if ($ev | has("event_type")) and ($ev.event_type == "PRECONDITIONS") then
                        (($ev.data.gate_name?    // "") + "|" +
                         ($ev.data.session_id?   // "") + "|" +
                         ($ev.data.worktree_id?  // "")) as $key |
                        if has($key) then
                            if ($ev.timestamp? // 0) > .[$key]._ts
                            then .[$key] = ($ev.data + {_ts: ($ev.timestamp? // 0)})
                            else .
                            end
                        else .[$key] = ($ev.data + {_ts: ($ev.timestamp? // 0)})
                        end
                    else .
                    end
                ) |
                to_entries |
                if length == 0 then {status: "pre-manifest"}
                else {
                    status:          "present",
                    manifest_depth:  ([.[].value.manifest_depth? // 0] | max // 0),
                    gate_verdicts:   (reduce .[].value.gate_verdicts? as $gv
                                       ({}; . + ($gv // {})))
                }
                end
                ' 2>/dev/null
            ) || _precond_summary='{"status":"pre-manifest"}'
        fi

        # Merge preconditions_summary into state
        state=$(printf '%s' "$state" | \
                jq --argjson ps "$_precond_summary" \
                   '.preconditions_summary = $ps' 2>/dev/null) || true

        # ── Output ────────────────────────────────────────────────────────────
        if [ "$format" = "llm" ]; then
            # LLM format: rename keys, strip nulls and empty arrays, minify.
            # Mirrors ticket_reducer/llm_format.py to_llm() key mapping exactly.
            printf '%s' "$state" | jq -c '
                # Build renamed dict; use null as sentinel for "omit this key"
                {
                    id:   .ticket_id,
                    t:    .ticket_type,
                    ttl:  .title,
                    st:   .status,
                    au:   .author,
                    pid:  .parent_id,
                    pr:   .priority,
                    asn:  .assignee,
                    desc: .description,
                    tg:   (if (.tags | length)     > 0 then .tags else null end),
                    cm:   (if (.comments | length) > 0
                           then [.comments[] |
                                 {b: .body, au: .author} |
                                 with_entries(select(.value != null))]
                           else null end),
                    dp:   (if (.deps | length)     > 0
                           then [.deps[] |
                                 {tid: .target_id, r: .relation} |
                                 with_entries(select(.value != null))]
                           else null end),
                    cf:   (if ((.conflicts? // []) | length) > 0
                           then .conflicts else null end)
                } | with_entries(select(.value != null))
            ' 2>/dev/null
        else
            # Default format: pretty-printed JSON
            printf '%s' "$state" | jq '.' 2>/dev/null
            # Emit bridge-alert warning to stderr (mirrors ticket-show.sh behaviour)
            local _unresolved
            _unresolved=$(printf '%s' "$state" | \
                          jq '[.bridge_alerts[] | select(.resolved == false)] | length' \
                          2>/dev/null) || _unresolved=0
            if [ "${_unresolved:-0}" -gt 0 ]; then
                printf 'WARNING: ticket %s has %s unresolved bridge alert(s). Run: ticket bridge-status for details.\n' \
                    "$ticket_id" "$_unresolved" >&2
            fi
        fi
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
            # REVIEW-DEFENSE: 2>/dev/null suppresses git error noise; REPO_ROOT-empty is pre-existing behavior
            # (empty REPO_ROOT → TRACKER_DIR="/.tickets-tracker" → file ops fail downstream with clear errors).
            # A hard return 1 here breaks callers (e.g., test setups using isolated $tmp repos) that supply
            # GIT_DIR directly or rely on subshell fall-through. GIT_DISCOVERY_ACROSS_FILESYSTEM=1 is the
            # real fix for alpine volume-mount git discovery; the empty-guard adds no safety value.
            REPO_ROOT="${PROJECT_ROOT:-$(GIT_DISCOVERY_ACROSS_FILESYSTEM=1 git rev-parse --show-toplevel 2>/dev/null)}"
            TRACKER_DIR="$REPO_ROOT/.tickets-tracker"
        fi

        local format="default"
        local include_archived=""
        local filter_type=""
        local filter_status=""
        local filter_parent=""
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
                    filter_parent="${arg#--parent=}"
                    ;;
                --help|-h)
                    echo "Usage: ticket list [--format=llm] [--include-archived] [--type=<type>] [--status=<status>] [--parent=<id>]" >&2
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
            _PARENT_FILTER="$filter_parent" \
            _SCRIPT_DIR="$_TICKETLIB_DIR" python3 -c "
import sys, os, json
sys.path.insert(0, os.environ['_SCRIPT_DIR'])
from ticket_reducer import reduce_all_tickets
from ticket_reducer.llm_format import to_llm

tracker_dir = os.environ['_TRACKER_DIR']
include_archived = os.environ.get('_INCLUDE_ARCHIVED', '') == 'true'
type_filter = os.environ.get('_TYPE_FILTER', '')
status_filter = os.environ.get('_STATUS_FILTER', '')
parent_filter = os.environ.get('_PARENT_FILTER', '')

results = reduce_all_tickets(tracker_dir, exclude_archived=not include_archived)
if status_filter not in ('error', 'fsck_needed'):
    results = [t for t in results if t.get('status') not in ('error', 'fsck_needed')]
if type_filter:
    results = [t for t in results if t.get('ticket_type') == type_filter]
if status_filter:
    status_values = {s.strip() for s in status_filter.split(',')}
    results = [t for t in results if t.get('status') in status_values]
if parent_filter:
    results = [t for t in results if t.get('parent_id') == parent_filter]
for t in results:
    print(json.dumps(to_llm(t), ensure_ascii=False, separators=(',', ':')))
"
        else
            _TRACKER_DIR="$TRACKER_DIR" _INCLUDE_ARCHIVED="$include_archived" \
            _TYPE_FILTER="$filter_type" _STATUS_FILTER="$filter_status" \
            _PARENT_FILTER="$filter_parent" \
            _SCRIPT_DIR="$_TICKETLIB_DIR" python3 -c "
import sys, os, json
sys.path.insert(0, os.environ['_SCRIPT_DIR'])
from ticket_reducer import reduce_all_tickets

tracker_dir = os.environ['_TRACKER_DIR']
include_archived = os.environ.get('_INCLUDE_ARCHIVED', '') == 'true'
type_filter = os.environ.get('_TYPE_FILTER', '')
status_filter = os.environ.get('_STATUS_FILTER', '')
parent_filter = os.environ.get('_PARENT_FILTER', '')

results = reduce_all_tickets(tracker_dir, exclude_archived=not include_archived)
if status_filter not in ('error', 'fsck_needed'):
    results = [t for t in results if t.get('status') not in ('error', 'fsck_needed')]
if type_filter:
    results = [t for t in results if t.get('ticket_type') == type_filter]
if status_filter:
    status_values = {s.strip() for s in status_filter.split(',')}
    results = [t for t in results if t.get('status') in status_values]
if parent_filter:
    results = [t for t in results if t.get('parent_id') == parent_filter]
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
            # REVIEW-DEFENSE: 2>/dev/null suppresses git error noise; REPO_ROOT-empty is pre-existing behavior
            # (empty REPO_ROOT → TRACKER_DIR="/.tickets-tracker" → file ops fail downstream with clear errors).
            # A hard return 1 here breaks callers (e.g., test setups using isolated $tmp repos) that supply
            # GIT_DIR directly or rely on subshell fall-through. GIT_DISCOVERY_ACROSS_FILESYSTEM=1 is the
            # real fix for alpine volume-mount git discovery; the empty-guard adds no safety value.
            REPO_ROOT="${PROJECT_ROOT:-$(GIT_DISCOVERY_ACROSS_FILESYSTEM=1 git rev-parse --show-toplevel 2>/dev/null)}"
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
            # REVIEW-DEFENSE: 2>/dev/null suppresses git error noise; REPO_ROOT-empty is pre-existing behavior
            # (empty REPO_ROOT → TRACKER_DIR="/.tickets-tracker" → file ops fail downstream with clear errors).
            # A hard return 1 here breaks callers (e.g., test setups using isolated $tmp repos) that supply
            # GIT_DIR directly or rely on subshell fall-through. GIT_DISCOVERY_ACROSS_FILESYSTEM=1 is the
            # real fix for alpine volume-mount git discovery; the empty-guard adds no safety value.
            REPO_ROOT="${PROJECT_ROOT:-$(GIT_DISCOVERY_ACROSS_FILESYSTEM=1 git rev-parse --show-toplevel 2>/dev/null)}"
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

# ── ticket_set_file_impact ────────────────────────────────────────────────────
# Write a FILE_IMPACT event recording which files are affected by a ticket.
ticket_set_file_impact() {
    if [ "${DSO_TICKET_LEGACY:-0}" = "1" ]; then
        echo "Error: ticket set-file-impact not available in legacy mode" >&2
        return 1
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
            # REVIEW-DEFENSE: 2>/dev/null suppresses git error noise; REPO_ROOT-empty is pre-existing behavior
            # (empty REPO_ROOT → TRACKER_DIR="/.tickets-tracker" → file ops fail downstream with clear errors).
            # A hard return 1 here breaks callers (e.g., test setups using isolated $tmp repos) that supply
            # GIT_DIR directly or rely on subshell fall-through. GIT_DISCOVERY_ACROSS_FILESYSTEM=1 is the
            # real fix for alpine volume-mount git discovery; the empty-guard adds no safety value.
            REPO_ROOT="${PROJECT_ROOT:-$(GIT_DISCOVERY_ACROSS_FILESYSTEM=1 git rev-parse --show-toplevel 2>/dev/null)}"
            TRACKER_DIR="$REPO_ROOT/.tickets-tracker"
        fi

        if [ $# -lt 2 ]; then
            echo "Usage: ticket set-file-impact <ticket_id> <json_array>" >&2
            return 1
        fi

        local ticket_id="$1"
        local json_array="$2"

        if [ -z "$ticket_id" ]; then
            echo "Error: ticket_id must be non-empty" >&2
            return 1
        fi

        # REVIEW-DEFENSE: jq is used here for input validation only — same approved
        # exception as ticket_show (epic 78fc-3858, story 564c-e391). python3 would
        # require a subshell + subprocess; jq is already the project-standard JSON
        # processor on the bash-native path and is available wherever ticket-lib-api.sh runs.
        # Validate: must be valid JSON
        if ! printf '%s' "$json_array" | jq -e . >/dev/null 2>&1; then
            echo "Error: file_impact argument is not valid JSON" >&2
            return 1
        fi

        # Validate: must be a JSON array (not object, not scalar)
        local json_type
        json_type=$(printf '%s' "$json_array" | jq -r 'type' 2>/dev/null) || json_type="unknown"
        if [ "$json_type" != "array" ]; then
            echo "Error: file_impact argument must be a JSON array, got '$json_type'" >&2
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

        local temp_event array_file
        temp_event=$(mktemp "$TRACKER_DIR/.tmp-file-impact-XXXXXX")
        array_file=$(mktemp "$TRACKER_DIR/.tmp-fi-array-XXXXXX")
        # shellcheck disable=SC2064
        trap "rm -f '$temp_event' '$array_file'" EXIT
        printf '%s' "$json_array" > "$array_file"

        python3 -c "
import json, sys, time, uuid

with open(sys.argv[3], 'r', encoding='utf-8') as af:
    file_impact = json.load(af)

event = {
    'timestamp': time.time_ns(),
    'uuid': str(uuid.uuid4()),
    'event_type': 'FILE_IMPACT',
    'env_id': sys.argv[1],
    'author': sys.argv[2],
    'data': {
        'file_impact': file_impact
    }
}

with open(sys.argv[4], 'w', encoding='utf-8') as f:
    json.dump(event, f, ensure_ascii=False)
" "$env_id" "$author" "$array_file" "$temp_event" || {
            rm -f "$temp_event" "$array_file"
            echo "Error: failed to build FILE_IMPACT event JSON" >&2
            return 1
        }
        rm -f "$array_file"

        write_commit_event "$ticket_id" "$temp_event" || {
            rm -f "$temp_event"
            echo "Error: failed to write and commit FILE_IMPACT event" >&2
            return 1
        }

        rm -f "$temp_event"
    )
}

# ── ticket_get_file_impact ────────────────────────────────────────────────────
# Read the compiled file_impact array for a ticket.
ticket_get_file_impact() {
    if [ "${DSO_TICKET_LEGACY:-0}" = "1" ]; then
        echo "Error: ticket get-file-impact not available in legacy mode" >&2
        return 1
    fi

    (
        set -euo pipefail

        unset GIT_DIR GIT_INDEX_FILE GIT_WORK_TREE GIT_COMMON_DIR 2>/dev/null || true

        local TRACKER_DIR
        if [ -n "${TICKETS_TRACKER_DIR:-}" ]; then
            TRACKER_DIR="$TICKETS_TRACKER_DIR"
        else
            local REPO_ROOT
            # REVIEW-DEFENSE: 2>/dev/null suppresses git error noise; REPO_ROOT-empty is pre-existing behavior
            # (empty REPO_ROOT → TRACKER_DIR="/.tickets-tracker" → file ops fail downstream with clear errors).
            # A hard return 1 here breaks callers (e.g., test setups using isolated $tmp repos) that supply
            # GIT_DIR directly or rely on subshell fall-through. GIT_DISCOVERY_ACROSS_FILESYSTEM=1 is the
            # real fix for alpine volume-mount git discovery; the empty-guard adds no safety value.
            REPO_ROOT="${PROJECT_ROOT:-$(GIT_DISCOVERY_ACROSS_FILESYSTEM=1 git rev-parse --show-toplevel 2>/dev/null)}"
            TRACKER_DIR="$REPO_ROOT/.tickets-tracker"
        fi

        if [ $# -lt 1 ]; then
            echo "Usage: ticket get-file-impact <ticket_id>" >&2
            return 1
        fi

        local ticket_id="$1"

        if [ -z "$ticket_id" ]; then
            echo "Error: ticket_id must be non-empty" >&2
            return 1
        fi

        if [ ! -d "$TRACKER_DIR/$ticket_id" ]; then
            echo "[]"
            return 0
        fi

        # Collect and sort event files (same pattern as ticket_show)
        local sorted_files=()
        while IFS= read -r -d '' f; do
            sorted_files+=("$f")
        done < <(find "$TRACKER_DIR/$ticket_id" -maxdepth 1 -name '*.json' ! -name '.*' \
            -print0 2>/dev/null | sort -z)

        if [ "${#sorted_files[@]}" -eq 0 ]; then
            echo "[]"
            return 0
        fi

        # REVIEW-DEFENSE: SC2016 suppressed — single quotes are intentional; $-refs are jq variables.
        # shellcheck disable=SC2016
        local _JQ_REDUCE='
def initial_state($tid):
  {
    ticket_id: $tid,
    ticket_type: null,
    title: null,
    status: "open",
    author: null,
    created_at: null,
    env_id: null,
    parent_id: null,
    priority: null,
    assignee: null,
    description: "",
    tags: [],
    comments: [],
    deps: [],
    bridge_alerts: [],
    reverts: [],
    file_impact: [],
    preconditions_summary: {status: "pre-manifest"}
  };

def apply_event(ev):
  if ev.event_type == "CREATE" then
    . + {
      ticket_type: ev.data.ticket_type,
      title: ev.data.title,
      author: ev.author,
      created_at: ev.timestamp,
      env_id: ev.env_id,
      parent_id: (if (ev.data.parent_id? // "") == "" then null
                  else ev.data.parent_id end),
      priority:    (ev.data.priority?  // null),
      assignee:    (ev.data.assignee?  // null),
      description: (ev.data.description? // ""),
      tags:        (ev.data.tags? // [])
    }
  elif ev.event_type == "STATUS" then
    .status = ev.data.status
  elif ev.event_type == "COMMENT" then
    .comments += [{
      body: (if ev.data.body == null then ""
             elif (ev.data.body | type) == "string" then ev.data.body
             else (ev.data.body | tostring)
             end),
      author:    ev.author,
      timestamp: ev.timestamp
    }]
  elif ev.event_type == "LINK" then
    .deps += [{
      target_id: ((ev.data.target_id? // ev.data.target?) // ""),
      relation:  (ev.data.relation? // ""),
      link_uuid:  ev.uuid
    }]
  elif ev.event_type == "UNLINK" then
    .deps = [.deps[] | select(.link_uuid != ev.data.link_uuid)]
  elif ev.event_type == "EDIT" then
    reduce ((ev.data.fields? // {}) | to_entries[]) as $field (.;
      if $field.key == "tags" then
        if   ($field.value | type) == "array"  then .tags = $field.value
        elif ($field.value | type) == "string" then
          .tags = [($field.value | split(","))[] |
                   gsub("^\\s+|\\s+$"; "") | select(length > 0)]
        else .tags = []
        end
      elif ([["ticket_id","ticket_type","title","status","author","created_at","env_id","parent_id","priority","assignee","description","tags","comments","deps","bridge_alerts","reverts"][] == $field.key] | any) then
        .[$field.key] = $field.value
      else .
      end
    )
  elif ev.event_type == "ARCHIVED" then
    .archived = true
  elif ev.event_type == "BRIDGE_ALERT" then
    ((ev.data.alert_type? // ev.data.reason? // ev.data.detail?) // "") as $reason |
    if ev.data.resolved? // false then
      ((ev.data.resolves_uuid? // ev.data.alert_uuid?) // "") as $target |
      if ([.bridge_alerts[] | select(.uuid == $target)] | length) > 0 then
        .bridge_alerts = [.bridge_alerts[] |
          if .uuid == $target then .resolved = true else . end]
      else
        .bridge_alerts += [{uuid: ev.uuid, reason: $reason,
                            timestamp: ev.timestamp, resolved: true}]
      end
    else
      .bridge_alerts += [{uuid: ev.uuid, reason: $reason,
                          timestamp: ev.timestamp, resolved: false}]
    end
  elif ev.event_type == "REVERT" then
    .reverts += [{
      uuid:              ev.uuid,
      target_event_uuid: (ev.data.target_event_uuid? // null),
      target_event_type: (ev.data.target_event_type? // null),
      reason:            (ev.data.reason? // ""),
      timestamp:          ev.timestamp,
      author:             ev.author
    }]
  elif ev.event_type == "SNAPSHOT" then
    reduce ((ev.data.compiled_state? // {}) | to_entries[]) as $field (.;
      .[$field.key] = $field.value
    )
  elif ev.event_type == "FILE_IMPACT" then
    .file_impact = (ev.data.file_impact // [])
  else .
  end;

reduce $_events[] as $ev (initial_state($TID); apply_event($ev))
'

        # REVIEW-DEFENSE: jq is used here for event reduction — same approved exception
        # as ticket_show (epic 78fc-3858, story 564c-e391). ticket_get_file_impact reuses
        # the shared $_JQ_REDUCE program (defined in ticket_show's scope and available via
        # the _ticketlib_dispatch subshell) to avoid duplicating reducer logic.
        local _valid_tmp
        _valid_tmp=$(mktemp)
        # shellcheck disable=SC2064
        trap "rm -f '$_valid_tmp'" EXIT
        local f
        for f in "${sorted_files[@]}"; do
            jq -c '.' "$f" 2>/dev/null >> "$_valid_tmp" || true
        done

        if [ ! -s "$_valid_tmp" ]; then
            echo "[]"
            rm -f "$_valid_tmp"
            return 0
        fi

        local fi_out
        fi_out=$(jq -c -n --arg TID "$ticket_id" --slurpfile _events "$_valid_tmp" \
            "$_JQ_REDUCE | .file_impact // []" 2>/dev/null) || fi_out="[]"
        rm -f "$_valid_tmp"

        echo "$fi_out"
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
            # REVIEW-DEFENSE: 2>/dev/null suppresses git error noise; REPO_ROOT-empty is pre-existing behavior
            # (empty REPO_ROOT → TRACKER_DIR="/.tickets-tracker" → file ops fail downstream with clear errors).
            # A hard return 1 here breaks callers (e.g., test setups using isolated $tmp repos) that supply
            # GIT_DIR directly or rely on subshell fall-through. GIT_DISCOVERY_ACROSS_FILESYSTEM=1 is the
            # real fix for alpine volume-mount git discovery; the empty-guard adds no safety value.
            REPO_ROOT="${PROJECT_ROOT:-$(GIT_DISCOVERY_ACROSS_FILESYSTEM=1 git rev-parse --show-toplevel 2>/dev/null)}"
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

# ── ticket_exists ─────────────────────────────────────────────────────────────
ticket_exists() {
    # No DSO_TICKET_LEGACY path: ticket-exists.sh is the canonical implementation (no prior script).
    bash "$_TICKETLIB_DIR/ticket-exists.sh" "$@"
    return $?
}

# ── ticket_validate ────────────────────────────────────────────────────────────
ticket_validate() {
    bash "$_TICKETLIB_DIR/validate-issues.sh" "$@"
    return $?
}

# ── ticket_classify ────────────────────────────────────────────────────────────
ticket_classify() {
    bash "$_TICKETLIB_DIR/classify-task.sh" "$@"
    return $?
}

# ── ticket_clarity_check ───────────────────────────────────────────────────────
ticket_clarity_check() {
    bash "$_TICKETLIB_DIR/ticket-clarity-check.sh" "$@"
    return $?
}

# ── ticket_check_ac ────────────────────────────────────────────────────────────
ticket_check_ac() {
    bash "$_TICKETLIB_DIR/check-acceptance-criteria.sh" "$@"
    return $?
}

# ── ticket_quality_check ───────────────────────────────────────────────────────
ticket_quality_check() {
    bash "$_TICKETLIB_DIR/issue-quality-check.sh" "$@"
    return $?
}

# ── ticket_summary ─────────────────────────────────────────────────────────────
ticket_summary() {
    bash "$_TICKETLIB_DIR/issue-summary.sh" "$@"
    return $?
}

# ── ticket_ready ───────────────────────────────────────────────────────────────
ticket_ready() {
    # No DSO_TICKET_LEGACY path: ticket-ready.sh is the canonical implementation (no prior script).
    bash "$_TICKETLIB_DIR/ticket-ready.sh" "$@"
    return $?
}

# ── ticket_list_epics ──────────────────────────────────────────────────────────
ticket_list_epics() {
    # No DSO_TICKET_LEGACY path: delegates to sprint-list-epics.sh (canonical; no prior script).
    bash "$_TICKETLIB_DIR/ticket-list-epics.sh" "$@"
    return $?
}

# ── ticket_list_descendants ────────────────────────────────────────────────────
ticket_list_descendants() {
    # No DSO_TICKET_LEGACY path: ticket-list-descendants.sh is the canonical implementation (no prior script).
    bash "$_TICKETLIB_DIR/ticket-list-descendants.sh" "$@"
    return $?
}

# ── ticket_next_batch ─────────────────────────────────────────────────────────
ticket_next_batch() {
    # No DSO_TICKET_LEGACY path: ticket-next-batch.sh is the canonical implementation (no prior script).
    bash "$_TICKETLIB_DIR/ticket-next-batch.sh" "$@"
    return $?
}

# ── ticket_archive ────────────────────────────────────────────────────────────
# Archive an open ticket by writing an ARCHIVED event and the .archived marker.
#
# Contract:
#   - Only works on tickets with status=open (rejects in_progress, closed, blocked)
#   - Idempotent: second call on an already-archived ticket exits 0 silently
#   - Does NOT require closing the ticket first
#   - After success, ticket is excluded from 'ticket list' (default)
#   - 'ticket list --include-archived' and 'ticket show' still surface the ticket
ticket_archive() {
    (
        set -euo pipefail

        # Unset git hook env vars so git commands target the correct repo.
        # Scoped to this subshell — does not leak to caller.
        unset GIT_DIR GIT_INDEX_FILE GIT_WORK_TREE GIT_COMMON_DIR 2>/dev/null || true

        # Source ticket-lib.sh for write_commit_event.
        # shellcheck source=/dev/null
        source "$_TICKETLIB_DIR/ticket-lib.sh"

        local TRACKER_DIR
        if [ -n "${TICKETS_TRACKER_DIR:-}" ]; then
            TRACKER_DIR="$TICKETS_TRACKER_DIR"
        else
            local REPO_ROOT
            # REVIEW-DEFENSE: 2>/dev/null suppresses git error noise; REPO_ROOT-empty is pre-existing behavior
            # (empty REPO_ROOT → TRACKER_DIR="/.tickets-tracker" → file ops fail downstream with clear errors).
            # A hard return 1 here breaks callers (e.g., test setups using isolated $tmp repos) that supply
            # GIT_DIR directly or rely on subshell fall-through. GIT_DISCOVERY_ACROSS_FILESYSTEM=1 is the
            # real fix for alpine volume-mount git discovery; the empty-guard adds no safety value.
            REPO_ROOT="${PROJECT_ROOT:-$(GIT_DISCOVERY_ACROSS_FILESYSTEM=1 git rev-parse --show-toplevel 2>/dev/null)}"
            TRACKER_DIR="$REPO_ROOT/.tickets-tracker"
        fi

        if [ $# -ne 1 ]; then
            echo "Usage: ticket archive <ticket_id>" >&2
            return 1
        fi

        local ticket_id="$1"

        if [ -z "$ticket_id" ]; then
            echo "Error: ticket_id must be non-empty" >&2
            return 1
        fi

        # Ticket directory must exist.
        if [ ! -d "$TRACKER_DIR/$ticket_id" ]; then
            echo "Error: ticket '$ticket_id' does not exist" >&2
            return 1
        fi

        local TICKET_DIR="$TRACKER_DIR/$ticket_id"

        # ── Idempotency check: exit 0 silently if already archived ────────────
        if [ -f "$TICKET_DIR/.archived" ]; then
            return 0
        fi
        # Also check for ARCHIVED event file (marker may be missing after clone)
        if find "$TICKET_DIR" -maxdepth 1 -name '*-ARCHIVED.json' 2>/dev/null | grep -q .; then
            # Write the marker if it was missing, then exit 0
            python3 -c "
import sys
sys.path.insert(0, '$_TICKETLIB_DIR')
from ticket_reducer.marker import write_marker
write_marker(sys.argv[1])
" "$TICKET_DIR" 2>/dev/null || true
            return 0
        fi

        # ── Status gate: only open tickets may be archived ────────────────────
        local current_status
        current_status=$(
            TICKETS_TRACKER_DIR="$TRACKER_DIR" bash "$_TICKETLIB_DIR/ticket" show "$ticket_id" 2>/dev/null \
            | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('status',''))" 2>/dev/null
        ) || current_status=""

        if [ -z "$current_status" ]; then
            echo "Error: could not read status for ticket '$ticket_id'" >&2
            return 1
        fi

        if [ "$current_status" != "open" ]; then
            echo "Error: ticket '$ticket_id' has status '$current_status'; archive only works on open tickets" >&2
            return 1
        fi

        # ── Write ARCHIVED event ──────────────────────────────────────────────
        local env_id author
        env_id=$(cat "$TRACKER_DIR/.env-id" 2>/dev/null || echo "unknown")
        author=$(git config user.name 2>/dev/null || echo "Unknown")

        local temp_event
        temp_event=$(mktemp "$TRACKER_DIR/.tmp-archive-XXXXXX")
        # shellcheck disable=SC2064
        trap "rm -f '$temp_event'" EXIT

        python3 -c "
import json, sys, time, uuid

event = {
    'timestamp': time.time_ns(),
    'uuid': str(uuid.uuid4()),
    'event_type': 'ARCHIVED',
    'env_id': sys.argv[1],
    'author': sys.argv[2],
    'data': {}
}

with open(sys.argv[3], 'w', encoding='utf-8') as f:
    json.dump(event, f, ensure_ascii=False)
" "$env_id" "$author" "$temp_event" || {
            rm -f "$temp_event"
            echo "Error: failed to build ARCHIVED event JSON" >&2
            return 1
        }

        write_commit_event "$ticket_id" "$temp_event" || {
            rm -f "$temp_event"
            echo "Error: failed to write and commit ARCHIVED event" >&2
            return 1
        }

        rm -f "$temp_event"

        # ── Write .archived marker (after event is durably committed) ─────────
        python3 -c "
import sys, os
sys.path.insert(0, '$_TICKETLIB_DIR')
from ticket_reducer.marker import write_marker
write_marker(sys.argv[1])
" "$TICKET_DIR" 2>/dev/null || true

        echo "Archived ticket '$ticket_id'"
    )
}

# ── ticket_delete ─────────────────────────────────────────────────────────────
# Hard-delete a ticket: write UNLINK events, write ARCHIVED event, drop
# .tombstone.json + .archived marker.
#
# Contract:
#   - Requires --user-approved flag (explicit intent gate)
#   - Accepts tickets in any non-deleted status (open, in_progress, closed)
#   - Blocked if any child ticket lacks both .tombstone.json and .archived marker
#   - Writes UNLINK events for all net-active LINK events referencing the ticket
#   - Idempotent: re-invocation against an already-tombstoned ticket completes
#     any missing UNLINKs and exits 0
ticket_delete() {
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
            REPO_ROOT="${PROJECT_ROOT:-$(GIT_DISCOVERY_ACROSS_FILESYSTEM=1 git rev-parse --show-toplevel 2>/dev/null)}"
            TRACKER_DIR="$REPO_ROOT/.tickets-tracker"
        fi

        local user_approved=0
        local ticket_id=""
        local remaining_args=()
        for arg in "$@"; do
            if [ "$arg" = "--user-approved" ]; then
                user_approved=1
            else
                remaining_args+=("$arg")
            fi
        done
        set -- "${remaining_args[@]+"${remaining_args[@]}"}"

        if [ $# -ne 1 ]; then
            echo "Usage: ticket delete <ticket_id> --user-approved" >&2
            return 1
        fi

        ticket_id="$1"

        if [ -z "$ticket_id" ]; then
            echo "Error: ticket_id must be non-empty" >&2
            return 1
        fi

        if [ "$user_approved" -ne 1 ]; then
            echo "Error: ticket delete requires --user-approved flag (this is a destructive operation)" >&2
            echo "Usage: ticket delete <ticket_id> --user-approved" >&2
            return 1
        fi

        if [ ! -d "$TRACKER_DIR/$ticket_id" ]; then
            echo "Error: ticket '$ticket_id' does not exist" >&2
            return 1
        fi

        local TICKET_DIR="$TRACKER_DIR/$ticket_id"

        local already_tombstoned=0
        if [ -f "$TICKET_DIR/.tombstone.json" ]; then
            already_tombstoned=1
        fi

        if [ "$already_tombstoned" -eq 0 ]; then
            # ── Children guard ────────────────────────────────────────────────
            local child_ids
            child_ids=$(python3 - "$TRACKER_DIR" "$ticket_id" <<'PYEOF'
import json, os, sys
from pathlib import Path

tracker_dir = sys.argv[1]
parent_id   = sys.argv[2]

children = []
for entry in sorted(Path(tracker_dir).iterdir()):
    if not entry.is_dir():
        continue
    tid = entry.name
    if tid.startswith('.') or tid == parent_id:
        continue
    tombstone = entry / '.tombstone.json'
    archived  = entry / '.archived'
    if tombstone.is_file() or archived.is_file():
        continue
    # Scan event files for a CREATE event that has this parent_id
    for ef in sorted(entry.glob('*-CREATE.json')):
        try:
            with open(ef, encoding='utf-8') as fh:
                ev = json.load(fh)
            if ev.get('data', {}).get('parent_id') == parent_id:
                children.append(tid)
                break
        except (OSError, json.JSONDecodeError):
            continue
print(' '.join(children))
PYEOF
)
            # set -euo pipefail (active in this subshell) aborts on non-zero python exit.
            if [ -n "$child_ids" ]; then
                echo "Cannot delete ticket '$ticket_id': has non-deleted children: $child_ids" >&2
                return 1
            fi
        fi

        local env_id author
        env_id=$(cat "$TRACKER_DIR/.env-id" 2>/dev/null || echo "unknown")
        author=$(git config user.name 2>/dev/null || echo "Unknown")

        # ── UNLINK scan: all active LINK events referencing this ticket ────────
        # Scan every ticket dir for inbound LINKs (target_id == ticket_id).
        # Also scan the deleted ticket's own dir for outbound LINKs.
        python3 - "$TRACKER_DIR" "$ticket_id" "$env_id" "$author" <<'PYEOF'
import json, os, sys, time, uuid
from pathlib import Path

tracker_dir = sys.argv[1]
deleted_id  = sys.argv[2]
env_id      = sys.argv[3]
author      = sys.argv[4]

import subprocess

def _get_active_links(ticket_dir: Path):
    """Return list of (link_uuid, target_id, relation) for net-active LINKs."""
    all_events = []
    for f in sorted(ticket_dir.glob('*-LINK.json')):
        all_events.append(('LINK', f))
    for f in sorted(ticket_dir.glob('*-UNLINK.json')):
        all_events.append(('UNLINK', f))

    _order = {'LINK': 0, 'UNLINK': 1}
    all_events.sort(key=lambda x: (int(x[1].name.split('-')[0]), _order.get(x[0], 99), x[1].name))

    active = {}
    for etype, f in all_events:
        try:
            with open(f, encoding='utf-8') as fh:
                ev = json.load(fh)
        except (OSError, json.JSONDecodeError):
            continue
        data = ev.get('data', {})
        u = ev.get('uuid', '')
        if etype == 'LINK' and u:
            active[u] = (data.get('target_id', data.get('target', '')), data.get('relation', ''))
        elif etype == 'UNLINK':
            lu = data.get('link_uuid', '')
            if lu:
                active.pop(lu, None)
    return [(u, tid, rel) for u, (tid, rel) in active.items()]


def _write_unlink(source_id, target_id, link_uuid_val):
    """Write an UNLINK event file into source_id's directory; return dest path (no commit)."""
    source_dir = Path(tracker_dir) / source_id
    if not source_dir.is_dir():
        return None
    ts_prefix = str(time.time_ns())
    ev_uuid = str(uuid.uuid4())
    event = {
        'event_type': 'UNLINK',
        'timestamp': int(ts_prefix),
        'uuid': ev_uuid,
        'env_id': env_id,
        'author': author,
        'data': {
            'link_uuid': link_uuid_val,
            'target_id': target_id,
        },
    }
    dest = source_dir / f'{ts_prefix}-{ev_uuid}-UNLINK.json'
    dest.write_text(json.dumps(event, ensure_ascii=False), encoding='utf-8')
    return str(dest)


tracker_path = Path(tracker_dir)

# Collect all UNLINK events; batch-commit in one operation to avoid O(K) git calls.
unlink_files = []

# Scan all ticket dirs for inbound LINKs pointing at deleted_id
for entry in sorted(tracker_path.iterdir()):
    if not entry.is_dir() or entry.name.startswith('.'):
        continue
    source_id = entry.name
    active = _get_active_links(entry)
    for link_uuid_val, target_id, relation in active:
        if target_id == deleted_id:
            f = _write_unlink(source_id, deleted_id, link_uuid_val)
            if f:
                unlink_files.append(f)

# Also scan deleted ticket's own dir for outbound LINKs
deleted_dir = tracker_path / deleted_id
if deleted_dir.is_dir():
    active = _get_active_links(deleted_dir)
    for link_uuid_val, target_id, relation in active:
        f = _write_unlink(deleted_id, target_id, link_uuid_val)
        if f:
            unlink_files.append(f)

# Single batch commit for all UNLINK events (O(1) git operations regardless of link count)
if unlink_files:
    subprocess.run(
        ['git', '-C', tracker_dir, 'add'] + unlink_files,
        check=True, capture_output=True
    )
    subprocess.run(
        ['git', '-C', tracker_dir, 'commit', '-q', '--no-verify',
         '-m', f'ticket: UNLINK {len(unlink_files)} events for deleted {deleted_id}'],
        check=True, capture_output=True
    )

PYEOF
        # set -euo pipefail (active in this subshell) aborts on non-zero python exit.

        if [ "$already_tombstoned" -eq 1 ]; then
            return 0
        fi

        # ── Write ARCHIVED event ──────────────────────────────────────────────
        local temp_event
        temp_event=$(mktemp "$TRACKER_DIR/.tmp-delete-XXXXXX")
        # shellcheck disable=SC2064
        trap "rm -f '$temp_event'" EXIT

        python3 -c "
import json, sys, time, uuid

event = {
    'timestamp': time.time_ns(),
    'uuid': str(uuid.uuid4()),
    'event_type': 'ARCHIVED',
    'env_id': sys.argv[1],
    'author': sys.argv[2],
    'data': {}
}

with open(sys.argv[3], 'w', encoding='utf-8') as f:
    json.dump(event, f, ensure_ascii=False)
" "$env_id" "$author" "$temp_event" || {
            rm -f "$temp_event"
            echo "Error: failed to build ARCHIVED event JSON" >&2
            return 1
        }

        write_commit_event "$ticket_id" "$temp_event" || {
            rm -f "$temp_event"
            echo "Error: failed to write and commit ARCHIVED event" >&2
            return 1
        }

        rm -f "$temp_event"

        # ── Write .tombstone.json ─────────────────────────────────────────────
        python3 -c "
import json, sys
with open(sys.argv[1], 'w', encoding='utf-8') as f:
    json.dump({'status': 'deleted'}, f, ensure_ascii=False)
" "$TICKET_DIR/.tombstone.json" || {
            echo "Error: failed to write .tombstone.json" >&2
            return 1
        }

        git -C "$TRACKER_DIR" add "$TICKET_DIR/.tombstone.json"
        git -C "$TRACKER_DIR" commit -q --no-verify -m "ticket: DELETE $ticket_id"

        # ── Write .archived marker ────────────────────────────────────────────
        python3 -c "
import sys
sys.path.insert(0, '$_TICKETLIB_DIR')
from ticket_reducer.marker import write_marker
write_marker(sys.argv[1])
" "$TICKET_DIR" 2>/dev/null || true

        echo "Deleted ticket '$ticket_id'"

        # ── Emit UNBLOCKED signals ──────────────────────────────────────────────
        # Mirror ticket-transition.sh: detect tickets newly unblocked by this deletion.
        local _batch_close_json
        _batch_close_json=$(python3 "$_TICKETLIB_DIR/ticket-unblock.py" --batch-close "$TRACKER_DIR" "$ticket_id" 2>/dev/null) || true
        if [ -n "$_batch_close_json" ]; then
            local _unblocked_ids
            _unblocked_ids=$(printf '%s' "$_batch_close_json" | python3 -c "
import json, sys
d = json.loads(sys.stdin.read())
ids = d.get('newly_unblocked', [])
print(','.join(ids)) if ids else None
" 2>/dev/null) || _unblocked_ids=""
            if [ -n "$_unblocked_ids" ]; then
                echo "UNBLOCKED: $_unblocked_ids"
            else
                echo "UNBLOCKED: none"
            fi
        else
            echo "UNBLOCKED: none"
        fi
    )
}
