#!/usr/bin/env bash
# hooks/lib/merge-helpers.sh
# Pure utility functions for merge-to-main.sh:
#   - State file helpers (resumable merge support)
#   - Lock acquire/release/wait primitives
#   - Stale git state and rebase auto-resolution helpers
#   - Push idempotency check
#   - Squash-rebase recovery
#
# Callers must set BRANCH before sourcing this file (used by _state_file_path).
# The following variables are used if set: MAX_MERGE_RETRIES, LOCK_WAIT_CEILING.
#
# Source this file after setting BRANCH:
#   source "${_SCRIPT_DIR}/../hooks/lib/merge-helpers.sh"

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
        # || true: state I/O is best-effort; set -e must not propagate from partial writes
        python3 -c "
import json
d = {'branch': '$BRANCH', 'merge_sha': '', 'completed_phases': [], 'current_phase': '', 'phases': {}}
with open('${_sf}.tmp', 'w') as f:
    json.dump(d, f)
" 2>/dev/null && mv "${_sf}.tmp" "$_sf" 2>/dev/null || true
    fi
    # Write a per-process marker so phases can distinguish a fresh init from inherited state.
    local _marker_file="/tmp/merge-state-init-marker-${BRANCH//\//-}"
    echo "${BASHPID:-$$}" > "$_marker_file" 2>/dev/null || true
    return 0
}

_state_write_phase() {
    local _phase="$1"
    local _sf
    _sf=$(_state_file_path) 2>/dev/null || return 0
    [[ -f "$_sf" ]] || return 0
    # || true: state I/O is best-effort; set -e must not propagate from partial/corrupt reads
    python3 -c "
import json
with open('$_sf') as f:
    d = json.load(f)
d['current_phase'] = '$_phase'
with open('${_sf}.tmp', 'w') as f:
    json.dump(d, f)
" 2>/dev/null && mv "${_sf}.tmp" "$_sf" 2>/dev/null || true
    return 0
}

_state_mark_complete() {
    local _phase="$1"
    local _sf
    _sf=$(_state_file_path) 2>/dev/null || return 0
    [[ -f "$_sf" ]] || return 0
    # || true: state I/O is best-effort; set -e must not propagate from partial/corrupt reads
    python3 -c "
import json
with open('$_sf') as f:
    d = json.load(f)
if '$_phase' not in d.get('completed_phases', []):
    d.setdefault('completed_phases', []).append('$_phase')
d.setdefault('phases', {})['$_phase'] = {'status': 'complete'}
with open('${_sf}.tmp', 'w') as f:
    json.dump(d, f)
" 2>/dev/null && mv "${_sf}.tmp" "$_sf" 2>/dev/null || true
    return 0
}

_set_phase_status() {
    local _phase="$1"
    local _status="$2"
    local _sf
    _sf=$(_state_file_path) 2>/dev/null || return 0
    [[ -f "$_sf" ]] || return 0
    # || true: state I/O is best-effort; set -e must not propagate from partial/corrupt reads
    python3 -c "
import json
with open('$_sf') as f:
    d = json.load(f)
d.setdefault('phases', {}).setdefault('$_phase', {})['status'] = '$_status'
with open('${_sf}.tmp', 'w') as f:
    json.dump(d, f)
" 2>/dev/null && mv "${_sf}.tmp" "$_sf" 2>/dev/null || true
    return 0
}

_state_record_merge_sha() {
    local _sha="$1"
    local _sf
    _sf=$(_state_file_path) 2>/dev/null || return 0
    [[ -f "$_sf" ]] || return 0
    # || true: state I/O is best-effort; set -e must not propagate from partial/corrupt reads
    python3 -c "
import json
with open('$_sf') as f:
    d = json.load(f)
d['merge_sha'] = '$_sha'
with open('${_sf}.tmp', 'w') as f:
    json.dump(d, f)
" 2>/dev/null && mv "${_sf}.tmp" "$_sf" 2>/dev/null || true
    return 0
}

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
    # || true: state I/O is best-effort; set -e must not propagate from partial/corrupt reads
    python3 -c "
import json
with open('$_sf') as f:
    d = json.load(f)
d['retry_count'] = d.get('retry_count', 0) + 1
with open('${_sf}.tmp', 'w') as f:
    json.dump(d, f)
" 2>/dev/null && mv "${_sf}.tmp" "$_sf" 2>/dev/null || true
    return 0
}

_state_reset_retry_count() {
    local _sf
    _sf=$(_state_file_path) 2>/dev/null || return 0
    [[ -f "$_sf" ]] || return 0
    # || true: state I/O is best-effort; set -e must not propagate from partial/corrupt reads
    python3 -c "
import json
with open('$_sf') as f:
    d = json.load(f)
d['retry_count'] = 0
with open('${_sf}.tmp', 'w') as f:
    json.dump(d, f)
" 2>/dev/null && mv "${_sf}.tmp" "$_sf" 2>/dev/null || true
    return 0
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
# Delegates detection to ms_is_rebase_in_progress (merge-state.sh library).
# No-op if no rebase state is present.
_abort_stale_rebase() {
    if type ms_is_rebase_in_progress >/dev/null 2>&1 && ms_is_rebase_in_progress; then
        git rebase --abort 2>/dev/null || true
        echo "INFO: Aborted stale rebase state before retry."
    fi
}

# --- Auto-resolve ticket-data conflicts during git pull --rebase ---
# Ticket event JSON files (.tickets-tracker/<id>/*.json) may appear as conflicts
# during rebase (e.g., during worktree sync). These are always safe to resolve by
# accepting our version (git add if present, git rm if absent).
# Non-ticket conflicts cause an immediate abort.
#
# Usage: call from the git pull --rebase failure handler in _phase_sync.
# Must be called while a rebase is in progress (REBASE_HEAD exists).
# Returns 0 on success (rebase continued), 1 on failure (rebase aborted).
_auto_resolve_archive_conflicts() {
    local _git_dir
    _git_dir=$(git rev-parse --git-dir 2>/dev/null) || return 1

    # Only proceed if a rebase is actually in progress
    if [[ ! -f "$_git_dir/REBASE_HEAD" ]]; then
        return 1
    fi

    # Collect all conflicted files (unmerged paths)
    local _conflicted_files
    _conflicted_files=$(git diff --name-only --diff-filter=U 2>/dev/null || true)

    # Also collect files listed in rebase conflict output (rename/delete shows differently)
    # git ls-files --unmerged captures all unmerged index entries
    local _unmerged_paths
    _unmerged_paths=$(git ls-files --unmerged 2>/dev/null | awk '{print $NF}' | sort -u || true)

    # Combine both lists
    local _all_conflicts
    _all_conflicts=$(printf '%s\n%s\n' "$_conflicted_files" "$_unmerged_paths" | sort -u | grep -v '^$' || true)

    if [[ -z "$_all_conflicts" ]]; then
        # No detectable conflicts from diff/ls-files — check git status porcelain
        # for rename/delete conflict types visible only there.
        # DU = deleted by us, UD = deleted by them, DD = both deleted, AA = both added, UA = added by them
        local _rename_delete
        _rename_delete=$(git status --porcelain 2>/dev/null | grep -E '^(DU|UD|DD|AA|UA)' | awk '{print $NF}' || true)
        _all_conflicts="$_rename_delete"
    fi

    if [[ -z "$_all_conflicts" ]]; then
        echo "INFO: _auto_resolve_archive_conflicts: no conflicts detected — skipping."
        return 1
    fi

    # Safety check: ALL conflicts must be ticket-data files (safe to auto-resolve).
    # Ticket data: v3 .tickets-tracker/<id>/*.json or .tickets-tracker/*.json (includes .index.json).
    local _non_archive_conflicts=0
    while IFS= read -r _file; do
        [[ -z "$_file" ]] && continue
        case "$_file" in
            .tickets-tracker/*/*.json | .tickets-tracker/*.json)
                # v3 ticket event JSON — safe to auto-resolve
                ;;
            *)
                _non_archive_conflicts=$(( _non_archive_conflicts + 1 ))
                ;;
        esac
    done <<< "$_all_conflicts"

    if [[ "$_non_archive_conflicts" -gt 0 ]]; then
        echo "INFO: _auto_resolve_archive_conflicts: non-archive conflicts present — aborting auto-resolve."
        git rebase --abort 2>/dev/null || true
        return 1
    fi

    # All conflicts are ticket-data files — resolve each one.
    # For JSON event file conflicts: accept ours (git add) — event files are
    # append-only and our version is always the authoritative local state.
    local _resolved=0
    local _failed=0

    while IFS= read -r _file; do
        [[ -z "$_file" ]] && continue

        if [[ "$_file" == .tickets-tracker/*.json || "$_file" == .tickets-tracker/*/*.json ]]; then
            # v3 ticket event JSON — accept ours (git add if present, git rm if absent)
            if [[ -f "$_file" ]]; then
                git add "$_file" 2>/dev/null && _resolved=$(( _resolved + 1 )) || _failed=$(( _failed + 1 ))
            else
                git rm --quiet --cached "$_file" 2>/dev/null || true
                _resolved=$(( _resolved + 1 ))
            fi
        fi
    done <<< "$_all_conflicts"

    if [[ "$_failed" -gt 0 ]]; then
        echo "ERROR: _auto_resolve_archive_conflicts: $_failed file(s) failed to resolve." >&2
        git rebase --abort 2>/dev/null || true
        return 1
    fi

    echo "INFO: Auto-resolved $_resolved archive rename/delete conflict(s)."

    # Continue the rebase — loop until fully complete.
    # A multi-commit rebase may have archive conflicts on more than one commit;
    # each `git rebase --continue` advances past one conflict commit and may
    # stop again at the next. We keep resolving and continuing until REBASE_HEAD
    # is gone (rebase complete) or we encounter a non-archive conflict (abort).
    # Clean up orphaned REBASE_HEAD if the rebase-merge dir is already gone.
    if [[ -f "$_git_dir/REBASE_HEAD" ]] && [[ ! -d "$_git_dir/rebase-merge" ]] && [[ ! -d "$_git_dir/rebase-apply" ]]; then
        rm -f "$_git_dir/REBASE_HEAD"
    fi

    local _loop_iters=0
    local _max_iters=50  # guard against infinite loops
    while [[ -f "$_git_dir/REBASE_HEAD" && ( -d "$_git_dir/rebase-merge" || -d "$_git_dir/rebase-apply" ) ]]; do
        _loop_iters=$(( _loop_iters + 1 ))
        if [[ "$_loop_iters" -gt "$_max_iters" ]]; then
            echo "ERROR: _auto_resolve_archive_conflicts: rebase loop exceeded $_max_iters iterations — aborting." >&2
            git rebase --abort 2>/dev/null || true
            return 1
        fi

        # Try to continue; capture exit code to distinguish conflict vs failure.
        local _continue_out _continue_rc=0
        _continue_out=$(GIT_EDITOR=: git rebase --continue 2>&1) || _continue_rc=$?

        # Clean up orphaned REBASE_HEAD after successful continue
        if [[ -f "$_git_dir/REBASE_HEAD" ]] && [[ ! -d "$_git_dir/rebase-merge" ]] && [[ ! -d "$_git_dir/rebase-apply" ]]; then
            rm -f "$_git_dir/REBASE_HEAD"
        fi

        # After --continue, check if we stopped again (new conflicts).
        if [[ -f "$_git_dir/REBASE_HEAD" ]]; then
            # Still in rebase — collect any new conflicts.
            local _new_conflicts
            _new_conflicts=$(git diff --name-only --diff-filter=U 2>/dev/null || true)
            local _new_unmerged
            _new_unmerged=$(git ls-files --unmerged 2>/dev/null | awk '{print $NF}' | sort -u || true)
            local _new_all
            _new_all=$(printf '%s\n%s\n' "$_new_conflicts" "$_new_unmerged" | sort -u | grep -v '^$' || true)

            if [[ -z "$_new_all" ]]; then
                # No conflicts yet rebase hasn't completed.
                if [[ "$_continue_rc" -ne 0 ]]; then
                    # rebase --continue failed without producing conflicts — likely a hook
                    # failure or other non-conflict error. Abort to avoid spinning.
                    echo "ERROR: _auto_resolve_archive_conflicts: rebase --continue failed (exit $_continue_rc) without new conflicts — aborting." >&2
                    echo "  Output: $_continue_out" >&2
                    git rebase --abort 2>/dev/null || true
                    return 1
                fi
                # May be an empty commit or editor pause — skip to advance.
                if ! GIT_EDITOR=: git rebase --continue 2>/dev/null; then
                    GIT_EDITOR=: git rebase --skip 2>/dev/null || true
                fi
                continue
            fi

            # Validate that all new conflicts are still ticket-data files.
            local _new_non_archive=0
            while IFS= read -r _nf; do
                [[ -z "$_nf" ]] && continue
                case "$_nf" in
                    .tickets-tracker/*/*.json | .tickets-tracker/*.json) ;;
                    *) _new_non_archive=$(( _new_non_archive + 1 )) ;;
                esac
            done <<< "$_new_all"

            if [[ "$_new_non_archive" -gt 0 ]]; then
                echo "INFO: _auto_resolve_archive_conflicts: non-ticket conflicts in subsequent commit — aborting auto-resolve." >&2
                git rebase --abort 2>/dev/null || true
                return 1
            fi

            # Resolve the new ticket-data conflicts (v3 JSON event files).
            local _new_resolved=0 _new_failed=0
            while IFS= read -r _nf; do
                [[ -z "$_nf" ]] && continue
                if [[ "$_nf" == .tickets-tracker/*.json || "$_nf" == .tickets-tracker/*/*.json ]]; then
                    # v3 ticket event JSON — accept ours
                    if [[ -f "$_nf" ]]; then
                        git add "$_nf" 2>/dev/null && _new_resolved=$(( _new_resolved + 1 )) || _new_failed=$(( _new_failed + 1 ))
                    else
                        git rm --quiet --cached "$_nf" 2>/dev/null || true
                        _new_resolved=$(( _new_resolved + 1 ))
                    fi
                fi
            done <<< "$_new_all"

            if [[ "$_new_failed" -gt 0 ]]; then
                echo "ERROR: _auto_resolve_archive_conflicts: $_new_failed file(s) failed to resolve in subsequent commit." >&2
                git rebase --abort 2>/dev/null || true
                return 1
            fi

            echo "INFO: Auto-resolved $_new_resolved additional archive conflict(s) (iteration $_loop_iters)."
        fi
    done

    echo "OK: Rebase completed successfully after archive conflict resolution (${_loop_iters} continuation(s))."
    return 0
}

# --- Clean up stale git state (rebase/merge/staged) on entry ---
# Usage: _cleanup_stale_git_state <repo_path>
# Aborts any leftover rebase or merge state from a prior interrupted run,
# and unstages any stale indexed changes from a prior session.
# Delegates detection to ms_is_rebase_in_progress / ms_is_merge_in_progress
# (merge-state.sh library). File removal (corrupted state fallback) still uses
# the resolved git-dir path directly.
# Safe to call on any repo — no-op if no stale state is present.
_cleanup_stale_git_state() {
    local repo_path="$1"
    local _git_dir
    _git_dir=$(git -C "$repo_path" rev-parse --git-dir 2>/dev/null) || return 0
    # Make absolute if relative
    if [[ "$_git_dir" != /* ]]; then
        _git_dir="$repo_path/$_git_dir"
    fi

    # Override git dir for the library so it operates on the target repo_path
    local _saved_ms_git_dir="${_MERGE_STATE_GIT_DIR:-}"
    _MERGE_STATE_GIT_DIR="$_git_dir"

    if type ms_is_rebase_in_progress >/dev/null 2>&1 && ms_is_rebase_in_progress; then
        git -C "$repo_path" rebase --abort 2>/dev/null || git -C "$repo_path" reset --merge 2>/dev/null || true
        # If git commands didn't clear it (e.g., corrupted state), remove directly
        rm -f "$_git_dir/REBASE_HEAD" 2>/dev/null || true
        echo "INFO: Cleaned up stale rebase state in $repo_path"
    fi

    if type ms_is_merge_in_progress >/dev/null 2>&1 && ms_is_merge_in_progress; then
        git -C "$repo_path" merge --abort 2>/dev/null || git -C "$repo_path" reset --merge 2>/dev/null || true
        rm -f "$_git_dir/MERGE_HEAD" 2>/dev/null || true
        echo "INFO: Cleaned up stale merge state in $repo_path"
    fi

    # Unstage any leftover staged changes from a prior interrupted session
    if ! git -C "$repo_path" diff --cached --quiet 2>/dev/null; then
        git -C "$repo_path" reset HEAD --quiet 2>/dev/null || true
        echo "INFO: Unstaged stale indexed changes in $repo_path"
    fi

    # Restore _MERGE_STATE_GIT_DIR
    if [[ -n "$_saved_ms_git_dir" ]]; then
        _MERGE_STATE_GIT_DIR="$_saved_ms_git_dir"
    else
        unset _MERGE_STATE_GIT_DIR
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
#      On conflict: print ACTION REQUIRED with conflicted file list, rebase --abort, return 1.
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
    if type ms_get_conflicted_files >/dev/null 2>&1; then
        _CONFLICTED_FILES=$(ms_get_conflicted_files)
    else
        _CONFLICTED_FILES=$(git diff --name-only --diff-filter=U 2>/dev/null || true)
    fi

    if [[ -z "$_CONFLICTED_FILES" ]]; then
        # No conflicts detected — unknown rebase failure
        git rebase --abort 2>/dev/null || true
        echo "ERROR: Rebase failed with no detectable conflicts." >&2
        return 1
    fi

    echo "ACTION REQUIRED: Rebase conflict in the following files:"
    echo "$_CONFLICTED_FILES"
    git rebase --abort 2>/dev/null || true
    return 1
}
