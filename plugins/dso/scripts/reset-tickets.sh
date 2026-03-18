#!/usr/bin/env bash
set -euo pipefail
# scripts/reset-tickets.sh
#
# Reset .tickets/ to a specific git commit's state and resync to Jira.
#
# This script performs an atomic reset of the local ticket state and Jira project:
#   1. Validates preconditions (on main, clean working tree, commit exists)
#   2. Deletes ALL existing issues from the target Jira project
#   3. Restores .tickets/ from the specified commit
#   4. Applies type hierarchy fixes (task→story for epic children)
#   5. Deletes .sync-state.json to force a full resync
#   6. Commits the reset
#   7. Runs tk sync to push all tickets to the clean Jira project
#   8. Verifies idempotency with a second sync
#
# Usage:
#   scripts/reset-tickets.sh <commit-sha> [--jira-project <key>]
#
# Options:
#   --jira-project <key>   Jira project key (default: from workflow-config.conf)
#   --skip-jira            Skip Jira deletion and sync (local reset only)
#   --dry-run              Show what would happen without making changes
#   --yes                  Skip confirmation prompts
#
# Prerequisites:
#   - Must be run on main (not a worktree)
#   - Clean working tree (no uncommitted changes)
#   - JIRA_URL, JIRA_USER, JIRA_API_TOKEN env vars set (unless --skip-jira)
#   - acli installed and in PATH (unless --skip-jira)
#
# Last known-good baseline (all tickets synced to LLD2L):
#   2263d8ab (2026-03-05) — 198 tickets, all stamped with jira_key, synced to LLD2L

set -euo pipefail

REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || {
    echo "Error: not inside a git repository" >&2
    exit 1
}

# ── Parse arguments ──────────────────────────────────────────────────────────

COMMIT_SHA=""
JIRA_PROJECT=""
SKIP_JIRA=false
DRY_RUN=false
AUTO_YES=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --jira-project) JIRA_PROJECT="$2"; shift 2 ;;
        --skip-jira) SKIP_JIRA=true; shift ;;
        --dry-run) DRY_RUN=true; shift ;;
        --yes) AUTO_YES=true; shift ;;
        -h|--help)
            sed -n '2,/^$/p' "$0" | sed 's/^# \?//'
            exit 0
            ;;
        -*) echo "Unknown option: $1" >&2; exit 1 ;;
        *) COMMIT_SHA="$1"; shift ;;
    esac
done

if [[ -z "$COMMIT_SHA" ]]; then
    echo "Usage: scripts/reset-tickets.sh <commit-sha> [--jira-project <key>]" >&2
    exit 1
fi

# ── Resolve Jira project ────────────────────────────────────────────────────

if [[ -z "$JIRA_PROJECT" ]]; then
    # Read from env var first, then workflow-config.conf
    if [[ -n "${JIRA_PROJECT_OVERRIDE:-}" ]]; then
        JIRA_PROJECT="$JIRA_PROJECT_OVERRIDE"
    else
        JIRA_PROJECT=$("${CLAUDE_PLUGIN_ROOT}/scripts/read-config.sh" jira.project "$REPO_ROOT/workflow-config.conf" 2>/dev/null) || true
    fi
fi

if [[ -z "$JIRA_PROJECT" ]] && [[ "$SKIP_JIRA" == "false" ]]; then
    echo "Error: could not determine Jira project. Use --jira-project <key> or set in workflow-config.conf" >&2
    exit 1
fi

# ── Validate preconditions ──────────────────────────────────────────────────

# Must be on main (not a worktree)
if [[ -f "$REPO_ROOT/.git" ]]; then
    echo "Error: must run on main repo, not a worktree (.git is a file)" >&2
    exit 1
fi

if [[ ! -d "$REPO_ROOT/.git" ]]; then
    echo "Error: .git is not a directory — unexpected state" >&2
    exit 1
fi

# Must be on main branch
CURRENT_BRANCH=$(git -C "$REPO_ROOT" branch --show-current)
if [[ "$CURRENT_BRANCH" != "main" ]]; then
    echo "Error: must be on main branch (currently on '$CURRENT_BRANCH')" >&2
    exit 1
fi

# Clean working tree
if [[ -n "$(git -C "$REPO_ROOT" status --porcelain)" ]]; then
    echo "Error: working tree is not clean. Commit or stash changes first." >&2
    exit 1
fi

# Commit exists
if ! git -C "$REPO_ROOT" cat-file -e "$COMMIT_SHA" 2>/dev/null; then
    echo "Error: commit $COMMIT_SHA does not exist" >&2
    exit 1
fi

# Commit has .tickets/
BASELINE_COUNT=$(git -C "$REPO_ROOT" ls-tree --name-only "$COMMIT_SHA" -- .tickets/ | wc -l | tr -d ' ')
if [[ "$BASELINE_COUNT" -eq 0 ]]; then
    echo "Error: commit $COMMIT_SHA has no .tickets/ directory" >&2
    exit 1
fi

# acli available (unless skipping Jira)
if [[ "$SKIP_JIRA" == "false" ]] && ! command -v acli &>/dev/null; then
    echo "Error: acli not found in PATH. Install it or use --skip-jira" >&2
    exit 1
fi

# ── Display plan and confirm ────────────────────────────────────────────────

CURRENT_COUNT=$(find "$REPO_ROOT/.tickets" -maxdepth 1 -name '*.md' 2>/dev/null | wc -l | tr -d ' ')

echo ""
echo "=== Ticket Reset Plan ==="
echo ""
echo "  Source commit:     $COMMIT_SHA"
echo "  Baseline tickets:  $BASELINE_COUNT files"
echo "  Current tickets:   $CURRENT_COUNT files"
echo "  Jira project:      ${JIRA_PROJECT:-N/A}"
echo "  Skip Jira:         $SKIP_JIRA"
echo "  Dry run:           $DRY_RUN"
echo ""
echo "This will:"
echo "  1. Delete ALL existing issues from Jira project '$JIRA_PROJECT'"
echo "  2. Remove all files in .tickets/"
echo "  3. Restore .tickets/ from commit $COMMIT_SHA ($BASELINE_COUNT files)"
echo "  4. Fix type hierarchy (task→story for epic children)"
echo "  5. Delete .sync-state.json"
echo "  6. Commit the reset"
echo "  7. Run tk sync to push $BASELINE_COUNT tickets to Jira"
echo "  8. Verify idempotency"
echo ""

if [[ "$DRY_RUN" == "true" ]]; then
    echo "[DRY RUN] No changes made."
    exit 0
fi

if [[ "$AUTO_YES" == "false" ]]; then
    printf "Proceed? [y/N] "
    read -r REPLY
    if [[ "$REPLY" != "y" && "$REPLY" != "Y" ]]; then
        echo "Aborted."
        exit 0
    fi
fi

# ── Step 1: Delete all Jira issues ──────────────────────────────────────────

if [[ "$SKIP_JIRA" == "false" ]]; then
    echo ""
    echo "Step 1/8: Deleting all issues from Jira project '$JIRA_PROJECT'..."

    # shellcheck disable=SC2097,SC2098
    JIRA_COUNT=$(JIRA_PROJECT="$JIRA_PROJECT" acli jira workitem search \
        --jql "project = $JIRA_PROJECT" --count 2>/dev/null | grep -o '[0-9]*' | head -1) || JIRA_COUNT=0

    if [[ "$JIRA_COUNT" -gt 0 ]]; then
        echo "  Found $JIRA_COUNT issues to delete..."
        # shellcheck disable=SC2097,SC2098
        JIRA_PROJECT="$JIRA_PROJECT" acli jira workitem delete \
            --jql "project = $JIRA_PROJECT" --yes --ignore-errors 2>&1 | tail -5
        echo "  Jira issues deleted."
    else
        echo "  No existing issues found."
    fi
else
    echo ""
    echo "Step 1/8: Skipping Jira deletion (--skip-jira)"
fi

# ── Step 2-3: Atomic .tickets/ reset ────────────────────────────────────────

echo ""
echo "Step 2/8: Removing .tickets/..."
rm -rf "$REPO_ROOT/.tickets/"

echo "Step 3/8: Restoring .tickets/ from $COMMIT_SHA..."
git -C "$REPO_ROOT" checkout "$COMMIT_SHA" -- .tickets/

RESTORED_COUNT=$(find "$REPO_ROOT/.tickets" -maxdepth 1 -name '*.md' 2>/dev/null | wc -l | tr -d ' ')
echo "  Restored $RESTORED_COUNT ticket files."

# ── Step 4: Type hierarchy fixes ────────────────────────────────────────────

echo ""
echo "Step 4/8: Fixing type hierarchy (task→story for epic children)..."
FIX_COUNT=0
for f in "$REPO_ROOT"/.tickets/*.md; do
    [[ -f "$f" ]] || continue
    type=$(awk '/^---$/{n++; next} n==1 && /^type:/{print $2}' "$f")
    parent=$(awk '/^---$/{n++; next} n==1 && /^parent:/{print $2}' "$f")
    if [[ "$type" == "task" && -n "$parent" ]]; then
        parent_file=$(find "$REPO_ROOT/.tickets" -maxdepth 1 -name "${parent}*.md" 2>/dev/null | head -1) || true
        if [[ -n "$parent_file" ]]; then
            parent_type=$(awk '/^---$/{n++; next} n==1 && /^type:/{print $2}' "$parent_file")
            if [[ "$parent_type" == "epic" ]]; then
                sed -i '' '/^---$/,/^---$/s/^type: task$/type: story/' "$f"
                FIX_COUNT=$((FIX_COUNT + 1))
            fi
        fi
    fi
done
echo "  Fixed $FIX_COUNT tickets."

# ── Step 5: Delete .sync-state.json ─────────────────────────────────────────

echo ""
echo "Step 5/8: Deleting .sync-state.json..."
rm -f "$REPO_ROOT/.tickets/.sync-state.json"
rm -f "$REPO_ROOT/.tickets/.last-sync-hash"
echo "  Done."

# ── Step 6: Commit ──────────────────────────────────────────────────────────

echo ""
echo "Step 6/8: Committing reset..."
git -C "$REPO_ROOT" add .tickets/
git -C "$REPO_ROOT" commit -m "$(cat <<EOF
chore: reset .tickets/ to $COMMIT_SHA baseline ($RESTORED_COUNT files)

Atomic reset of .tickets/ to the specified baseline commit.
Type hierarchy fixes: $FIX_COUNT task→feature promotions.
Sync state cleared for clean Jira resync.

Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>
EOF
)" || echo "  (nothing to commit — already at baseline)"

# ── Step 7: Sync to Jira ────────────────────────────────────────────────────

if [[ "$SKIP_JIRA" == "false" ]]; then
    echo ""
    echo "Step 7/8: Running tk sync to push tickets to '$JIRA_PROJECT'..."
    # Skip per-ticket git push during bulk sync — we do a single batch push afterward.
    # Without this, each of N tickets triggers an individual git push (N round-trips),
    # which causes hangs from rate limiting after ~196 pushes.
    TK_SYNC_SKIP_WORKTREE_PUSH=1 JIRA_PROJECT="$JIRA_PROJECT" \
        "${CLAUDE_PLUGIN_ROOT}/scripts/tk" sync 2>&1 | tail -10
    echo "  Sync complete."

    # Batch commit+push: jira_key stamps were written to .tickets/ files during sync
    echo "  Committing jira_key stamps..."
    git -C "$REPO_ROOT" add .tickets/
    git -C "$REPO_ROOT" commit -m "$(cat <<EOF
chore: stamp jira_key fields after bulk sync to $JIRA_PROJECT

Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>
EOF
)" || echo "  (no jira_key changes to commit)"
    git -C "$REPO_ROOT" push origin main || echo "  WARNING: push failed — run 'git push' manually"

    # ── Step 8: Verify idempotency ──────────────────────────────────────────

    echo ""
    echo "Step 8/8: Verifying idempotency (second sync)..."
    SECOND_SYNC=$(TK_SYNC_SKIP_WORKTREE_PUSH=1 JIRA_PROJECT="$JIRA_PROJECT" \
        "${CLAUDE_PLUGIN_ROOT}/scripts/tk" sync 2>&1)
    CREATED_COUNT=$(echo "$SECOND_SYNC" | grep -c 'created' || true)
    if [[ "$CREATED_COUNT" -gt 0 ]]; then
        echo "  WARNING: Second sync created $CREATED_COUNT new issues — not idempotent!"
        echo "$SECOND_SYNC" | grep 'created'
        exit 1
    else
        echo "  Idempotent: no new issues created."
    fi
else
    echo ""
    echo "Step 7-8/8: Skipping Jira sync (--skip-jira)"
fi

# ── Final verification ──────────────────────────────────────────────────────

echo ""
FINAL_COUNT=$(find "$REPO_ROOT/.tickets" -maxdepth 1 -name '*.md' 2>/dev/null | wc -l | tr -d ' ')
echo "=== Reset Complete ==="
echo "  Ticket files: $FINAL_COUNT"
echo "  Jira project: ${JIRA_PROJECT:-N/A}"
echo "  Commit: $(git -C "$REPO_ROOT" log --oneline -1)"
echo ""
