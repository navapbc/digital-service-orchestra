#!/usr/bin/env bash
# backfill-bug-types.sh — Backfill bug-type-* tags on closed bug tickets
#                          that have not yet been classified.
#
# Usage:
#   backfill-bug-types.sh [--dry-run] [--window-days N]
#
# Options:
#   --dry-run        Print tickets that would be classified without dispatching
#                    the classifier agent or writing any tags.
#   --window-days N  Only process tickets created within the last N days
#                    (default: 60).
#
# Environment overrides (for testability):
#   TICKET_CMD          Override the ticket CLI path (default: $SCRIPT_DIR/ticket)
#   REPO_ROOT           Override the repo root (default: git rev-parse --show-toplevel)
#   LOCK_DIR            Override the lock directory (default: $REPO_ROOT/.claude/locks)
#   CLASSIFIER_OUTPUT   Mock classifier agent output (slug or "uncategorized")
#
# Backfill logic:
#   1. Load slug set from the bug-classification-registry.json (at _PLUGIN_ROOT/docs/)
#   2. List all closed bug tickets
#   3. Skip tickets that already have a bug-type-* tag (idempotent)
#   4. Skip jira-* ticket IDs (log a message)
#   5. For each qualifying ticket:
#      --dry-run: print "DRY-RUN: would classify <id> (<title>)"
#      normal:    The orchestrator reading this script should dispatch the
#                 bug-classifier-haiku agent for each ticket and apply the
#                 resulting tag. For testability, CLASSIFIER_OUTPUT env var
#                 overrides the agent output.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Always resolve the plugin root from the script location for intra-plugin paths
# (e.g. the registry JSON). The env var may point to the main repo while this
# script lives in a worktree, so we use the script-relative parent as the
# authoritative location.
_PLUGIN_ROOT="$SCRIPT_DIR/.."

# ── Argument parsing ───────────────────────────────────────────────────────────
DRY_RUN=false
WINDOW_DAYS=60

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run)        DRY_RUN=true; shift ;;
        --window-days)    WINDOW_DAYS="$2"; shift 2 ;;
        --window-days=*)  WINDOW_DAYS="${1#--window-days=}"; shift ;;
        *) echo "Unknown argument: $1" >&2; exit 2 ;;
    esac
done

# ── Environment / path resolution ─────────────────────────────────────────────
TICKET_CMD="${TICKET_CMD:-$SCRIPT_DIR/ticket}"
REPO_ROOT="${REPO_ROOT:-$(git rev-parse --show-toplevel)}"
LOCK_DIR="${LOCK_DIR:-$REPO_ROOT/.claude/locks}"
LOCK_FILE="$LOCK_DIR/backfill-bug-types.lock"

REGISTRY_FILE="$_PLUGIN_ROOT/docs/bug-classification-registry.json"

# ── Tickets-branch presence assertion ─────────────────────────────────────────
# The ticket system stores all data on the 'tickets' orphan branch. If that
# branch is absent the ticket CLI will be operating against stale or missing
# state, making a backfill run unsafe. Testability: set
# SKIP_TICKETS_BRANCH_CHECK=1 to bypass (used when REPO_ROOT is a temp dir
# that is not a real git repository).
if [[ "${SKIP_TICKETS_BRANCH_CHECK:-0}" != "1" ]]; then
    if ! git -C "$REPO_ROOT" for-each-ref --format='%(refname)' refs/heads/tickets 2>/dev/null | grep -q .; then
        echo "ERROR: tickets branch not found in $REPO_ROOT. The ticket system orphan branch is required before running backfill." >&2
        exit 1
    fi
fi

# ── Temp files (set up early so trap can clean them) ──────────────────────────
tickets_tmpfile=$(mktemp /tmp/backfill-tickets.XXXXXX)
qualifying_tmpfile=$(mktemp /tmp/backfill-qualifying.XXXXXX)

_cleanup() {
    rm -f "$LOCK_FILE" "$tickets_tmpfile" "$qualifying_tmpfile"
}
trap _cleanup EXIT

# ── Lock management ────────────────────────────────────────────────────────────
mkdir -p "$LOCK_DIR"

if [ -f "$LOCK_FILE" ]; then
    existing_pid=$(head -n1 "$LOCK_FILE" 2>/dev/null || echo "")
    if [ -n "$existing_pid" ] && kill -0 "$existing_pid" 2>/dev/null; then
        echo "backfill already running (PID $existing_pid)" >&2
        exit 0
    else
        echo "Removing stale lock (PID ${existing_pid:-unknown} no longer running); proceeding." >&2
        rm -f "$LOCK_FILE"
    fi
fi

# Write lock with PID (and timestamp on second line)
printf '%s\n%s\n' "$$" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$LOCK_FILE"

# ── Load slug set from registry ────────────────────────────────────────────────
if [ ! -f "$REGISTRY_FILE" ]; then
    echo "ERROR: bug-classification-registry.json not found at $REGISTRY_FILE" >&2
    exit 1
fi

# Build newline-separated list of valid slugs
valid_slugs=$(python3 -c "
import json, sys
with open(sys.argv[1]) as f:
    data = json.load(f)
for entry in data.get('entries', []):
    print(entry['slug'])
" "$REGISTRY_FILE")

# ── Fetch closed bug tickets ───────────────────────────────────────────────────
"$TICKET_CMD" list --type=bug --status=closed > "$tickets_tmpfile" 2>/dev/null || printf '[]' > "$tickets_tmpfile"

# ── Filter: build list of qualifying ticket records ───────────────────────────
python3 - "$tickets_tmpfile" "$qualifying_tmpfile" "$WINDOW_DAYS" << 'PYEOF'
import json, sys, time

tickets_file = sys.argv[1]
output_file  = sys.argv[2]
window_days  = int(sys.argv[3]) if len(sys.argv) > 3 else 60

# Cutoff timestamp in seconds; tickets created before this are excluded
cutoff_sec = time.time() - window_days * 86400

try:
    with open(tickets_file) as f:
        tickets = json.load(f)
except Exception as e:
    print(f"ERROR: failed to parse ticket list JSON: {e}", file=sys.stderr)
    sys.exit(1)

with open(output_file, "w") as out:
    for t in tickets:
        ticket_id = t.get("ticket_id", "")
        title     = t.get("title", "")
        tags      = t.get("tags", [])

        # Apply window filter using created_at (nanosecond epoch timestamp)
        created_at_ns = t.get("created_at", 0)
        if created_at_ns and (created_at_ns / 1e9) < cutoff_sec:
            continue

        # Skip tickets already bearing a bug-type-* tag (idempotency)
        if any(tag.startswith("bug-type-") for tag in tags):
            continue

        # Skip jira-* ticket IDs
        if ticket_id.startswith("jira-"):
            print(f"skipping jira ticket {ticket_id}", flush=True)
            continue

        # Emit qualifying ticket as a line of JSON
        out.write(json.dumps({"id": ticket_id, "title": title}) + "\n")
PYEOF

# ── Process each qualifying ticket ────────────────────────────────────────────
while IFS= read -r line; do
    [ -z "$line" ] && continue

    ticket_id=$(python3 -c "import json,sys; d=json.loads(sys.argv[1]); print(d['id'])" "$line" 2>/dev/null || true)
    ticket_title=$(python3 -c "import json,sys; d=json.loads(sys.argv[1]); print(d['title'])" "$line" 2>/dev/null || true)

    if [ -z "$ticket_id" ]; then
        continue
    fi

    if $DRY_RUN; then
        echo "DRY-RUN: would classify $ticket_id ($ticket_title)"
    else
        # ── Classification ────────────────────────────────────────────────────
        # In normal (non-dry-run) mode, the orchestrator should dispatch the
        # bug-classifier-haiku agent with the registry slug list, ticket title,
        # description, and fix diff summary, then apply the returned slug as a
        # bug-type-<slug> tag.
        #
        # For testability: if CLASSIFIER_OUTPUT is set, use it as mock output.
        if [ -n "${CLASSIFIER_OUTPUT:-}" ]; then
            classifier_result="$CLASSIFIER_OUTPUT"
        else
            # CLASSIFIER_OUTPUT must be set by the orchestrator before each ticket.
            # Bash cannot dispatch AI agents directly. The orchestrator must invoke
            # bug-classifier-haiku and inject the result via CLASSIFIER_OUTPUT.
            echo "ERROR: CLASSIFIER_OUTPUT is not set for ticket $ticket_id. The orchestrator must dispatch bug-classifier-haiku and set CLASSIFIER_OUTPUT before calling backfill-bug-types.sh in production mode. Use --dry-run to preview tickets without requiring classification." >&2
            exit 1
        fi

        # Normalize: strip whitespace
        classifier_result=$(printf '%s' "$classifier_result" | tr -d '[:space:]')

        if [ -z "$classifier_result" ]; then
            # Empty result — treat as classifier failure
            echo "WARN: classifier returned empty result for $ticket_id; tagging as uncategorized+failed" >&2
            "$TICKET_CMD" tag "$ticket_id" "bug-type-uncategorized" 2>/dev/null || true
            "$TICKET_CMD" tag "$ticket_id" "bug-type-classifier-failed-empty-result" 2>/dev/null || true
        elif [ "$classifier_result" = "uncategorized" ]; then
            echo "INFO: $ticket_id classified as uncategorized"
            "$TICKET_CMD" tag "$ticket_id" "bug-type-uncategorized" 2>/dev/null || true
        else
            # Validate slug against registry
            if printf '%s\n' "$valid_slugs" | grep -qxF "$classifier_result"; then
                echo "INFO: $ticket_id classified as $classifier_result"
                "$TICKET_CMD" tag "$ticket_id" "bug-type-$classifier_result" 2>/dev/null || true
            else
                # Unknown slug — treat as classifier failure
                echo "WARN: classifier returned unknown slug '$classifier_result' for $ticket_id; tagging as uncategorized+failed" >&2
                "$TICKET_CMD" tag "$ticket_id" "bug-type-uncategorized" 2>/dev/null || true
                "$TICKET_CMD" tag "$ticket_id" "bug-type-classifier-failed-unknown-slug" 2>/dev/null || true
            fi
        fi
    fi
done < "$qualifying_tmpfile"

echo "Backfill complete."
