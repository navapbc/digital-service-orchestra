#!/usr/bin/env bash
# scripts/bulk-delete-stale-tickets.sh
# Bulk-delete auto-created duplicate bug tickets and stale marker files.
#
# Deletes tickets whose H1 title matches any of these patterns:
#   - Fix recurring hook errors:
#   - Investigate recurring tool error:
#   - Investigate timeout:
#   - Investigate pre-commit timeout:
#
# Also deletes stale marker files in ~/.claude/hook-error-bugs/
# and removes .tickets/.index.json to force index rebuild on next tk command.
#
# Environment overrides (for testing):
#   TICKETS_DIR           — path to .tickets/ directory (default: REPO_ROOT/.tickets)
#   HOOK_ERROR_BUGS_DIR   — path to marker files dir (default: ~/.claude/hook-error-bugs)
#
# Usage:
#   bash scripts/bulk-delete-stale-tickets.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Resolve paths (allow override for testing)
TICKETS_DIR="${TICKETS_DIR:-$REPO_ROOT/.tickets}"
HOOK_ERROR_BUGS_DIR="${HOOK_ERROR_BUGS_DIR:-$HOME/.claude/hook-error-bugs}"

echo "=== bulk-delete-stale-tickets.sh ==="
echo "Tickets dir:  $TICKETS_DIR"
echo "Marker dir:   $HOOK_ERROR_BUGS_DIR"
echo ""

# ── Count before ──────────────────────────────────────────────────────────────
before_count=$(ls "$TICKETS_DIR"/*.md 2>/dev/null | wc -l | tr -d ' ')
echo "Ticket files before: $before_count"

# ── Find and delete auto-created tickets ──────────────────────────────────────
# Match on the H1 title line (starts with '# ') to avoid false positives from
# tickets that merely reference these patterns in their description body.
pattern='^# Fix recurring hook errors:\|^# Investigate recurring tool error:\|^# Investigate timeout:\|^# Investigate pre-commit timeout:'

matching_files=$(grep -l "$pattern" "$TICKETS_DIR"/*.md 2>/dev/null || true)

deleted_count=0
if [[ -n "$matching_files" ]]; then
    while IFS= read -r f; do
        [[ -z "$f" ]] && continue
        echo "Deleting: $(basename "$f")"
        rm "$f"
        (( ++deleted_count ))
    done <<< "$matching_files"
fi

echo ""
echo "Deleted $deleted_count auto-created ticket file(s)."

# ── Delete stale marker files ─────────────────────────────────────────────────
marker_count=0
if [[ -d "$HOOK_ERROR_BUGS_DIR" ]]; then
    while IFS= read -r marker; do
        [[ -z "$marker" ]] && continue
        echo "Removing marker: $(basename "$marker")"
        rm "$marker"
        (( ++marker_count ))
    done < <(find "$HOOK_ERROR_BUGS_DIR" -maxdepth 1 -type f 2>/dev/null)
    echo "Removed $marker_count marker file(s) from $HOOK_ERROR_BUGS_DIR"
else
    echo "No marker directory found at $HOOK_ERROR_BUGS_DIR — skipping."
fi

# ── Rebuild ticket index ──────────────────────────────────────────────────────
# Use tk index-rebuild to perform a full rebuild of .index.json.
# Removing the file is insufficient: _update_ticket_index starts with {} when
# the file is missing, so the next tk write only adds that one ticket — leaving
# the index with 1 entry for hundreds of .md files.
if command -v tk &>/dev/null && tk index-rebuild &>/dev/null 2>&1; then
    echo "Rebuilt ticket index via tk index-rebuild."
else
    # Fallback: remove so the next tk command at least doesn't serve stale data.
    index_file="$TICKETS_DIR/.index.json"
    if [[ -f "$index_file" ]]; then
        rm "$index_file"
        echo "tk index-rebuild unavailable; removed $index_file (fallback)."
    fi
fi

# ── Count after ───────────────────────────────────────────────────────────────
after_count=$(ls "$TICKETS_DIR"/*.md 2>/dev/null | wc -l | tr -d ' ')
echo ""
echo "Ticket files after:  $after_count"
echo "Net reduction:       $(( before_count - after_count ))"
echo ""
echo "Done."
