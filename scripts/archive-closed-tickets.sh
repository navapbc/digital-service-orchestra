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

# ── Find and move closed tickets ──────────────────────────────────────────────
# Only scan .md files at the top level of TICKETS_DIR (not archive/ subdirectory).

archived=0
while IFS= read -r ticket_file; do
    # Extract the status field from YAML frontmatter.
    # Frontmatter is the block between the first two '---' lines.
    # We read only the frontmatter section (awk exits after second ---).
    status=$(awk '
        /^---$/ { n++; if (n == 2) exit; next }
        n == 1 && /^status:/ { gsub(/^status:[[:space:]]*/, ""); print; exit }
    ' "$ticket_file")

    if [ "$status" = "closed" ]; then
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
