#!/usr/bin/env bash
set -euo pipefail
# scripts/merge-to-main.sh
# Merge worktree branch into main and push.
# Called by /dso:end-session after all worktree commits are done.
#
# Replaces the old two-script flow (sprintend-sync.sh + merge-to-main.sh).
# tk (the issue tracker) uses file-per-issue storage under .tickets/ and requires
# no sync step; changes to .tickets/ are committed normally as part of regular commits.
#
# Usage: scripts/merge-to-main.sh
# Exit codes: 0=success, 1=error
# Output: concise status for LLM consumption

set -euo pipefail

# --- CLI: --help (early exit before any context checks) ---
for _arg in "$@"; do
    if [[ "$_arg" == "--help" ]]; then
        cat <<'USAGE'
Usage: merge-to-main.sh [--phase=<name>|--resume|--help]

  --phase=<name>  Run a single named phase and exit. Valid phase names:
                    checkpoint_verify  sync  merge  validate  push  archive  ci_trigger
  --resume        Resume from last incomplete phase. On merge failure, squash-rebase
                  recovery runs automatically before retrying (up to 5 retries).
  --help          Print this usage message and exit.

  (no args)       Run all phases sequentially (backward compatible).

Merge recovery: on git merge failure the script squash-rebases the branch onto
main and retries. If recovery fails, run --resume (retry budget: 5 attempts).
USAGE
        exit 0
    fi
done

# --- Resolve repo root and cd into it ---
# This ensures relative path checks work regardless of where the script is called from
if ! REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null); then
    echo "ERROR: Not a git repository."
    exit 1
fi
cd "$REPO_ROOT"
WORKTREE_DIR="$REPO_ROOT"

_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLAUDE_PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT}"

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

_set_phase_status() {
    local _phase="$1"
    local _status="$2"
    local _sf
    _sf=$(_state_file_path) 2>/dev/null || return 0
    [[ -f "$_sf" ]] || return 0
    python3 -c "
import json
with open('$_sf') as f:
    d = json.load(f)
d.setdefault('phases', {}).setdefault('$_phase', {})['status'] = '$_status'
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

# Maximum number of --resume retries before escalating to the user
MAX_MERGE_RETRIES=5

_state_get_retry_count() {
    local _sf
    _sf=$(_state_file_path) 2>/dev/null || { echo "0"; return 0; }
    [[ -f "$_sf" ]] || { echo "0"; return 0; }
    python3 -c "
import json
with open('$_sf') as f:
    d = json.load(f)
print(d.get('retry_count', 0))
" 2>/dev/null || echo "0"
}

_state_increment_retry() {
    local _sf
    _sf=$(_state_file_path) 2>/dev/null || return 0
    [[ -f "$_sf" ]] || return 0
    python3 -c "
import json
with open('$_sf') as f:
    d = json.load(f)
d['retry_count'] = d.get('retry_count', 0) + 1
with open('${_sf}.tmp', 'w') as f:
    json.dump(d, f)
" 2>/dev/null && mv "${_sf}.tmp" "$_sf" 2>/dev/null
    return 0
}

_state_reset_retry_count() {
    local _sf
    _sf=$(_state_file_path) 2>/dev/null || return 0
    [[ -f "$_sf" ]] || return 0
    python3 -c "
import json
with open('$_sf') as f:
    d = json.load(f)
d['retry_count'] = 0
with open('${_sf}.tmp', 'w') as f:
    json.dump(d, f)
" 2>/dev/null && mv "${_sf}.tmp" "$_sf" 2>/dev/null
    return 0
}

# --- SIGURG trap: save current phase to state file before exit ---
# Registered after _state_init is called (see below, after BRANCH is set).
_sigurg_handler() {
    _state_write_phase "${_CURRENT_PHASE:-interrupted}" 2>/dev/null || true
    exit 0
}

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

# --- Lock wait with exponential backoff ---
# Usage: _wait_for_lock <lock_file> [ceiling_seconds]
# Polls for lock availability using _acquire_lock, with exponential backoff.
# If the existing lock is stale, removes it and retries immediately.
# Args:
#   lock_file       — path to the lock file
#   ceiling_seconds — max wait time (default: $LOCK_WAIT_CEILING or 300s = 5 minutes)
# Returns 0 on successful acquisition, 1 on timeout.
_wait_for_lock() {
    local lock_file="$1"
    local ceiling="${2:-${LOCK_WAIT_CEILING:-300}}"
    local elapsed=0
    local backoff=2

    while true; do
        # Try to acquire the lock
        if _acquire_lock "$lock_file"; then
            return 0
        fi

        # Lock exists and acquire failed — check staleness
        if _is_lock_stale "$lock_file"; then
            rm -f "$lock_file" 2>/dev/null
            # Retry immediately after clearing stale lock
            continue
        fi

        # Check if we've exceeded the ceiling
        if [[ "$elapsed" -ge "$ceiling" ]]; then
            echo "ERROR: Lock wait timed out after ${ceiling}s" >&2
            return 1
        fi

        # Report progress
        local holder_pid
        holder_pid=$(cut -d'|' -f1 < "$lock_file" 2>/dev/null || echo "unknown")
        echo "Waiting for merge lock... (${elapsed}s elapsed, held by PID ${holder_pid})" >&2

        # Sleep with exponential backoff (capped at 30s)
        sleep "$backoff"
        elapsed=$(( elapsed + backoff ))
        backoff=$(( backoff * 2 ))
        if [[ "$backoff" -gt 30 ]]; then
            backoff=30
        fi
    done
}

# --- Abort stale rebase helper ---
# Checks for leftover rebase state and aborts it before retrying a pull.
# If REBASE_HEAD exists in the git dir, a prior rebase was interrupted.
# No-op if no rebase state is present.
_abort_stale_rebase() {
    local _git_dir
    _git_dir=$(git rev-parse --git-dir 2>/dev/null) || return 0
    if [[ -f "$_git_dir/REBASE_HEAD" ]]; then
        git rebase --abort 2>/dev/null || true
        echo "INFO: Aborted stale rebase state before retry."
    fi
}

# --- Clean up stale git state (rebase/merge) on entry ---
# Usage: _cleanup_stale_git_state <repo_path>
# Aborts any leftover REBASE_HEAD or MERGE_HEAD state from a prior interrupted run.
# Safe to call on any repo — no-op if no stale state is present.
_cleanup_stale_git_state() {
    local repo_path="$1"
    local _git_dir
    _git_dir=$(git -C "$repo_path" rev-parse --git-dir 2>/dev/null) || return 0
    # Make absolute if relative
    if [[ "$_git_dir" != /* ]]; then
        _git_dir="$repo_path/$_git_dir"
    fi

    if [[ -f "$_git_dir/REBASE_HEAD" ]]; then
        git -C "$repo_path" rebase --abort 2>/dev/null || git -C "$repo_path" reset --merge 2>/dev/null || true
        # If git commands didn't clear it (e.g., corrupted state), remove directly
        rm -f "$_git_dir/REBASE_HEAD" 2>/dev/null || true
        echo "INFO: Cleaned up stale rebase state in $repo_path"
    fi

    if [[ -f "$_git_dir/MERGE_HEAD" ]]; then
        git -C "$repo_path" merge --abort 2>/dev/null || git -C "$repo_path" reset --merge 2>/dev/null || true
        rm -f "$_git_dir/MERGE_HEAD" 2>/dev/null || true
        echo "INFO: Cleaned up stale merge state in $repo_path"
    fi

    return 0
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

# --- Squash-rebase recovery helper ---
# Performs a squash-rebase sequence to linearize branch history before merge.
# Called by the merge phase on failure to recover from merge conflicts.
#
# Prerequisites: BRANCH must be set (validated on entry).
# Returns 0 on success, 1 on unrecoverable failure.
#
# Steps:
#   1. Count commits ahead of origin/main. If <=1, skip to step 4 (rebase only).
#   2. Capture pre-squash HEAD (_PRE_SQUASH_HEAD) for rollback on failure.
#      Squash via: git reset --soft <merge-base> + git commit.
#   3. If branch exists on origin: git push --force-with-lease.
#      On force-push failure: restore HEAD via git reset --soft, return 1.
#   4. GIT_EDITOR=: git rebase origin/main.
#      On conflict:
#        - If ONLY .tickets/.index.json conflicts: auto-resolve via merge-ticket-index.py
#          (extracts clean :1:/:2:/:3: staging versions before running the driver).
#        - Otherwise: print ACTION REQUIRED with conflicted file list, rebase --abort, return 1.
#   5. Print RECOVERY: Squash-rebase succeeded. Return 0.
_squash_rebase_recovery() {
    # Validate BRANCH is set
    if [[ -z "${BRANCH:-}" ]]; then
        echo "ERROR: _squash_rebase_recovery: BRANCH is not set." >&2
        return 1
    fi

    local _COMMIT_COUNT
    _COMMIT_COUNT=$(git rev-list --count origin/main..HEAD 2>/dev/null || echo "0")

    if [[ "$_COMMIT_COUNT" -gt 1 ]]; then
        # Step 2: Capture pre-squash HEAD for rollback
        local _PRE_SQUASH_HEAD
        _PRE_SQUASH_HEAD=$(git rev-parse HEAD)

        # Squash all branch commits into one via soft-reset to merge-base
        local _MERGE_BASE
        _MERGE_BASE=$(git merge-base HEAD origin/main)
        if ! git reset --soft "$_MERGE_BASE" 2>/dev/null; then
            echo "ERROR: git reset --soft failed during squash." >&2
            return 1
        fi
        if ! GIT_EDITOR=: git commit -m "Squashed branch commits for rebase" 2>/dev/null; then
            echo "ERROR: git commit failed during squash — restoring HEAD." >&2
            git reset --soft "$_PRE_SQUASH_HEAD" 2>/dev/null || true
            return 1
        fi

        # Step 3: Force-push the squashed commit if branch is on origin
        local _BRANCH_ON_ORIGIN=0
        if git ls-remote --exit-code origin "refs/heads/${BRANCH}" >/dev/null 2>&1; then
            _BRANCH_ON_ORIGIN=1
        fi

        if [[ "$_BRANCH_ON_ORIGIN" -eq 1 ]]; then
            echo "INFO: Pushing squashed commit to origin/${BRANCH} with --force-with-lease."
            if ! git push --force-with-lease origin "${BRANCH}" 2>/dev/null; then
                echo "ERROR: force-with-lease push failed — restoring pre-squash HEAD." >&2
                git reset --soft "$_PRE_SQUASH_HEAD" 2>/dev/null || true
                return 1
            fi
        fi
    fi

    # Step 4: Rebase onto origin/main
    # Fetch latest origin/main first so rebase sees up-to-date remote refs
    git fetch origin main --quiet 2>/dev/null || true

    if GIT_EDITOR=: git rebase origin/main 2>/dev/null; then
        echo "RECOVERY: Squash-rebase succeeded."
        return 0
    fi

    # Rebase failed — check which files conflict
    local _CONFLICTED_FILES
    _CONFLICTED_FILES=$(git diff --name-only --diff-filter=U 2>/dev/null || true)

    # Filter out .tickets/.index.json to see if there are other conflicts
    local _OTHER_CONFLICTS
    _OTHER_CONFLICTS=$(echo "$_CONFLICTED_FILES" | grep -v '^\.tickets/\.index\.json$' || true)

    if [[ -z "$_CONFLICTED_FILES" ]]; then
        # No conflicts detected — unknown rebase failure
        git rebase --abort 2>/dev/null || true
        echo "ERROR: Rebase failed with no detectable conflicts." >&2
        return 1
    fi

    if [[ -n "$_OTHER_CONFLICTS" ]]; then
        # Unresolvable conflicts in non-index files
        echo "ACTION REQUIRED: Rebase conflict in the following files:"
        echo "$_OTHER_CONFLICTS"
        git rebase --abort 2>/dev/null || true
        return 1
    fi

    # Only .tickets/.index.json is conflicted — auto-resolve via merge-ticket-index.py
    # Prefer CLAUDE_PLUGIN_ROOT (set at top-level in merge-to-main.sh and exported) so
    # the driver path is stable even when this function is eval'd in test contexts.
    local _MERGE_DRIVER
    if [[ -n "${CLAUDE_PLUGIN_ROOT}" && -f "${CLAUDE_PLUGIN_ROOT}/scripts/merge-ticket-index.py" ]]; then
        _MERGE_DRIVER="${CLAUDE_PLUGIN_ROOT}/scripts/merge-ticket-index.py"
    else
        local _SCRIPT_DIR_LOCAL
        _SCRIPT_DIR_LOCAL="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
        _MERGE_DRIVER="${_SCRIPT_DIR_LOCAL}/merge-ticket-index.py"
    fi

    if [[ ! -f "$_MERGE_DRIVER" ]]; then
        echo "ERROR: merge-ticket-index.py not found at $_MERGE_DRIVER — cannot auto-resolve." >&2
        git rebase --abort 2>/dev/null || true
        return 1
    fi

    # Extract clean versions from the git staging area (no conflict markers)
    local _TMP_RESOLVE
    _TMP_RESOLVE=$(mktemp -d)
    local _BASE_FILE="$_TMP_RESOLVE/base.json"
    local _OURS_FILE="$_TMP_RESOLVE/ours.json"
    local _THEIRS_FILE="$_TMP_RESOLVE/theirs.json"

    # :1: = common ancestor (base), :2: = ours (current branch), :3: = theirs (incoming)
    if ! git show :1:.tickets/.index.json > "$_BASE_FILE" 2>/dev/null; then
        echo "ERROR: Could not extract base version of .tickets/.index.json." >&2
        rm -rf "$_TMP_RESOLVE"
        git rebase --abort 2>/dev/null || true
        return 1
    fi
    if ! git show :2:.tickets/.index.json > "$_OURS_FILE" 2>/dev/null; then
        echo "ERROR: Could not extract ours version of .tickets/.index.json." >&2
        rm -rf "$_TMP_RESOLVE"
        git rebase --abort 2>/dev/null || true
        return 1
    fi
    if ! git show :3:.tickets/.index.json > "$_THEIRS_FILE" 2>/dev/null; then
        echo "ERROR: Could not extract theirs version of .tickets/.index.json." >&2
        rm -rf "$_TMP_RESOLVE"
        git rebase --abort 2>/dev/null || true
        return 1
    fi

    # Run the merge driver (writes result back to _OURS_FILE)
    if ! python3 "$_MERGE_DRIVER" "$_BASE_FILE" "$_OURS_FILE" "$_THEIRS_FILE" 2>/dev/null; then
        echo "ERROR: merge-ticket-index.py failed to auto-resolve .tickets/.index.json." >&2
        rm -rf "$_TMP_RESOLVE"
        git rebase --abort 2>/dev/null || true
        return 1
    fi

    # Copy resolved result back into the working tree
    cp "$_OURS_FILE" ".tickets/.index.json"
    rm -rf "$_TMP_RESOLVE"

    git add ".tickets/.index.json"
    if ! GIT_EDITOR=: git rebase --continue 2>/dev/null; then
        echo "ERROR: rebase --continue failed after auto-resolving .tickets/.index.json." >&2
        git rebase --abort 2>/dev/null || true
        return 1
    fi

    echo "RECOVERY: Squash-rebase succeeded."
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

# --- Initialize state file and register SIGURG trap ---
_state_init
trap '_sigurg_handler' URG

# =============================================================================
# Phase functions — each wraps a sequential phase with state recording
# =============================================================================

# --- 1.7) Verify checkpoint review sentinel ---
_phase_checkpoint_verify() {
    _CURRENT_PHASE="checkpoint_verify"
    _state_write_phase "checkpoint_verify"

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

    _state_mark_complete "checkpoint_verify"
}

# --- 1.5) Sync worktree with main ---
_phase_sync() {
    _CURRENT_PHASE="sync"
    _state_write_phase "sync"

    # Delegates to worktree-sync-from-main.sh which handles:
    #   - Fetching and merging origin/main
    # This surfaces merge conflicts here (where /dso:resolve-conflicts can operate)
    # rather than discovering them during the main-repo merge.

    # Fallback: try plugin dir first, then repo-root scripts/
    if [ -f "$_SCRIPT_DIR/worktree-sync-from-main.sh" ]; then
        source "$_SCRIPT_DIR/worktree-sync-from-main.sh"
    elif [ -f "${CLAUDE_PLUGIN_ROOT}/scripts/worktree-sync-from-main.sh" ]; then
        source "${CLAUDE_PLUGIN_ROOT}/scripts/worktree-sync-from-main.sh"
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
            "${CLAUDE_PLUGIN_ROOT}/scripts/verify-baseline-intent.sh" || BASELINE_CHECK_EXIT=$?
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
    # --- 2.3) Derive lock file path and clean stale git state ---
    LOCK_FILE="/tmp/merge-to-main-lock-$(echo -n "$MAIN_REPO" | shasum 2>/dev/null | cut -c1-8 || echo "default")"
    _cleanup_stale_git_state "$MAIN_REPO"

    # Verify main is checked out
    MAIN_BRANCH=$(git branch --show-current)
    if [ "$MAIN_BRANCH" != "main" ]; then
        echo "ERROR: Main repo is on '$MAIN_BRANCH', expected 'main'."
        exit 1
    fi

    # --- 2.4) Acquire merge lock (per-main-repo isolation) ---
    if ! _wait_for_lock "$LOCK_FILE"; then
        echo "ERROR: Could not acquire merge lock after timeout. Another merge may be in progress."
        exit 1
    fi
    # Release lock on any exit path (including CONFLICT_DATA exits)
    trap '_release_lock "$LOCK_FILE"' EXIT

    # --- 2.6) Pull remote changes before merging ---
    echo "Pulling remote changes..."
    # Stash any local changes so rebase pull can proceed
    STASHED=false
    if ! git diff --quiet 2>/dev/null || ! git diff --cached --quiet 2>/dev/null; then
        echo "Stashing local changes before pull..."
        git stash push --quiet -m "merge-to-main: pre-pull stash"
        STASHED=true
    fi
    _abort_stale_rebase
    if ! git pull --rebase 2>&1; then
        _abort_stale_rebase
        if $STASHED; then git stash pop --quiet 2>/dev/null || true; fi
        _set_phase_status "pull_rebase" "conflict"
        # Lock held via EXIT trap through conflict resolution
        echo "CONFLICT_DATA: phase=pull_rebase branch=$BRANCH"
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

    _state_mark_complete "sync"
}

# --- 3) Merge worktree branch ---
_phase_merge() {
    # _phase_merge() — calls _squash_rebase_recovery on failure, then retries merge.
    # On unrecoverable failure: _state_increment_retry, directive to run --resume.
    _CURRENT_PHASE="merge"
    _state_write_phase "merge"

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
        # First attempt failed — abort the merge and try squash-rebase recovery
        git merge --abort 2>/dev/null || true
        echo "INFO: Merge failed. Attempting squash-rebase recovery..."

        # Save current directory and cd back to worktree for squash-rebase
        _MERGE_SAVED_DIR="$(pwd)"
        cd "$WORKTREE_DIR"

        _RECOVERY_RC=0
        _squash_rebase_recovery 2>&1 || _RECOVERY_RC=$?

        if [ "$_RECOVERY_RC" -eq 0 ]; then
            # Recovery succeeded — return to main repo and retry the merge
            cd "$_MERGE_SAVED_DIR"
            echo "INFO: Squash-rebase recovery succeeded. Retrying merge..."
            if git merge --no-ff "$BRANCH" -m "$MERGE_MSG" --quiet 2>&1; then
                echo "OK: Merged $BRANCH into main (after squash-rebase recovery)."
            else
                # Retry also failed — increment retry count and exit with directive
                git merge --abort 2>/dev/null || true
                _state_increment_retry
                echo "ERROR: Merge retry failed after squash-rebase recovery."
                echo "  Run: merge-to-main.sh --resume"
                exit 1
            fi
        else
            # Recovery failed — return to main repo, increment retry, exit with directive
            cd "$_MERGE_SAVED_DIR"
            _state_increment_retry
            echo "ERROR: Squash-rebase recovery failed. Cannot resolve automatically."
            echo "  Run: merge-to-main.sh --resume"
            exit 1
        fi
    else
        echo "OK: Merged $BRANCH into main."
    fi

    _state_record_merge_sha "$(git rev-parse HEAD)"
    _state_mark_complete "merge"
}

# --- 3.5) Post-merge validation ---
_phase_validate() {
    _CURRENT_PHASE="validate"
    _state_write_phase "validate"

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

    _state_mark_complete "validate"
}

# --- 4) Push ---
_phase_push() {
    _CURRENT_PHASE="push"
    _state_write_phase "push"

    echo "Pushing main..."
    if ! _check_push_needed; then
        echo "INFO: Push skipped - already on origin/main."
    else
        if ! retry_with_backoff 4 2 git push 2>&1; then
            echo "ERROR: Push failed after retries. Try: git pull --rebase && git push"
            exit 1
        fi
        echo "OK: Pushed main to remote."
    fi

    _state_mark_complete "push"
}

# --- 4.5) Archive closed tickets if count exceeds threshold ---
_phase_archive() {
    _CURRENT_PHASE="archive"
    _state_write_phase "archive"

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

    _state_mark_complete "archive"
}

# --- 5) Trigger CI if HEAD has [skip ci] but merge contained changes ---
_phase_ci_trigger() {
    _CURRENT_PHASE="ci_trigger"
    _state_write_phase "ci_trigger"

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

    _state_mark_complete "ci_trigger"
}

# =============================================================================
# CLI argument dispatch
# =============================================================================

# Ordered list of all phase names (used by --resume to find next incomplete phase)
_ALL_PHASES=(checkpoint_verify sync merge validate push archive ci_trigger)

# --- Parse CLI arguments ---
_CLI_PHASE=""
_CLI_RESUME=false

for _arg in "$@"; do
    case "$_arg" in
        --phase=*)
            _CLI_PHASE="${_arg#--phase=}"
            ;;
        --resume)
            _CLI_RESUME=true
            ;;
        --help)
            # Already handled above (before worktree checks); should not reach here
            exit 0
            ;;
        *)
            echo "WARNING: Unknown argument '$_arg'. See --help for usage." >&2
            ;;
    esac
done

# --- Dispatch: --phase=<name> ---
if [[ -n "$_CLI_PHASE" ]]; then
    _DISPATCH_FN="_phase_${_CLI_PHASE}"
    if declare -f "$_DISPATCH_FN" > /dev/null 2>&1; then
        "$_DISPATCH_FN"
        echo "DONE: phase '$_CLI_PHASE' completed."
        exit 0
    else
        echo "ERROR: Unknown phase '$_CLI_PHASE'. Valid phases: ${_ALL_PHASES[*]}" >&2
        exit 1
    fi
fi

# --- Dispatch: --resume ---
if [[ "$_CLI_RESUME" == "true" ]]; then
    _sf=$(_state_file_path)
    # Escalation gate: check retry budget before attempting anything
    _resume_retry_count=$(_state_get_retry_count 2>/dev/null || echo "0")
    if [[ "$_resume_retry_count" -ge "$MAX_MERGE_RETRIES" ]]; then
        echo "ESCALATE: Merge has failed 5 times. Stop and ask the user for help. Do NOT retry."
        exit 1
    fi
    if [[ ! -f "$_sf" ]]; then
        echo "WARNING: No state file found at '$_sf'. Starting from the beginning."
        # Fall through to run all phases
    else
        # Read completed_phases and find the first incomplete phase
        _COMPLETED=$(python3 -c "
import json
with open('$_sf') as f:
    d = json.load(f)
print(' '.join(d.get('completed_phases', [])))
" 2>/dev/null || echo "")
        # Find the first phase with conflict state (fresh attempt)
        _CONFLICT_PHASE=$(python3 -c "
import json
with open('$_sf') as f:
    d = json.load(f)
phases = d.get('phases', {})
for name, info in phases.items():
    if info.get('status') == 'conflict':
        print(name)
        break
" 2>/dev/null || echo "")

        _FOUND_RESUME_START=false
        for _pname in "${_ALL_PHASES[@]}"; do
            # If this phase has a conflict, start fresh from here
            if [[ -n "$_CONFLICT_PHASE" && "$_pname" == "$_CONFLICT_PHASE" ]]; then
                echo "INFO: Resuming from phase '$_pname' (conflict state — fresh attempt)."
                _FOUND_RESUME_START=true
            fi
            if [[ "$_FOUND_RESUME_START" == "true" ]]; then
                "_phase_${_pname}"
            elif ! echo " $_COMPLETED " | grep -q " $_pname "; then
                # Not in completed_phases — start here
                echo "INFO: Resuming from phase '$_pname' (first incomplete phase)."
                _FOUND_RESUME_START=true
                "_phase_${_pname}"
            fi
            # else: phase is already complete — skip it
        done

        if [[ "$_FOUND_RESUME_START" == "false" ]]; then
            echo "INFO: All phases already complete (nothing to resume)."
        fi

        echo "DONE: $BRANCH resumed, merged, committed, and pushed."
        _state_reset_retry_count
        rm -f "$(_state_file_path)" 2>/dev/null
        exit 0
    fi
fi

# --- No-args (or state file missing for --resume): run all phases sequentially ---
if [[ $# -eq 0 ]]; then
    echo "WARNING: Running all phases sequentially. Use --phase=<name> to run a single phase" \
         "or --resume to continue from the last incomplete phase." >&2
fi

_phase_checkpoint_verify
_phase_sync
_phase_merge
_phase_validate
_phase_push
_phase_archive
_phase_ci_trigger

rm -f "$(_state_file_path)" 2>/dev/null
echo "DONE: $BRANCH merged, committed, and pushed."
