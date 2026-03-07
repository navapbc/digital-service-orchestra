#!/usr/bin/env bash
# lockpick-workflow/scripts/merge-to-main.sh
# Merge worktree branch into main and push.
# Called by /end-session after all worktree commits are done.
#
# Replaces the old two-script flow (sprintend-sync.sh + merge-to-main.sh).
# tk (the issue tracker) uses file-per-issue storage under .tickets/ and requires
# no sync step; changes to .tickets/ are committed normally as part of regular commits.
#
# Usage: scripts/merge-to-main.sh
# Exit codes: 0=success, 1=error
# Output: concise status for LLM consumption

set -euo pipefail

# --- Resolve repo root and cd into it ---
# This ensures relative path checks work regardless of where the script is called from
if ! REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null); then
    echo "ERROR: Not a git repository."
    exit 1
fi
cd "$REPO_ROOT"

# --- Load ticket sync library (provides _clear_ticket_skip_worktree) ---
# Resolve relative to script location, not REPO_ROOT, so the source works
# when merge-to-main.sh is invoked from a test environment where REPO_ROOT
# points to a temp worktree that doesn't contain scripts/.
_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- Load project config via read-config.sh ---
TICKETS_DIR=$(bash "$_SCRIPT_DIR"/read-config.sh tickets.directory 2>/dev/null || true)
TICKETS_DIR=${TICKETS_DIR:-.tickets}
export LOCKPICK_TICKETS_DIR="$TICKETS_DIR"

VISUAL_BASELINE_PATH=$(bash "$_SCRIPT_DIR"/read-config.sh merge.visual_baseline_path 2>/dev/null || true)
CI_WORKFLOW_NAME=$(bash "$_SCRIPT_DIR"/read-config.sh merge.ci_workflow_name 2>/dev/null || true)
MSG_EXCLUSION_PATTERN=$(bash "$_SCRIPT_DIR"/read-config.sh merge.message_exclusion_pattern 2>/dev/null || true)

# Fallback: try plugin dir first, then repo-root scripts/
if [ -f "$_SCRIPT_DIR/tk-sync-lib.sh" ]; then
    source "$_SCRIPT_DIR/tk-sync-lib.sh" || { echo "ERROR: tk-sync-lib.sh failed to load"; exit 1; }
elif [ -f "$REPO_ROOT/scripts/tk-sync-lib.sh" ]; then
    source "$REPO_ROOT/scripts/tk-sync-lib.sh" || { echo "ERROR: tk-sync-lib.sh failed to load"; exit 1; }
else
    echo "ERROR: tk-sync-lib.sh not found in $_SCRIPT_DIR or $REPO_ROOT/scripts/"
    exit 1
fi

# --- Verify worktree context ---
if [ -d .git ]; then
    echo "ERROR: Not a worktree. This script is for worktree sessions only."
    exit 1
fi
if [ ! -f .git ]; then
    echo "ERROR: Not a git repository."
    exit 1
fi

# --- 1) Store worktree branch name ---
BRANCH=$(git branch --show-current)
if [ -z "$BRANCH" ]; then
    echo "ERROR: Could not determine worktree branch name."
    exit 1
fi

# --- Check for uncommitted or untracked changes on worktree ---
# Exclude .tickets/ — the pre-commit guard auto-unstages ticket files on
# non-main branches, so they always appear dirty in worktrees.
# They sync independently via the PostToolUse ticket-sync-push hook.
# (.sync-state.json now lives inside .tickets/ so is covered by this exclusion.)
DIRTY=$(git diff --name-only -- ':!'"$TICKETS_DIR"'/' 2>/dev/null || true)
DIRTY_CACHED=$(git diff --cached --name-only -- ':!'"$TICKETS_DIR"'/' 2>/dev/null || true)
DIRTY_UNTRACKED=$(git ls-files --others --exclude-standard -- ':!'"$TICKETS_DIR"'/' 2>/dev/null || true)
if [ -n "$DIRTY" ] || [ -n "$DIRTY_CACHED" ] || [ -n "$DIRTY_UNTRACKED" ]; then
    echo "ERROR: Uncommitted changes on worktree. Commit or stash first."
    [ -n "$DIRTY" ] && echo "Unstaged: $DIRTY"
    [ -n "$DIRTY_CACHED" ] && echo "Staged: $DIRTY_CACHED"
    [ -n "$DIRTY_UNTRACKED" ] && echo "Untracked: $DIRTY_UNTRACKED"
    exit 1
fi

# --- 1.5) Sync worktree with main ---
# Delegates to worktree-sync-from-main.sh which handles:
#   - Clearing skip-worktree flags on .tickets/ files
#   - Stashing dirty/untracked .tickets/ files
#   - Fetching and merging origin/main
#   - Auto-resolving .tickets/ conflicts (worktree wins)
#   - Restoring stashed .tickets/ files
# This surfaces merge conflicts here (where /resolve-conflicts can operate)
# rather than discovering them during the main-repo merge.

# Fallback: try plugin dir first, then repo-root scripts/
if [ -f "$_SCRIPT_DIR/worktree-sync-from-main.sh" ]; then
    source "$_SCRIPT_DIR/worktree-sync-from-main.sh"
elif [ -f "$REPO_ROOT/scripts/worktree-sync-from-main.sh" ]; then
    source "$REPO_ROOT/scripts/worktree-sync-from-main.sh"
else
    echo "ERROR: worktree-sync-from-main.sh not found in $_SCRIPT_DIR or $REPO_ROOT/scripts/"
    exit 1
fi

if ! _worktree_sync_from_main --quiet; then
    echo "ERROR: Syncing worktree with main failed. Resolve conflicts, then re-run."
    exit 1
fi

# --- Check visual baseline intent ---
# Use merge-base against origin/main (not local main) to detect only branch-originated
# snapshot changes. After the sync merge above, local main hasn't been fast-forwarded
# yet, so diffing HEAD vs local main would incorrectly flag CI baseline updates pulled
# in from origin/main as branch-originated changes (false positive).
MERGE_BASE_ORIGIN=$(git merge-base HEAD origin/main 2>/dev/null || git rev-parse HEAD)
if [ -n "$VISUAL_BASELINE_PATH" ]; then
    BASELINE_DIFF=$(git diff --name-only "$MERGE_BASE_ORIGIN" HEAD -- "$VISUAL_BASELINE_PATH" 2>/dev/null | grep '\.png$' || true)
    if [ -n "$BASELINE_DIFF" ]; then
        BASELINE_CHECK_EXIT=0
        "$REPO_ROOT/scripts/verify-baseline-intent.sh" || BASELINE_CHECK_EXIT=$?
        if [ "$BASELINE_CHECK_EXIT" -eq 2 ]; then
            echo "ERROR: Visual baseline changes need review. See .claude/docs/VISUAL-BASELINES.md"
            exit 1
        elif [ "$BASELINE_CHECK_EXIT" -ne 0 ]; then
            echo "ERROR: verify-baseline-intent.sh failed with exit code $BASELINE_CHECK_EXIT."
            exit 1
        fi
    fi
else
    echo 'INFO: merge.visual_baseline_path not configured -- skipping baseline intent check.'
fi

# --- 2) Resolve main repo path and cd into it ---
MAIN_REPO=$(dirname "$(git rev-parse --git-common-dir)")
if [ -z "$MAIN_REPO" ]; then
    echo "ERROR: Could not determine main repo path."
    exit 1
fi
cd "$MAIN_REPO"

# Verify main is checked out
MAIN_BRANCH=$(git branch --show-current)
if [ "$MAIN_BRANCH" != "main" ]; then
    echo "ERROR: Main repo is on '$MAIN_BRANCH', expected 'main'."
    exit 1
fi

# --- 2.5) Recover from incomplete merge state on main ---
# If a prior run left main with MERGE_HEAD (e.g., stash pop conflict), abort it
# so this run can proceed cleanly. The worktree merge (step 3) will re-apply
# the correct changes.
if [ -f "$(git rev-parse --git-dir)/MERGE_HEAD" ]; then
    echo "WARNING: Main has incomplete merge state (MERGE_HEAD). Aborting it..."
    git merge --abort 2>/dev/null || git reset --merge 2>/dev/null || true
fi

# --- 2.55) Force-clean .tickets/ on main ---
# The ticket-sync-push hook advances refs/heads/main via detached-index commits,
# leaving the main repo's working tree dirty with stale .tickets/ files. Some may
# have skip-worktree set (hiding them from git diff/stash). Force-clean ensures
# .tickets/ is pristine before any git operations (pull, merge) on main.
# Order matters: clear flags first (so checkout/reset can see the files),
# then unstage, restore working tree, and remove untracked files.
_clear_ticket_skip_worktree
git reset HEAD -- "$TICKETS_DIR"/ 2>/dev/null || true
git checkout -- "$TICKETS_DIR"/ 2>/dev/null || true
git clean -fd "$TICKETS_DIR"/ 2>/dev/null || true

# --- 2.6) Pull remote changes before merging ---
echo "Pulling remote changes..."
# Stash any local changes so rebase pull can proceed
STASHED=false
if ! git diff --quiet 2>/dev/null || ! git diff --cached --quiet 2>/dev/null; then
    echo "Stashing local changes before pull..."
    git stash push --quiet -m "merge-to-main: pre-pull stash"
    STASHED=true
fi
if ! git pull --rebase 2>&1; then
    if $STASHED; then git stash pop --quiet 2>/dev/null || true; fi
    echo "ERROR: git pull --rebase failed. Resolve conflicts manually, then retry."
    exit 1
fi
if $STASHED; then
    echo "Restoring stashed changes..."
    if ! git stash pop --quiet 2>/dev/null; then
        # Stash pop conflicted — discard the stash. The pre-stash files were
        # .tickets/ files, which the merge step will overwrite
        # anyway. Keeping an unmerged stash pop would block all subsequent ops.
        echo "WARNING: Stash pop had conflicts — resetting. Merge step will reconcile."
        git reset --merge 2>/dev/null || true
        git stash drop --quiet 2>/dev/null || true
    fi
fi
echo "OK: Pulled remote changes."

# --- 3) Merge worktree branch ---
# Find the last meaningful commit message from the worktree branch (skip chore/cleanup commits)
if [ -n "$MSG_EXCLUSION_PATTERN" ]; then
    LAST_MSG=$(git log "$BRANCH" --format='%s' --no-merges -- \
        | grep -v -E "$MSG_EXCLUSION_PATTERN" \
        | head -1 || true)
else
    LAST_MSG=$(git log "$BRANCH" --format='%s' --no-merges -- \
        | head -1 || true)
fi
if [ -z "$LAST_MSG" ]; then
    LAST_MSG="Merge $BRANCH"
fi
MERGE_MSG="$LAST_MSG (merge $BRANCH)"

# Force-clean .tickets/ before merge — the ticket sync push hook and git pull
# --rebase may have left .tickets/ dirty again since the force-clean in 2.55
# (e.g., stash pop at 2.6 can restore stashed ticket files).
# The merge result is authoritative for .tickets/ (worktree branch wins), so
# there is no data to preserve here — force-clean is safe.
_clear_ticket_skip_worktree
git reset HEAD -- "$TICKETS_DIR"/ 2>/dev/null || true
git checkout -- "$TICKETS_DIR"/ 2>/dev/null || true
git clean -fd "$TICKETS_DIR"/ 2>/dev/null || true

# Capture pre-merge SHA so we can later detect whether the merge contained
# non-.tickets/ changes (used for the CI trigger check after push).
PRE_MERGE_SHA=$(git rev-parse HEAD)

echo "Merging $BRANCH into main..."
if ! git merge --no-ff "$BRANCH" -m "$MERGE_MSG" --quiet 2>&1; then
    CONFLICTED=$(git diff --name-only --diff-filter=U 2>/dev/null || true)
    # Auto-resolve .tickets/ conflicts (same as worktree sync)
    NON_TICKET_CONFLICTS=$(echo "$CONFLICTED" | grep -v '^'"$TICKETS_DIR"'/' || true)
    if [ -z "$NON_TICKET_CONFLICTS" ] && [ -n "$CONFLICTED" ]; then
        echo "Auto-resolving ticket conflicts (branch wins)..."
        git checkout --theirs -- "$TICKETS_DIR"/ 2>/dev/null || true
        git add "$TICKETS_DIR"/ 2>/dev/null || true
        git commit --no-edit --quiet 2>/dev/null || true
        echo "OK: Auto-resolved ticket conflicts."
    else
        git merge --abort 2>/dev/null || true
        echo "ERROR: Merge conflict. Aborted merge."
        # Structured output for /resolve-conflicts skill consumption
        echo "CONFLICT_DATA: branch=$BRANCH merge_base=$(git merge-base main "$BRANCH" 2>/dev/null || echo unknown)"
        if [ -n "$CONFLICTED" ]; then
            echo "CONFLICT_FILES: $CONFLICTED"
        fi
        exit 1
    fi
fi
echo "OK: Merged $BRANCH into main."

# Stage any post-merge artifacts (.gitignore entries for worktree dirs)
git add .gitignore 2>/dev/null || true

REMAINING_DIRTY=$(git diff --name-only -- ':!'"$TICKETS_DIR"'/' 2>/dev/null || true)
if [ -n "$REMAINING_DIRTY" ]; then
    echo "WARNING: Unexpected dirty files on main (not staged): $REMAINING_DIRTY"
fi

if ! git diff --cached --quiet 2>/dev/null; then
    git commit --amend --no-edit --quiet
    echo "OK: Folded post-merge changes into merge commit."
fi

# --- 4) Push ---
echo "Pushing main..."
if ! git push 2>&1; then
    echo "ERROR: Push failed. Try: git pull --rebase && git push"
    exit 1
fi
echo "OK: Pushed main to remote."

# --- 5) Trigger CI if HEAD has [skip ci] but merge contained code changes ---
# The PostToolUse ticket-sync-push hook appends [skip ci] commits to main after
# the push. GitHub evaluates CI eligibility based on the HEAD commit message, so
# if a [skip ci] commit lands on top of the merge commit, CI is suppressed even
# though the merge contained real code changes.
# Mitigation: if the merge introduced non-.tickets/ changes AND the current HEAD
# on origin carries [skip ci], explicitly dispatch the CI workflow so it runs.
HEAD_MSG=$(git log -1 --format='%s' origin/main 2>/dev/null || git log -1 --format='%s' 2>/dev/null || true)
CODE_CHANGES=$(git diff --name-only "$PRE_MERGE_SHA" HEAD -- ':!'"$TICKETS_DIR"'/' 2>/dev/null | head -1 || true)
if [ -n "$CI_WORKFLOW_NAME" ]; then
    if echo "$HEAD_MSG" | grep -q '\[skip ci\]' && [ -n "$CODE_CHANGES" ]; then
        echo "INFO: HEAD has [skip ci] but merge contained code changes — triggering CI workflow..."
        if command -v gh >/dev/null 2>&1; then
            if gh workflow run "$CI_WORKFLOW_NAME" --ref main 2>&1; then
                echo "OK: CI workflow triggered on main."
            else
                echo "WARNING: Could not trigger CI workflow (gh workflow run failed). Trigger manually or check GitHub Actions."
            fi
        else
            echo "WARNING: gh CLI not found — cannot trigger CI. Trigger manually or check GitHub Actions."
        fi
    fi
else
    echo 'INFO: merge.ci_workflow_name not configured -- skipping CI trigger.'
fi

echo "DONE: $BRANCH merged, committed, and pushed."
