#!/usr/bin/env bash
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

# ── Build protected set from transitive dependency chains ────────────────────
# Walk the dep graph of all open/in_progress tickets recursively. Any ticket ID
# reachable as a transitive dependency of an active ticket is protected from
# archival — even if that ticket itself is closed.

# Phase 1: collect deps for every ticket into an associative array (id -> dep ids)
# Scan both .tickets/ and .tickets/archive/ so the transitive graph is complete.
declare -A ticket_deps
declare -A ticket_status
declare -A ticket_location  # "root" or "archive"
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
        ticket_status["$tid"]="$status"
        ticket_deps["$tid"]="$deps_raw"
        ticket_location["$tid"]="$location"
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
            continue
        fi
        dest="$ARCHIVE_DIR/$(basename "$ticket_file")"
        if ! mv "$ticket_file" "$dest"; then
            echo "ERROR: failed to move $ticket_file to $dest" >&2
            exit 1
        fi
        ((archived++))
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
