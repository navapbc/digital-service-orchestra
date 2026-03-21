#!/usr/bin/env bash
set -uo pipefail
# archive-closed-tickets.sh — Move closed tickets from .tickets/ to .tickets/archive/
#
# Finds all .tickets/*.md files whose YAML frontmatter status field is "closed",
# moves them to .tickets/archive/ (creating the directory if needed), then reports
# a summary. Emits a WARNING to stderr if the active (non-archived) ticket count
# exceeds 500 after archiving.
#
# Usage:
#   ./scripts/archive-closed-tickets.sh
#
# Environment:
#   TICKETS_DIR   Override the tickets directory (default: <repo-root>/.tickets)
#                 Useful for testing without touching the real ticket store.
#
# Exit codes:
#   0  — success (even if no tickets were archived)
#   1  — I/O error or .tickets/ directory not found

set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || echo "")"
TICKETS_DIR="${TICKETS_DIR:-${REPO_ROOT}/.tickets}"
ARCHIVE_DIR="$TICKETS_DIR/archive"
WARN_THRESHOLD=500

# ── Validate tickets directory ─────────────────────────────────────────────────

if [ ! -d "$TICKETS_DIR" ]; then
    echo "ERROR: tickets directory not found: $TICKETS_DIR" >&2
    exit 1
fi

# ── Create archive directory if needed ────────────────────────────────────────

if ! mkdir -p "$ARCHIVE_DIR"; then
    echo "ERROR: failed to create archive directory: $ARCHIVE_DIR" >&2
    exit 1
fi

TOMBSTONE_DIR="$ARCHIVE_DIR/tombstones"
if ! mkdir -p "$TOMBSTONE_DIR"; then
    echo "ERROR: failed to create tombstone directory: $TOMBSTONE_DIR" >&2
    exit 1
fi

# ── Build protected set from transitive dependency chains ────────────────────
# Walk the dep graph of all open/in_progress tickets recursively. Any ticket ID
# reachable as a transitive dependency of an active ticket is protected from
# archival — even if that ticket itself is closed.

# Phase 1: collect deps for every ticket into an associative array (id -> dep ids)
# Scan both .tickets/ and .tickets/archive/ so the transitive graph is complete.
declare -A ticket_deps
declare -A ticket_status
declare -A ticket_type
declare -A ticket_location  # "root" or "archive"
declare -A ticket_parent
_scan_tickets() {
    local dir="$1" location="$2"
    while IFS= read -r ticket_file; do
        local tid
        tid=$(basename "$ticket_file" .md)
        local status
        status=$(awk '
            /^---$/ { n++; if (n == 2) exit; next }
            n == 1 && /^status:/ { gsub(/^status:[[:space:]]*/, ""); print; exit }
        ' "$ticket_file")
        local deps_raw
        deps_raw=$(awk '
            /^---$/ { n++; if (n == 2) exit; next }
            n == 1 && /^deps:/ { gsub(/^deps:[[:space:]]*\[/, ""); gsub(/\].*/, ""); print; exit }
        ' "$ticket_file")
        local parent_raw
        parent_raw=$(awk '
            /^---$/ { n++; if (n == 2) exit; next }
            n == 1 && /^parent:/ { gsub(/^parent:[[:space:]]*/, ""); gsub(/[[:space:]]*$/, ""); print; exit }
        ' "$ticket_file")
        local type_raw
        type_raw=$(awk '
            /^---$/ { n++; if (n == 2) exit; next }
            n == 1 && /^type:/ { gsub(/^type:[[:space:]]*/, ""); gsub(/[[:space:]]*$/, ""); print; exit }
        ' "$ticket_file")
        ticket_status["$tid"]="$status"
        ticket_deps["$tid"]="$deps_raw"
        ticket_type["$tid"]="$type_raw"
        ticket_location["$tid"]="$location"
        ticket_parent["$tid"]="$parent_raw"
    done < <(find "$dir" -maxdepth 1 -name "*.md" -type f | sort)
}
_scan_tickets "$TICKETS_DIR" "root"
if [[ -d "$ARCHIVE_DIR" ]]; then
    _scan_tickets "$ARCHIVE_DIR" "archive"
fi

# Phase 2: BFS from every active ticket to collect all transitively protected IDs
declare -A protected
_walk_deps() {
    local tid="$1"
    # Skip if already visited
    [[ -n "${protected[$tid]+x}" ]] && return
    protected["$tid"]=1
    # Parse comma-separated deps and recurse
    local deps_str="${ticket_deps[$tid]:-}"
    if [[ -n "$deps_str" ]]; then
        local dep
        while IFS= read -r dep; do
            dep=$(echo "$dep" | tr -d '[:space:]')
            [[ -z "$dep" ]] && continue
            _walk_deps "$dep"
        done <<< "${deps_str//,/$'\n'}"
    fi
}

for tid in "${!ticket_status[@]}"; do
    if [[ "${ticket_status[$tid]}" == "open" || "${ticket_status[$tid]}" == "in_progress" ]]; then
        _walk_deps "$tid"
    fi
done

# Phase 2b: Reverse parent scan — protect parents of open/in_progress children.
# For each active (open/in_progress) ticket that declares a parent field, add
# that parent ticket ID to the protected set. This is separate from the forward
# deps BFS above and handles the case where a closed epic has open child stories
# that reference it only via the parent field (not via deps[]).
for tid in "${!ticket_status[@]}"; do
    if [[ "${ticket_status[$tid]}" == "open" || "${ticket_status[$tid]}" == "in_progress" ]]; then
        local_parent="${ticket_parent[$tid]:-}"
        if [[ -n "$local_parent" ]]; then
            protected["$local_parent"]=1
        fi
    fi
done

# ── Restore archived tickets that belong to active dep chains ─────────────────
# Before archiving, move any ticket in archive/ that is in the protected set
# back to .tickets/ so dependency chains remain intact.

restored=0
for tid in "${!protected[@]}"; do
    if [[ "${ticket_location[$tid]:-}" == "archive" ]]; then
        src="$ARCHIVE_DIR/${tid}.md"
        dest="$TICKETS_DIR/${tid}.md"
        if [[ -f "$src" ]]; then
            if ! mv "$src" "$dest"; then
                echo "ERROR: failed to restore $src to $dest" >&2
                exit 1
            fi
            ticket_location["$tid"]="root"
            ((restored++))
        fi
    fi
done

if [[ "$restored" -gt 0 ]]; then
    echo "Restored ${restored} ticket(s) from archive to active."
fi

# ── Find and move closed tickets ──────────────────────────────────────────────
# Only scan .md files at the top level of TICKETS_DIR (not archive/ subdirectory).
# Skip any ticket in the protected set (transitively depended upon by active tickets).

archived=0
while IFS= read -r ticket_file; do
    tid=$(basename "$ticket_file" .md)
    status="${ticket_status[$tid]:-}"

    if [ "$status" = "closed" ]; then
        # Skip if protected by an active dependency chain
        if [[ -n "${protected[$tid]+x}" ]]; then
            # Build a list of open children that reference this ticket as parent
            child_list=""
            for child_tid in "${!ticket_parent[@]}"; do
                if [[ "${ticket_parent[$child_tid]}" == "$tid" ]]; then
                    child_status="${ticket_status[$child_tid]:-}"
                    if [[ "$child_status" == "open" || "$child_status" == "in_progress" ]]; then
                        child_list="${child_list:+$child_list, }$child_tid"
                    fi
                fi
            done
            if [[ -n "$child_list" ]]; then
                echo "Skipping archive of $tid — open children: $child_list" >&2
            fi
            continue
        fi
        dest="$ARCHIVE_DIR/$(basename "$ticket_file")"
        if ! mv "$ticket_file" "$dest"; then
            echo "ERROR: failed to move $ticket_file to $dest" >&2
            exit 1
        fi
        ((archived++))
        # ── Write tombstone atomically ────────────────────────────────────────
        # Contract: plugins/dso/docs/contracts/tombstone-archive-format.md
        _ticket_type="${ticket_type[$tid]:-}"
        _tombstone_path="$TOMBSTONE_DIR/${tid}.json"
        _tombstone_tmp="${_tombstone_path}.tmp"
        # Idempotency: if tombstone already exists with matching id, skip write
        if [[ -f "$_tombstone_path" ]]; then
            _existing_id=$(_TPATH="$_tombstone_path" python3 -c "import json, os; d=json.load(open(os.environ['_TPATH'])); print(d.get('id',''))" 2>/dev/null || true)
            if [[ "$_existing_id" == "$tid" ]]; then
                : # skip — already written correctly
            else
                echo "ERROR: tombstone id mismatch at $_tombstone_path (expected $tid, found $_existing_id) — system integrity error" >&2
                exit 1
            fi
        else
            if _TID="$tid" _TYPE="$_ticket_type" _OUT="$_tombstone_tmp" python3 -c "
import json, os
data = {'id': os.environ['_TID'], 'type': os.environ['_TYPE'], 'final_status': 'closed'}
with open(os.environ['_OUT'], 'w') as f:
    json.dump(data, f, indent=2)
    f.write('\n')
" 2>/dev/null && mv "$_tombstone_tmp" "$_tombstone_path" 2>/dev/null; then
                : # tombstone written successfully
            else
                rm -f "$_tombstone_tmp" 2>/dev/null || true
                echo "WARNING: tombstone write failed for $tid — archive succeeded but tombstone not written" >&2
            fi
        fi
    fi
done < <(find "$TICKETS_DIR" -maxdepth 1 -name "*.md" -type f | sort)

# ── Count remaining active tickets ────────────────────────────────────────────
# Active = .md files at the top level of TICKETS_DIR (excluding archive/ subdir).

active=$(find "$TICKETS_DIR" -maxdepth 1 -name "*.md" -type f | wc -l | tr -d '[:space:]')

# ── Warn if active count exceeds threshold ────────────────────────────────────

if [ "$active" -gt "$WARN_THRESHOLD" ]; then
    echo "WARNING: active ticket count ($active) exceeds 500 — consider reviewing open issues" >&2
fi

# ── Print summary ──────────────────────────────────────────────────────────────

echo "Archived ${archived} ticket(s). Active count: ${active}."
