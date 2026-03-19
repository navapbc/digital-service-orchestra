#!/usr/bin/env bash
# jira-reset-sync.sh — Nuclear reset: delete ALL Jira issues, clear ledger,
# strip jira_key from tickets, resync from local.
#
# Usage:
#   scripts/jira-reset-sync.sh --dry-run     (default — preview only)
#   scripts/jira-reset-sync.sh --execute     (actually perform the reset)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CLAUDE_PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$SCRIPT_DIR/..}"
REPO_ROOT="$(git rev-parse --show-toplevel)"
TK="${TK:-$SCRIPT_DIR/tk}"

# ── Parse flags ──────────────────────────────────────────────────────────────
DRY_RUN=1
for arg in "$@"; do
    case "$arg" in
        --dry-run)  DRY_RUN=1 ;;
        --execute)  DRY_RUN=0 ;;
        *)
            echo "Usage: $0 [--dry-run|--execute]" >&2
            exit 1
            ;;
    esac
done

# ── Resolve JIRA_PROJECT ────────────────────────────────────────────────────
if [[ -z "${JIRA_PROJECT:-}" ]]; then
    _read_config="${CLAUDE_PLUGIN_ROOT}/scripts/read-config.sh"
    if [[ -x "$_read_config" ]]; then
        JIRA_PROJECT=$("$_read_config" "jira.project" 2>/dev/null) || true
    fi
fi
if [[ -z "${JIRA_PROJECT:-}" ]]; then
    echo "Error: JIRA_PROJECT not set" >&2
    exit 1
fi

echo "Project: $JIRA_PROJECT"
echo "Mode: $([ $DRY_RUN -eq 1 ] && echo 'DRY RUN' || echo 'EXECUTE')"
echo ""

# ── Step 1: Fetch all Jira issues ───────────────────────────────────────────
echo "Fetching all Jira issues..."
all_issues=$(acli jira workitem search \
    --jql "project=$JIRA_PROJECT ORDER BY created ASC" \
    --paginate --json 2>/dev/null) || {
    echo "Error: failed to fetch Jira issues" >&2
    exit 1
}

issue_count=$(echo "$all_issues" | python3 -c "import json,sys; print(len(json.load(sys.stdin)))")
echo "Found $issue_count Jira issues to delete"

# Count local tickets
ticket_count=$(find "$REPO_ROOT/.tickets" -name "*.md" -not -name ".last-sync-hash" | wc -l | tr -d ' ')
echo "Found $ticket_count local tickets to sync"
echo ""

if [[ $DRY_RUN -eq 1 ]]; then
    echo "=== DRY RUN ==="
    echo "Would delete $issue_count Jira issues"
    echo "Would clear .sync-state.json ledger"
    echo "Would strip jira_key from $ticket_count ticket files"
    echo "Would run tk sync to recreate all Jira issues"
    echo ""
    echo "Run with --execute to perform the reset."
    exit 0
fi

# ── Step 2: Delete all Jira issues ──────────────────────────────────────────
echo "=== DELETING ALL JIRA ISSUES ==="
deleted=0
failed_keys=()

while IFS= read -r key; do
    [[ -z "$key" ]] && continue
    if acli jira workitem delete --key "$key" --yes 2>/dev/null; then
        ((deleted++))
        echo "  deleted: $key ($deleted/$issue_count)"
    else
        echo "  FAILED: $key" >&2
        failed_keys+=("$key")
    fi
done < <(echo "$all_issues" | python3 -c "import json,sys; [print(i['key']) for i in json.load(sys.stdin)]")

echo "Deleted $deleted/$issue_count Jira issues"
if [[ ${#failed_keys[@]} -gt 0 ]]; then
    echo "Failed to delete: ${failed_keys[*]}" >&2
    echo "Re-run the script to retry failed deletions." >&2
fi

# ── Step 3: Clear ledger ────────────────────────────────────────────────────
echo ""
echo "Clearing .sync-state.json..."
echo "{}" > "$REPO_ROOT/.tickets/.sync-state.json"

# ── Step 4: Delete stale worktree ledger copies ─────────────────────────────
echo "Cleaning stale worktree ledgers..."
while IFS= read -r wt_path; do
    [[ "$wt_path" == "$REPO_ROOT" ]] && continue
    local_ledger="$wt_path/.tickets/.sync-state.json"
    if [[ -f "$local_ledger" ]]; then
        echo "  removing: $local_ledger"
        rm -f "$local_ledger"
    fi
done < <(git worktree list --porcelain | grep '^worktree ' | sed 's/^worktree //')

# ── Step 5: Strip jira_key from all ticket files ────────────────────────────
echo ""
echo "Stripping jira_key from ticket frontmatter..."
stripped=0
for ticket_file in "$REPO_ROOT/.tickets"/*.md; do
    [[ -f "$ticket_file" ]] || continue
    if grep -q "^jira_key:" "$ticket_file"; then
        # Remove jira_key line from frontmatter only (between --- markers)
        TICKET_FILE="$ticket_file" python3 -c "
import os
tf = os.environ['TICKET_FILE']
lines = open(tf).readlines()
result = []
fm_count = 0
for line in lines:
    stripped = line.rstrip('\n').rstrip('\r')
    if stripped == '---':
        fm_count += 1
    # Skip jira_key lines inside frontmatter (fm_count == 1)
    if fm_count == 1 and stripped.startswith('jira_key:'):
        continue
    result.append(line)
open(tf, 'w').writelines(result)
"
        ((stripped++))
    fi
done
echo "Stripped jira_key from $stripped ticket files"

# ── Step 6: Resync ──────────────────────────────────────────────────────────
echo ""
echo "Running tk sync (this may take several minutes)..."
TK_SYNC_SKIP_LOCK=1 "$TK" sync --include-closed || {
    echo "warning: tk sync exited with $?" >&2
}

# ── Summary ──────────────────────────────────────────────────────────────────
echo ""
echo "=== RESET COMPLETE ==="
echo "  Deleted: $deleted Jira issues"
echo "  Stripped: $stripped ticket files"
echo "  Synced: $ticket_count local tickets"
echo ""
echo "Run 'tk backfill-jira-keys --dry-run' to verify all tickets are stamped."
