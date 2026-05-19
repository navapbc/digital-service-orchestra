#!/usr/bin/env bash
# bug-classification-stats.sh — Aggregate bug-type tag statistics from closed tickets.
#
# Usage:
#   bug-classification-stats.sh [--window-days N]
#
# Options:
#   --window-days N   Filter to tickets created within the last N days
#                     (default: 60)
#
# Env vars:
#   TICKET_CMD      — override ticket CLI (default: $SCRIPT_DIR/ticket)
#   REGISTRY_FILE   — override registry JSON path
#
# Output:
#   One line per slug with count > 0, sorted descending by count: "<count> <slug>"
#   Then: "uncategorized: <N>"
#   Then: "classifier-failed: <N>"

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_PLUGIN_ROOT="$SCRIPT_DIR/.."

# ── Defaults ──────────────────────────────────────────────────────────────────
TICKET_CMD="${TICKET_CMD:-$SCRIPT_DIR/ticket}"
REGISTRY_FILE="${REGISTRY_FILE:-${_PLUGIN_ROOT}/docs/bug-classification-registry.json}"

# Default window-days: 60
WINDOW_DAYS=60

# ── Argument parsing ──────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        --window-days)
            WINDOW_DAYS="$2"
            shift 2
            ;;
        --window-days=*)
            WINDOW_DAYS="${1#--window-days=}"
            shift
            ;;
        *)
            echo "Unknown argument: $1" >&2
            exit 1
            ;;
    esac
done

# ── Fetch closed tickets ──────────────────────────────────────────────────────
_ticket_tmp="$(mktemp /tmp/bug-stats-tickets.XXXXXX)"
trap 'rm -f "$_ticket_tmp"' EXIT
"$TICKET_CMD" list --type=bug --status=closed > "$_ticket_tmp"

# ── Aggregate via Python ──────────────────────────────────────────────────────
python3 - "$REGISTRY_FILE" "$_ticket_tmp" "$WINDOW_DAYS" <<'PYEOF'
import json
import sys
import time

registry_path = sys.argv[1]
tickets_path = sys.argv[2]
window_days = int(sys.argv[3]) if len(sys.argv) > 3 else 60

# Cutoff timestamp in seconds (tickets older than this are excluded)
cutoff_sec = time.time() - window_days * 86400

# Load known slugs from registry
with open(registry_path) as f:
    data = json.load(f)
known_slugs = {entry["slug"] for entry in data.get("entries", [])}

# Parse tickets
with open(tickets_path) as f:
    raw = f.read().strip()
try:
    tickets = json.loads(raw) if raw else []
except json.JSONDecodeError:
    tickets = []

# Aggregate counts
slug_counts = {}
uncategorized_count = 0
classifier_failed_count = 0

# Dual-count deduplication: a ticket carrying both bug-type-uncategorized and
# bug-type-classifier-failed-* is counted in classifier-failed only, treating
# classifier-failed as a strict subset of uncategorized (the uncategorized tag
# is added as a companion marker when classification fails; the intended signal
# is the failure, not the uncategorized bucket).
for ticket in tickets:
    # Apply window filter using created_at (nanosecond epoch timestamp)
    created_at_ns = ticket.get("created_at", 0)
    if created_at_ns and (created_at_ns / 1e9) < cutoff_sec:
        continue

    tags = ticket.get("tags", [])
    bug_type_tags = [t for t in tags if t.startswith("bug-type-")]

    has_classifier_failed = any(
        t[len("bug-type-"):].startswith("classifier-failed") for t in bug_type_tags
    )

    for tag in bug_type_tags:
        remainder = tag[len("bug-type-"):]
        if remainder.startswith("classifier-failed"):
            classifier_failed_count += 1
        elif remainder == "uncategorized":
            # Skip uncategorized count when classifier-failed is also present
            if not has_classifier_failed:
                uncategorized_count += 1
        else:
            slug_counts[remainder] = slug_counts.get(remainder, 0) + 1

# Print slug counts sorted descending by count
sorted_slugs = sorted(slug_counts.items(), key=lambda x: -x[1])
for slug, count in sorted_slugs:
    print(f"{count} {slug}")

# Print special buckets
print(f"uncategorized: {uncategorized_count}")
print(f"classifier-failed: {classifier_failed_count}")
PYEOF
