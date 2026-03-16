#!/usr/bin/env bash
set -euo pipefail
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

_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLAUDE_PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$_SCRIPT_DIR/.." && pwd)}"

# --- Count closed tickets using a single awk pass over all .md files ---
# Usage: _count_closed_tickets <tickets_dir>
# Returns: integer count of .md files whose YAML front-matter contains "status: closed"
_count_closed_tickets() {
    local dir="$1"
    local _result
    _result=$(find "$dir" -maxdepth 1 -name "*.md" -type f \
        | xargs awk '
            FILENAME != _prev {
                if (_prev != "" && _found) count++
                _prev=FILENAME; _found=0; _n=0
            }
            /^---$/ { _n++; if(_n==2) nextfile }
            _n==1 && /^status:[[:space:]]*closed/ { _found=1 }
            END { if (_prev != "" && _found) count++; print count+0 }
        ' 2>/dev/null)
    echo "${_result:-0}"
}

# --- State file helpers (resumable merge support) ---

_state_file_path() {
    local _sanitized="${BRANCH//\//-}"
    echo "/tmp/merge-to-main-state-${_sanitized}.json"
}

_state_is_fresh() {
    local _sf
    _sf=$(_state_file_path) 2>/dev/null || return 1
    if [[ ! -f "$_sf" ]]; then
        return 1
    fi
    # Check if mtime > 4 hours (240 minutes) ago using python3 (portable across /tmp symlinks)
    local _is_stale
    _is_stale=$(python3 -c "
import os, time
try:
    mtime = os.path.getmtime('$_sf')
    if (time.time() - mtime) > 240 * 60:
        print('stale')
    else:
        print('fresh')
except Exception:
    print('stale')
" 2>/dev/null || echo "stale")
    if [[ "$_is_stale" == "stale" ]]; then
        rm -f "$_sf" 2>/dev/null
        return 1
    fi
    return 0
}

_state_init() {
    # Clean up any stale state files first
    find /tmp -maxdepth 1 -name 'merge-to-main-state-*.json' -mmin +240 -delete 2>/dev/null
    local _sf
    _sf=$(_state_file_path) 2>/dev/null || return 0
    if ! _state_is_fresh; then
        # Not fresh (missing or stale) — write fresh skeleton
        python3 -c "
import json
d = {'branch': '$BRANCH', 'merge_sha': '', 'completed_phases': [], 'current_phase': '', 'phases': {}}
with open('${_sf}.tmp', 'w') as f:
    json.dump(d, f)
" 2>/dev/null && mv "${_sf}.tmp" "$_sf" 2>/dev/null
    fi
    return 0
}

_state_write_phase() {
    local _phase="$1"
    local _sf
    _sf=$(_state_file_path) 2>/dev/null || return 0
    [[ -f "$_sf" ]] || return 0
    python3 -c "
import json
with open('$_sf') as f:
    d = json.load(f)
d['current_phase'] = '$_phase'
with open('${_sf}.tmp', 'w') as f:
    json.dump(d, f)
" 2>/dev/null && mv "${_sf}.tmp" "$_sf" 2>/dev/null
    return 0
}

_state_mark_complete() {
    local _phase="$1"
    local _sf
    _sf=$(_state_file_path) 2>/dev/null || return 0
    [[ -f "$_sf" ]] || return 0
    python3 -c "
import json
with open('$_sf') as f:
    d = json.load(f)
if '$_phase' not in d.get('completed_phases', []):
    d.setdefault('completed_phases', []).append('$_phase')
d.setdefault('phases', {})['$_phase'] = {'status': 'complete'}
with open('${_sf}.tmp', 'w') as f:
    json.dump(d, f)
" 2>/dev/null && mv "${_sf}.tmp" "$_sf" 2>/dev/null
    return 0
}

_state_record_merge_sha() {
    local _sha="$1"
    local _sf
    _sf=$(_state_file_path) 2>/dev/null || return 0
    [[ -f "$_sf" ]] || return 0
    python3 -c "
import json
with open('$_sf') as f:
    d = json.load(f)
d['merge_sha'] = '$_sha'
with open('${_sf}.tmp', 'w') as f:
    json.dump(d, f)
" 2>/dev/null && mv "${_sf}.tmp" "$_sf" 2>/dev/null
    return 0
}

# --- SIGURG trap: save current phase to state file before exit ---
_sigurg_handler() {
    _state_write_phase "${_CURRENT_PHASE:-interrupted}" 2>/dev/null || true
    exit 0
}
trap '_sigurg_handler' URG

# --- Lock staleness check ---
# Usage: _is_lock_stale <lock_file>
# Returns 0 (true/stale) if the lock can be broken, 1 (false/valid) if the lock is held.
# Lock file format: PID|command_name
# Checks:
#   1. Lock file does not exist → stale (absent = can acquire)
#   2. PID is not alive → stale (process died)
#   3. PID is alive but command name doesn't match → stale (PID was recycled)
#   4. PID is alive and command matches → not stale (valid lock)
_is_lock_stale() {
    local lock_file="$1"

    # No lock file → stale (can acquire)
    if [[ ! -f "$lock_file" ]]; then
        return 0
    fi

    # Read PID and command from lock file
    local lock_pid lock_cmd
    lock_pid=$(cut -d'|' -f1 < "$lock_file")
    lock_cmd=$(cut -d'|' -f2 < "$lock_file")

    # Check if PID is alive
    if ! kill -0 "$lock_pid" 2>/dev/null; then
        return 0  # PID is dead → stale
    fi

    # PID is alive — check command name to guard against PID recycling
    local current_cmd
    current_cmd=$(ps -p "$lock_pid" -o comm= 2>/dev/null || echo "")
    if [[ "$current_cmd" != "$lock_cmd" ]]; then
        return 0  # Command mismatch → PID was recycled → stale
    fi

    # PID is alive AND command matches → valid lock
    return 1
}

# --- Lock acquire/release primitives ---
# Usage: _acquire_lock [lock_file]
# Creates a lock file atomically containing "PID|merge-to-main".
# If lock_file is omitted, derives path from MAIN_REPO hash:
#   /tmp/merge-to-main-lock-<hash>
# Returns 0 on success, 1 if lock is already held by a valid process.
# If the existing lock is stale, it is broken and re-acquired.
_acquire_lock() {
    local lock_file="${1:-}"
    if [[ -z "$lock_file" ]]; then
        local _lock_hash
        _lock_hash=$(echo -n "${MAIN_REPO:-unknown}" | shasum 2>/dev/null | cut -c1-8 || echo -n "${MAIN_REPO:-unknown}" | sha256sum 2>/dev/null | cut -c1-8 || echo "default")
        lock_file="/tmp/merge-to-main-lock-${_lock_hash}"
    fi

    # If a lock file exists, check staleness
    if [[ -f "$lock_file" ]]; then
        if _is_lock_stale "$lock_file"; then
            # Stale lock — remove it and proceed
            rm -f "$lock_file" 2>/dev/null
        else
            # Valid lock held by another process
            return 1
        fi
    fi

    # Write lock atomically using noclobber
    local _lock_content="$$|merge-to-main"
    (
        set -C
        echo "$_lock_content" > "$lock_file"
    ) 2>/dev/null
    local _rc=$?

    if [[ $_rc -ne 0 ]]; then
        # Race condition: another process created the file between our check and write
        return 1
    fi

    return 0
}

# Usage: _release_lock <lock_file>
# Removes the lock file only if the current process ($$) is the owner.
# Returns 0 on success, 1 if not owner (no-ops silently).
_release_lock() {
    local lock_file="$1"

    if [[ ! -f "$lock_file" ]]; then
        return 0
    fi

    # Read PID from lock file
    local lock_pid
    lock_pid=$(cut -d'|' -f1 < "$lock_file" 2>/dev/null || echo "")

    if [[ "$lock_pid" == "$$" ]]; then
        rm -f "$lock_file" 2>/dev/null
        return 0
    fi

    # Not owner — leave it alone
    return 1
}

# --- Push idempotency helper ---
# Determines whether a push to origin/main is needed.
# Returns 0 if push is needed (commits exist ahead of origin/main).
# Returns 1 if push is not needed (origin/main already contains HEAD).
# On fetch failure, returns 0 (push needed) to avoid suppressing a needed push.
_check_push_needed() {
    if ! git fetch origin main --quiet 2>/dev/null; then
        echo "WARNING: git fetch origin main failed — assuming push is needed."
        return 0
    fi
    local _ahead
    _ahead=$(git log origin/main..HEAD --oneline 2>/dev/null || true)
    if [[ -z "$_ahead" ]]; then
        echo "INFO: Push skipped - origin/main already contains HEAD (idempotent)."
        return 1
    fi
    return 0
}

# --- Load hooks/lib/deps.sh for get_artifacts_dir ---
# Needed for checkpoint sentinel verification (see below).
_HOOK_LIB="$CLAUDE_PLUGIN_ROOT/hooks/lib/deps.sh"
if [[ -f "$_HOOK_LIB" ]]; then
    source "$_HOOK_LIB"
fi

# --- Load project config (single batch call to read-config) ---
eval "$(bash "$_SCRIPT_DIR"/read-config.sh --batch 2>/dev/null || true)"
TICKETS_DIR="${TICKETS_DIRECTORY:-.tickets}"
export LOCKPICK_TICKETS_DIR="$TICKETS_DIR"

VISUAL_BASELINE_PATH="${MERGE_VISUAL_BASELINE_PATH:-}"
CI_WORKFLOW_NAME="${MERGE_CI_WORKFLOW_NAME:-}"
MSG_EXCLUSION_PATTERN="${MERGE_MESSAGE_EXCLUSION_PATTERN:-}"

# Post-merge validation commands
# Defaults: make format-check (commands.format_check), make lint (commands.lint)
CMD_FORMAT_CHECK="${COMMANDS_FORMAT_CHECK:-make format-check}"
CMD_LINT="${COMMANDS_LINT:-make lint}"

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
# Exclude the configured tickets directory — ticket files are created by tk
# and should never block a merge regardless of sync infrastructure.
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

# --- 1.7) Verify checkpoint review sentinel ---
# Run BEFORE the sync (step 1.5) so that compaction events or fetch operations
# during the sync cannot introduce new checkpoint commits that postdate the last
# deletion and cause a false positive.
#
# If any commit in this worktree branch added or modified .checkpoint-needs-review
# (written by pre-compact-checkpoint.sh during compaction), verify that a subsequent
# commit DELETED the sentinel — proving it was cleared via /review + /commit.
#
# On multi-session branches the sentinel may be added, cleared, and re-added multiple
# times; we only require that the most recent ADD/MODIFY is an ancestor of the most
# recent DELETE — meaning every checkpoint was ultimately reviewed before merge.
#
# Uses HEAD as the upper bound (not origin/main) because origin/main has not been
# fetched yet at this point — the pre-sync HEAD is the stable reference.
_PRESYNC_HEAD=$(git rev-parse HEAD)
_PRESYNC_MERGE_BASE=$(git merge-base HEAD origin/main 2>/dev/null || echo "")
_SENTINEL_RANGE="${_PRESYNC_MERGE_BASE:+${_PRESYNC_MERGE_BASE}..}${_PRESYNC_HEAD}"
_LAST_CHECKPOINT_ADD=$(git log "$_SENTINEL_RANGE" --diff-filter=AM --format="%H" -- .checkpoint-needs-review 2>/dev/null | head -1 || true)
if [[ -n "$_LAST_CHECKPOINT_ADD" ]]; then
    _LAST_CHECKPOINT_DEL=$(git log "$_SENTINEL_RANGE" --diff-filter=D --format="%H" -- .checkpoint-needs-review 2>/dev/null | head -1 || true)
    if [[ -z "$_LAST_CHECKPOINT_DEL" ]]; then
        echo "ERROR: Unreviewed checkpoint commit detected."
        echo "  A pre-compaction auto-save exists but the sentinel was never deleted."
        echo "  Run /commit (which includes /review) to review and clear the sentinel."
        echo "  Checkpoint commit: ${_LAST_CHECKPOINT_ADD:0:12}"
        exit 1
    fi
    # Verify the deletion is a descendant of the last addition (deletion came after add).
    if ! git merge-base --is-ancestor "$_LAST_CHECKPOINT_ADD" "$_LAST_CHECKPOINT_DEL" 2>/dev/null; then
        echo "ERROR: Unreviewed checkpoint commit detected."
        echo "  A checkpoint was added after the last sentinel deletion."
        echo "  Run /commit (which includes /review) to review and clear the sentinel."
        echo "  Checkpoint commit: ${_LAST_CHECKPOINT_ADD:0:12}"
        exit 1
    fi
    echo "OK: Checkpoint sentinel was cleared (deletion at ${_LAST_CHECKPOINT_DEL:0:12} follows last add at ${_LAST_CHECKPOINT_ADD:0:12})."
fi

# --- 1.5) Sync worktree with main ---
# Delegates to worktree-sync-from-main.sh which handles:
#   - Fetching and merging origin/main
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

# Capture pre-merge SHA so we can later detect whether the merge contained
# non-.tickets/ changes (used for the CI trigger check after push).
PRE_MERGE_SHA=$(git rev-parse HEAD)

echo "Merging $BRANCH into main..."
if ! git merge --no-ff "$BRANCH" -m "$MERGE_MSG" --quiet 2>&1; then
    CONFLICTED=$(git diff --name-only --diff-filter=U 2>/dev/null || true)
    git merge --abort 2>/dev/null || true
    echo "ERROR: Merge conflict. Aborted merge."
    # Structured output for /resolve-conflicts skill consumption
    echo "CONFLICT_DATA: branch=$BRANCH merge_base=$(git merge-base main "$BRANCH" 2>/dev/null || echo unknown)"
    if [ -n "$CONFLICTED" ]; then
        echo "CONFLICT_FILES: $CONFLICTED"
    fi
    exit 1
fi
echo "OK: Merged $BRANCH into main."

# --- 3.5) Post-merge validation ---
# Pre-commit hooks use stages: [commit] which excludes merge commits.
# Run format-check and lint here to catch issues that bypass pre-commit via merge.
_APP_DIR_NAME="${PATHS_APP_DIR:-app}"
if [ -d "$MAIN_REPO/$_APP_DIR_NAME" ]; then
    echo "Running post-merge validation (format-check + lint in parallel)..."
    POST_MERGE_FAIL=false
    create_managed_tempdir _VALIDATION_TMPDIR
    _FMT_LOG="${_VALIDATION_TMPDIR}/fmt.log"
    _LINT_LOG="${_VALIDATION_TMPDIR}/lint.log"

    # Run both checks concurrently as background jobs
    (cd "$MAIN_REPO/$_APP_DIR_NAME" && PY_RUN_APPROACH=local $CMD_FORMAT_CHECK 2>&1) > "$_FMT_LOG" &
    _FMT_PID=$!
    (cd "$MAIN_REPO/$_APP_DIR_NAME" && PY_RUN_APPROACH=local $CMD_LINT 2>&1) > "$_LINT_LOG" &
    _LINT_PID=$!

    # Collect exit codes after both finish
    wait $_FMT_PID
    _FMT_RC=$?
    wait $_LINT_PID
    _LINT_RC=$?

    if [[ $_FMT_RC -ne 0 ]]; then
        cat "$_FMT_LOG"
        echo "WARNING: Post-merge format-check failed. Run 'make format' to fix."
        POST_MERGE_FAIL=true
    fi
    if [[ $_LINT_RC -ne 0 ]]; then
        cat "$_LINT_LOG"
        echo "WARNING: Post-merge lint failed. Fix lint errors before pushing."
        POST_MERGE_FAIL=true
    fi
    rm -f "$_FMT_LOG" "$_LINT_LOG"

    if [[ "$POST_MERGE_FAIL" == "true" ]]; then
        echo "ERROR: Post-merge validation failed. Fix issues, amend the merge commit, then retry."
        exit 1
    fi
    echo "OK: Post-merge validation passed."
fi

# Stage any post-merge artifacts (.gitignore entries for worktree dirs)
git add .gitignore 2>/dev/null || true

# Auto-stage .tickets/ changes — CI failure tracking pushes ticket commits directly
# to main, and the merge can leave .tickets/ files dirty. These are data files, not
# code, so auto-staging into the merge commit is safe.
git add "$TICKETS_DIR"/ 2>/dev/null || true

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
if ! retry_with_backoff 4 2 git push 2>&1; then
    echo "ERROR: Push failed after retries. Try: git pull --rebase && git push"
    exit 1
fi
echo "OK: Pushed main to remote."

# --- 4.5) Archive closed tickets if count exceeds threshold ---
_ARCHIVE_SCRIPT="$_SCRIPT_DIR/archive-closed-tickets.sh"
if [ ! -f "$_ARCHIVE_SCRIPT" ]; then
    _ARCHIVE_SCRIPT="$MAIN_REPO/scripts/archive-closed-tickets.sh"
fi
if [ -f "$_ARCHIVE_SCRIPT" ]; then
    _CLOSED_COUNT=$(_count_closed_tickets "$TICKETS_DIR")
    if [ "$_CLOSED_COUNT" -gt 100 ]; then
        echo "Archiving $_CLOSED_COUNT closed ticket(s)..."
        _ARCHIVE_OUT=$(TICKETS_DIR="$TICKETS_DIR" bash "$_ARCHIVE_SCRIPT" 2>&1)
        echo "$_ARCHIVE_OUT"
        # Commit archived tickets if any were moved
        if echo "$_ARCHIVE_OUT" | grep -qE '^Archived [1-9]'; then
            git add "$TICKETS_DIR"/archive/ 2>/dev/null || true
            git add -u "$TICKETS_DIR"/ 2>/dev/null || true
            if ! git diff --cached --quiet 2>/dev/null; then
                git commit -m "chore: archive closed tickets [skip ci]" --quiet
                git push --quiet 2>&1 || echo "WARNING: Push of archive commit failed — retry with git push."
                echo "OK: Archived tickets committed and pushed."
            fi
        fi
    else
        echo "INFO: $_CLOSED_COUNT closed ticket(s) — below threshold (100), skipping archive."
    fi
else
    echo "INFO: archive-closed-tickets.sh not found — skipping archive step."
fi

# --- 5) Trigger CI if HEAD has [skip ci] but merge contained changes ---
# If a [skip ci] commit lands on top of the merge commit, CI is suppressed even
# though the merge contained real changes.
# Mitigation: if the merge introduced changes AND the current HEAD
# on origin carries [skip ci], explicitly dispatch the CI workflow so it runs.
HEAD_MSG=$(git log -1 --format='%s' origin/main 2>/dev/null || git log -1 --format='%s' 2>/dev/null || true)
CODE_CHANGES=$(git diff --name-only "$PRE_MERGE_SHA" HEAD 2>/dev/null | head -1 || true)
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
