#!/usr/bin/env bash
# ticket-lifecycle.sh
# Bulk ticket lifecycle operations: compact + archive in a single git commit.
#
# Usage: ticket-lifecycle.sh [--base-path=<dir>]
#   --base-path=<dir>  Path to the tickets tracker directory
#                      (default: <repo-root>/.tickets-tracker/)
#
# Operations:
#   1. Sync once (fetch + pull --rebase)
#   2. Bulk compact: compact tickets above 10-event threshold (--no-commit)
#   3. Archive: write ARCHIVED events for eligible closed tickets
#   4. Single git commit for all changes
#   5. Push with 3-retry fetch-rebase-push on non-fast-forward
#
# Exit codes:
#   0 = success or nothing to do
#   Non-zero = push failure after retries
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Parse arguments ──────────────────────────────────────────────────────────
base_path=""
while [ $# -gt 0 ]; do
    case "$1" in
        --base-path=*)
            base_path="${1#--base-path=}"
            ;;
        *)
            echo "Error: unknown argument '$1'" >&2
            echo "Usage: ticket-lifecycle.sh [--base-path=<dir>]" >&2
            exit 1
            ;;
    esac
    shift
done

# ── Resolve base path ───────────────────────────────────────────────────────
if [ -z "$base_path" ]; then
    # Respect PROJECT_ROOT exported by the .claude/scripts/dso shim (bb42-1291).
    REPO_ROOT="${PROJECT_ROOT:-$(git rev-parse --show-toplevel)}"
    base_path="$REPO_ROOT/.tickets-tracker"
fi

if [ ! -d "$base_path" ]; then
    echo "Error: tracker directory not found: $base_path" >&2
    exit 1
fi

# ── Step 1: Sync once ───────────────────────────────────────────────────────
# Fetch and rebase from origin tickets branch (best-effort; skip if no remote)
_has_remote=false
if git -C "$base_path" remote get-url origin >/dev/null 2>&1; then
    _has_remote=true
fi

if [ "$_has_remote" = true ]; then
    if git -C "$base_path" fetch origin tickets 2>/dev/null; then
        # Two-phase sync guard (0051-3428 + eb00-efd0):
        # Phase 1: orphan branch (no merge-base) — safe to force-reset.
        # Phase 2: related history — preserve local-ahead commits.
        if ! git -C "$base_path" merge-base tickets origin/tickets &>/dev/null; then
            git -C "$base_path" reset --hard origin/tickets 2>/dev/null || true
        else
            _local_ahead=$(git -C "$base_path" log --oneline origin/tickets..tickets 2>/dev/null) || true
            if [ -z "$_local_ahead" ]; then
                git -C "$base_path" reset --hard origin/tickets 2>/dev/null || true
            fi
        fi
    fi
fi

# ── Step 2: Bulk compact ────────────────────────────────────────────────────
# Find all ticket dirs (directories with at least one .json event file)
compact_threshold=10
compacted_count=0

for ticket_dir in "$base_path"/*/; do
    [ -d "$ticket_dir" ] || continue
    ticket_id="$(basename "$ticket_dir")"

    # Skip hidden dirs and non-ticket dirs
    [[ "$ticket_id" == .* ]] && continue

    # Count event files
    event_count=$(find "$ticket_dir" -maxdepth 1 -name '*.json' ! -name '.*' 2>/dev/null | wc -l | tr -d ' ')
    if [ "$event_count" -gt "$compact_threshold" ]; then
        # Run compact with --no-commit and --skip-sync (we already synced)
        compact_exit=0
        TICKET_TRACKER_DIR="$base_path" bash "$SCRIPT_DIR/ticket-compact.sh" "$ticket_id" \
            --threshold="$compact_threshold" --skip-sync --no-commit 2>/tmp/lifecycle-compact-err.$$ || compact_exit=$?
        if [ "$compact_exit" -ne 0 ]; then
            echo "WARNING: compact failed for $ticket_id (exit $compact_exit): $(cat /tmp/lifecycle-compact-err.$$ 2>/dev/null)" >&2
            rm -f /tmp/lifecycle-compact-err.$$
            continue
        fi
        rm -f /tmp/lifecycle-compact-err.$$
        compacted_count=$((compacted_count + 1))
    fi
done

# ── Step 3: Archive eligible tickets ────────────────────────────────────────
# Get archive-eligible ticket IDs from ticket-graph.py
archive_ids_json=$(python3 "$SCRIPT_DIR/ticket-graph.py" --archive-eligible --tickets-dir="$base_path" 2>/dev/null || echo "[]")

# Read env_id
env_id_path="$base_path/.env-id"
if [ -f "$env_id_path" ]; then
    env_id=$(cat "$env_id_path" | tr -d '[:space:]')
else
    env_id="00000000-0000-4000-8000-000000000000"
fi

# Get author
author=$(git config user.name 2>/dev/null || echo "system")

# Parse JSON array and write ARCHIVED events
archived_count=0
archived_dirs=()
while IFS= read -r ticket_id; do
    [ -z "$ticket_id" ] && continue
    ticket_dir="$base_path/$ticket_id"
    [ -d "$ticket_dir" ] || continue

    # Skip if already archived
    existing_archived=$(find "$ticket_dir" -maxdepth 1 -name '*-ARCHIVED.json' 2>/dev/null | wc -l | tr -d ' ')
    if [ "$existing_archived" -gt 0 ]; then
        continue
    fi

    ts=$(date +%s)
    event_uuid=$(python3 -c "import uuid; print(uuid.uuid4())")
    event_file="$ticket_dir/${ts}-${event_uuid}-ARCHIVED.json"
    python3 -c "
import json, sys
event = {'timestamp': int(sys.argv[1]), 'uuid': sys.argv[2], 'event_type': 'ARCHIVED', 'env_id': sys.argv[3], 'author': sys.argv[4], 'data': {}}
with open(sys.argv[5], 'w') as f: json.dump(event, f)
" "$ts" "$event_uuid" "$env_id" "$author" "$event_file"
    # Collect dir for post-commit marker write (SC2: marker must only be written
    # after the ARCHIVED event is durably committed to git)
    archived_dirs+=("$ticket_dir")
    archived_count=$((archived_count + 1))
done < <(python3 -c "
import json, sys
ids = json.loads(sys.argv[1])
for tid in ids:
    print(tid)
" "$archive_ids_json")

# ── Step 4: Single git commit ───────────────────────────────────────────────
# Stage all changes and commit once
add_exit=0
git -C "$base_path" add -A 2>/tmp/lifecycle-add-err.$$ || add_exit=$?
if [ "$add_exit" -ne 0 ]; then
    echo "Error: git add failed (exit $add_exit): $(cat /tmp/lifecycle-add-err.$$ 2>/dev/null)" >&2
    rm -f /tmp/lifecycle-add-err.$$
    exit 1
fi
rm -f /tmp/lifecycle-add-err.$$

# Check if there are staged changes
if git -C "$base_path" diff --cached --quiet 2>/dev/null; then
    # Nothing to commit — exit 0 silently
    exit 0
fi

commit_exit=0
git -C "$base_path" commit -q --no-verify -m "chore: ticket lifecycle — bulk compact and archive" 2>/tmp/lifecycle-commit-err.$$ || commit_exit=$?
if [ "$commit_exit" -ne 0 ]; then
    echo "Error: git commit failed (exit $commit_exit): $(cat /tmp/lifecycle-commit-err.$$ 2>/dev/null)" >&2
    rm -f /tmp/lifecycle-commit-err.$$
    exit 1
fi
rm -f /tmp/lifecycle-commit-err.$$

# Write .archived markers now that the ARCHIVED events are durably committed (SC2)
# Error-tolerant — failure degrades to slow path on next read, does not block push.
for _archived_dir in "${archived_dirs[@]+"${archived_dirs[@]}"}"; do
    python3 -c "
import sys, pathlib
pathlib.Path(sys.argv[1]).touch()
" "$_archived_dir/.archived" 2>/dev/null || true
done

# ── Step 5: Push with 3-retry ───────────────────────────────────────────────
if [ "$_has_remote" != true ]; then
    # No remote — nothing to push
    exit 0
fi

max_push_retries=3
push_attempt=0

while [ "$push_attempt" -lt "$max_push_retries" ]; do
    push_attempt=$((push_attempt + 1))

    push_exit=0
    push_stderr=""
    push_stderr=$(PRE_COMMIT_ALLOW_NO_CONFIG=1 git -C "$base_path" push origin tickets 2>&1) || push_exit=$?

    if [ "$push_exit" -eq 0 ]; then
        exit 0
    fi

    # Check if failure is retryable (non-fast-forward) vs fatal (auth, network, etc.)
    if echo "$push_stderr" | grep -qiE 'non-fast-forward|rejected|fetch first'; then
        # Retryable: fetch, rebase, retry
        git -C "$base_path" fetch origin tickets 2>/dev/null || true
    else
        # Non-retryable failure — exit immediately
        echo "Error: push failed (non-retryable, exit $push_exit): $push_stderr" >&2
        exit 1
    fi

    rebase_exit=0
    git -C "$base_path" rebase origin/tickets 2>/dev/null || rebase_exit=$?

    if [ "$rebase_exit" -ne 0 ]; then
        # Rebase conflict — abort and fail
        git -C "$base_path" rebase --abort 2>/dev/null || true
        echo "Error: rebase conflict during push retry (attempt $push_attempt)" >&2
        exit 1
    fi
done

echo "Error: push failed after $max_push_retries retries" >&2
exit 1
