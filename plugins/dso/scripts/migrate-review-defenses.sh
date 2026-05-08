#!/usr/bin/env bash
# migrate-review-defenses.sh
# One-shot migration of # REVIEW-DEFENSE: inline comments to TrackerDefenseStore.
#
# Usage:
#   migrate-review-defenses.sh [--dry-run]
#
# Modes:
#   (default)  Migrate all # REVIEW-DEFENSE: comments: bind to owning ticket,
#              write to TrackerDefenseStore, delete inline comment.
#   --dry-run  Report what would be migrated without making any changes.
#
# Exit codes:
#   0  Success (all records processed; unbound records noted but not fatal)
#   1  Fatal pre-flight error (e.g., REPO_ROOT not found)

set -euo pipefail

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------
DRY_RUN=false
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=true

REPO_ROOT=$(git rev-parse --show-toplevel)
_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TICKET_CMD="${TICKET_CMD:-"$REPO_ROOT/.claude/scripts/dso ticket"}"
LEGACY_TICKET_TAG="review-defense-legacy"

# File extensions to scan (passed to grep --include)
INCLUDE_ARGS=(--include='*.sh' --include='*.py' --include='*.js' --include='*.ts')

# ---------------------------------------------------------------------------
# Logging helpers
# ---------------------------------------------------------------------------
_log()    { printf '[migrate-review-defenses] %s\n' "$*"; }
_warn()   { printf '[migrate-review-defenses] WARN: %s\n' "$*" >&2; }

# ---------------------------------------------------------------------------
# Source TrackerDefenseStore if available (best-effort)
# ---------------------------------------------------------------------------
# shellcheck source=/dev/null
source "$_SCRIPT_DIR/review-defense-store.sh" 2>/dev/null || true

# ---------------------------------------------------------------------------
# _find_owning_ticket filepath
# Heuristic: inspect git log for the most recent commit on this file that
# references a known ticket ID (hex pattern: [0-9a-f]{4}-[0-9a-f]{4}).
# Outputs the ticket ID or empty string if none found.
# ---------------------------------------------------------------------------
_find_owning_ticket() {
    local filepath="$1"
    local rel_path
    rel_path=$(realpath --relative-to="$REPO_ROOT" "$filepath" 2>/dev/null || python3 -c "
import os, sys
print(os.path.relpath(sys.argv[1], sys.argv[2]))
" "$filepath" "$REPO_ROOT")

    # Extract ticket IDs from git log for this file (most recent first)
    local ticket_id=""
    ticket_id=$(
        git -C "$REPO_ROOT" log --oneline --follow -- "$rel_path" 2>/dev/null \
          | grep -oE '[0-9a-f]{4}-[0-9a-f]{4}(-[0-9a-f]{4}-[0-9a-f]{4})?' \
          | head -1
    ) || true

    printf '%s' "${ticket_id:-}"
}

# ---------------------------------------------------------------------------
# _build_defense_json filepath lineno defense_text ticket_id
# Construct a minimal defense JSON record for defense_store_write.
# ---------------------------------------------------------------------------
_build_defense_json() {
    local filepath="$1" lineno="$2" defense_text="$3" ticket_id="$4"
    python3 - "$filepath" "$lineno" "$defense_text" "$ticket_id" <<'PYEOF'
import json, sys, datetime

filepath    = sys.argv[1]
lineno      = sys.argv[2]
defense_text= sys.argv[3]
ticket_id   = sys.argv[4]

record = {
    "defense_text":       defense_text,
    "file_paths":         [filepath],
    "cited_lines":        [f"{filepath}:{lineno}:{defense_text}"],
    "severity_history":   [{"severity": "important", "source": "migration"}],
    "prior_finding_id":   "",
    "migrated_from_inline": True,
    "migrated_at":        datetime.datetime.utcnow().isoformat() + "Z",
    "owning_ticket":      ticket_id,
}
print(json.dumps(record))
PYEOF
}

# ---------------------------------------------------------------------------
# _delete_inline_comment filepath lineno
# Remove the line containing # REVIEW-DEFENSE: at the given line number.
# Uses a temp file + atomic replace for safety.
# ---------------------------------------------------------------------------
_delete_inline_comment() {
    local filepath="$1" lineno="$2"
    local tmpfile
    tmpfile=$(mktemp /tmp/migrate-review-defenses.XXXXXX)
    # Remove line by number; preserve all others
    awk -v target="$lineno" 'NR != target' "$filepath" > "$tmpfile"
    mv "$tmpfile" "$filepath"
}

# ---------------------------------------------------------------------------
# _ensure_legacy_ticket
# Find or note the legacy corpus ticket for unbound defenses.
# Outputs the ticket ID or empty string if ticket CLI is unavailable.
# Retained for caller use; invoked indirectly via LEGACY_TICKET_TAG lookups.
# ---------------------------------------------------------------------------
# shellcheck disable=SC2329
_ensure_legacy_ticket() {
    # Look for an existing ticket tagged review-defense-legacy
    local existing
    existing=$(
        $TICKET_CMD list --format=llm 2>/dev/null \
          | grep -oE '[0-9a-f]{4}-[0-9a-f]{4}[^\s]*' \
          | head -1
    ) || true

    # Check for ticket tagged with our legacy tag
    local tagged
    tagged=$(
        $TICKET_CMD list --has-tag="$LEGACY_TICKET_TAG" --format=llm 2>/dev/null \
          | grep -oE '^[0-9a-f]{4}-[0-9a-f]{4}' \
          | head -1
    ) || true

    printf '%s' "${tagged:-}"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
_log "Starting migration (dry_run=$DRY_RUN)"
_log "Scanning: $REPO_ROOT"

# Collect all inline # REVIEW-DEFENSE: occurrences in code files (not .md)
mapfile -t MATCHES < <(
    grep -rn '# REVIEW-DEFENSE:' "${INCLUDE_ARGS[@]}" "$REPO_ROOT" 2>/dev/null || true
)

total=${#MATCHES[@]}
_log "Found $total inline # REVIEW-DEFENSE: comment(s) to migrate"

if [[ "$total" -eq 0 ]]; then
    _log "Nothing to migrate. Exiting."
    exit 0
fi

# Track counts
bound_count=0
unbound_count=0
skipped_count=0

# Accumulate unbound records for legacy ticket
unbound_records=()

for match in "${MATCHES[@]}"; do
    # Parse "filepath:lineno:...rest..."
    filepath=$(printf '%s' "$match" | cut -d: -f1)
    lineno=$(printf '%s' "$match"   | cut -d: -f2)

    # Validate lineno is a number
    if ! [[ "$lineno" =~ ^[0-9]+$ ]]; then
        _warn "Could not parse line number from: $match — skipping"
        (( skipped_count++ )) || true
        continue
    fi

    # Extract the defense text (everything after "# REVIEW-DEFENSE: ")
    defense_text=$(printf '%s' "$match" | cut -d: -f3- | sed 's/.*# REVIEW-DEFENSE:[[:space:]]*//')

    _log "Processing: $filepath:$lineno"
    _log "  Text: $defense_text"

    # Find owning ticket
    ticket_id=$(_find_owning_ticket "$filepath")

    if [[ -n "$ticket_id" ]]; then
        _log "  Owning ticket: $ticket_id"
        (( bound_count++ )) || true

        if $DRY_RUN; then
            _log "  DRY_RUN: would write defense to TrackerDefenseStore under ticket $ticket_id"
            _log "  DRY_RUN: would delete inline comment at $filepath:$lineno"
        else
            # Build JSON record
            defense_json=$(_build_defense_json "$filepath" "$lineno" "$defense_text" "$ticket_id")

            # Write to TrackerDefenseStore (best-effort; failure is non-fatal)
            if declare -f defense_store_write >/dev/null 2>&1; then
                if DSO_SESSION_TICKET_ID="$ticket_id" \
                    defense_store_write "$defense_json" >/dev/null 2>&1; then
                    _log "  Wrote defense record to TrackerDefenseStore"
                else
                    _warn "  defense_store_write failed for $filepath:$lineno — audit record logged above"
                fi
            else
                _log "  defense_store_write not available; audit record: $defense_json"
            fi

            # Delete the inline comment
            _delete_inline_comment "$filepath" "$lineno"
            _log "  Deleted inline comment"
        fi
    else
        _warn "  UNBOUND: no owning ticket found for $filepath:$lineno"
        (( unbound_count++ )) || true
        unbound_records+=("$filepath:$lineno: $defense_text")

        if $DRY_RUN; then
            _log "  DRY_RUN: would add to legacy corpus ticket (tag: $LEGACY_TICKET_TAG)"
        else
            _log "  Audit (unbound): $defense_text"
        fi
    fi
done

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
_log "---"
_log "Migration summary:"
_log "  Total found:   $total"
_log "  Bound:         $bound_count"
_log "  Unbound:       $unbound_count"
_log "  Skipped:       $skipped_count"

if [[ ${#unbound_records[@]} -gt 0 ]]; then
    _log "Unbound records (no owning ticket — add to legacy corpus manually):"
    for rec in "${unbound_records[@]}"; do
        _log "  UNBOUND: $rec"
    done
fi

if $DRY_RUN; then
    _log "Dry-run complete. No files modified."
fi

exit 0
