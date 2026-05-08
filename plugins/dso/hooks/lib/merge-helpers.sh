#!/usr/bin/env bash
# hooks/lib/merge-helpers.sh
# Pure utility functions for merge-to-main.sh:
#   - State file helpers (resumable merge support)
#   - Lock acquire/release/wait primitives
#   - Stale git state and rebase auto-resolution helpers
#   - Push idempotency check
#   - Squash-rebase recovery
#   - PR thread-resolution helpers (_pr_fetch_unresolved_threads,
#     _pr_thread_is_unresolved, _pr_post_thread_reply, _pr_resolve_thread,
#     _pr_settling_check)
#
# Callers must set BRANCH before sourcing this file (used by _state_file_path).
# The following variables are used if set: MAX_MERGE_RETRIES, LOCK_WAIT_CEILING.
#
# Source this file after setting BRANCH:
#   source "${_SCRIPT_DIR}/../hooks/lib/merge-helpers.sh"

# --- State file helpers (resumable merge support) ---
#
# Most of the helpers below share the same pattern: locate the state file,
# load JSON, mutate one field, atomic .tmp+mv write. The two private helpers
# `_state_set_field` and `_state_get_field` capture that pattern; the public
# helpers like `_state_record_merge_sha` are now thin wrappers around them.
# Helpers with non-trivial mutation (`_state_mark_complete`, `_set_phase_status`,
# `_state_increment_retry`, `_state_write_remediation_state`) keep their own
# python3 blocks because they touch nested structures or read-modify-write
# counters.

# Set a single top-level field on the state file.
# Args: $1=field name, $2=value, $3=value_kind (optional: "string" (default), "json")
#   - string: stored as-is via env-var passthrough.
#   - json:   parsed as JSON before storing — use for booleans, numbers, arrays.
# Best-effort: silent no-op when state file is unavailable.
_state_set_field() {
    local _field="$1" _value="$2" _kind="${3:-string}"
    local _sf
    _sf=$(_state_file_path) 2>/dev/null || return 0
    [[ -f "$_sf" ]] || return 0
    _DSO_SF="$_sf" _DSO_FIELD="$_field" _DSO_VALUE="$_value" _DSO_KIND="$_kind" python3 -c "
import json, os, sys
sf = os.environ['_DSO_SF']
field = os.environ['_DSO_FIELD']
raw = os.environ['_DSO_VALUE']
kind = os.environ['_DSO_KIND']
try:
    value = json.loads(raw) if kind == 'json' else raw
except Exception:
    value = raw
try:
    with open(sf) as f:
        d = json.load(f)
    d[field] = value
    with open(sf + '.tmp', 'w') as f:
        json.dump(d, f)
        f.flush()
        os.fsync(f.fileno())
except Exception:
    sys.exit(1)
" 2>/dev/null && mv "${_sf}.tmp" "$_sf" 2>/dev/null || true
    return 0
}

# Read a single top-level field from the state file.
# Args: $1=field name, $2=default (optional, prints when state file or field is absent)
# Prints the value on stdout; never errors.
_state_get_field() {
    local _field="$1" _default="${2:-}"
    local _sf
    _sf=$(_state_file_path) 2>/dev/null || { printf '%s' "$_default"; return 0; }
    [[ -f "$_sf" ]] || { printf '%s' "$_default"; return 0; }
    _DSO_SF="$_sf" _DSO_FIELD="$_field" _DSO_DEFAULT="$_default" python3 -c "
import json, os
try:
    with open(os.environ['_DSO_SF']) as f:
        d = json.load(f)
    v = d.get(os.environ['_DSO_FIELD'], None)
    if v is None:
        print(os.environ['_DSO_DEFAULT'])
    elif isinstance(v, bool):
        print('true' if v else 'false')
    else:
        print(v)
except Exception:
    print(os.environ['_DSO_DEFAULT'])
" 2>/dev/null || printf '%s' "$_default"
}

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
    _is_stale=$(_DSO_SF="$_sf" python3 -c "
import os, time
try:
    mtime = os.path.getmtime(os.environ['_DSO_SF'])
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
        # Pass variables via env to avoid shell-string interpolation injection
        # (branch names with quotes/backslashes/newlines would break python source).
        _DSO_BRANCH="$BRANCH" _DSO_SF="$_sf" python3 -c "
import json, os
sf = os.environ['_DSO_SF']
d = {'branch': os.environ['_DSO_BRANCH'], 'merge_sha': '', 'completed_phases': [], 'current_phase': '', 'phases': {}, 'merge_strategy': os.environ.get('MERGE_STRATEGY', 'direct')}
with open(sf + '.tmp', 'w') as f:
    json.dump(d, f)
    f.flush()
    os.fsync(f.fileno())
" 2>/dev/null && mv "${_sf}.tmp" "$_sf" 2>/dev/null || true
    fi
    # Write a per-process marker so phases can distinguish a fresh init from inherited state.
    local _marker_file="/tmp/merge-state-init-marker-${BRANCH//\//-}"
    echo "${BASHPID:-$$}" > "$_marker_file" 2>/dev/null || true
    return 0
}

_state_write_phase() {
    _state_set_field "current_phase" "$1"
}

_state_mark_complete() {
    local _phase="$1"
    local _sf
    _sf=$(_state_file_path) 2>/dev/null || return 0
    [[ -f "$_sf" ]] || return 0
    # || true: state I/O is best-effort; set -e must not propagate from partial/corrupt reads
    # Pass variables via env to avoid shell-string interpolation injection.
    _DSO_SF="$_sf" _DSO_PHASE="$_phase" python3 -c "
import json, os
sf = os.environ['_DSO_SF']
phase = os.environ['_DSO_PHASE']
with open(sf) as f:
    d = json.load(f)
if phase not in d.get('completed_phases', []):
    d.setdefault('completed_phases', []).append(phase)
d.setdefault('phases', {})[phase] = {'status': 'complete'}
with open(sf + '.tmp', 'w') as f:
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
    # Pass variables via env to avoid shell-string interpolation injection.
    _DSO_SF="$_sf" _DSO_PHASE="$_phase" _DSO_STATUS="$_status" python3 -c "
import json, os
sf = os.environ['_DSO_SF']
with open(sf) as f:
    d = json.load(f)
d.setdefault('phases', {}).setdefault(os.environ['_DSO_PHASE'], {})['status'] = os.environ['_DSO_STATUS']
with open(sf + '.tmp', 'w') as f:
    json.dump(d, f)
" 2>/dev/null && mv "${_sf}.tmp" "$_sf" 2>/dev/null || true
    return 0
}

_state_record_merge_sha() {
    _state_set_field "merge_sha" "$1"
}

_state_record_failed_run_id() {
    _state_set_field "failed_run_id" "$1"
}

# Read the last-recorded failed_run_id from the state file. Empty string when
# the state file or field is absent. Used by _phase_remediate to detect when
# _phase_poll has captured a new CI run after a fix push, so it can re-download
# fresh artifacts instead of reusing the original (now-stale) ones.
_state_read_failed_run_id() {
    _state_get_field "failed_run_id" ""
}

_state_get_retry_count() {
    _state_get_field "retry_count" "0"
}

_state_increment_retry() {
    local _sf
    _sf=$(_state_file_path) 2>/dev/null || return 0
    [[ -f "$_sf" ]] || return 0
    # || true: state I/O is best-effort; set -e must not propagate from partial/corrupt reads
    _DSO_SF="$_sf" python3 -c "
import json, os
sf = os.environ['_DSO_SF']
with open(sf) as f:
    d = json.load(f)
d['retry_count'] = d.get('retry_count', 0) + 1
with open(sf + '.tmp', 'w') as f:
    json.dump(d, f)
" 2>/dev/null && mv "${_sf}.tmp" "$_sf" 2>/dev/null || true
    return 0
}

_state_reset_retry_count() {
    _state_set_field "retry_count" "0" "json"
}

# Write remediation loop state to the state file atomically.
# Args: $1=phase (string), $2=attempts_per_tier (JSON object string), $3=attempts_global (integer)
_state_write_remediation_state() {
    local _phase="$1"
    local _per_tier="$2"
    local _global="$3"
    local _sf
    _sf=$(_state_file_path) 2>/dev/null || return 0
    [[ -f "$_sf" ]] || return 0
    # || true: state I/O is best-effort; set -e must not propagate from partial/corrupt reads
    # Pass variables via env to avoid shell-string interpolation injection.
    _DSO_SF="$_sf" _DSO_PHASE="$_phase" _DSO_PER_TIER="$_per_tier" _DSO_GLOBAL="$_global" python3 -c "
import json, os
sf = os.environ['_DSO_SF']
with open(sf) as f:
    d = json.load(f)
d['remediation_phase'] = os.environ['_DSO_PHASE']
try:
    d['remediation_attempts_per_tier'] = json.loads(os.environ['_DSO_PER_TIER'])
except Exception:
    d['remediation_attempts_per_tier'] = {}
try:
    d['remediation_attempts_global'] = int(os.environ['_DSO_GLOBAL'])
except Exception:
    d['remediation_attempts_global'] = 0
with open(sf + '.tmp', 'w') as f:
    json.dump(d, f)
" 2>/dev/null && mv "${_sf}.tmp" "$_sf" 2>/dev/null || true
    return 0
}

# Read remediation loop state from the state file.
# Outputs KEY=VALUE lines on stdout. Defaults when state file absent or fields missing.
_state_read_remediation_state() {
    local _sf
    _sf=$(_state_file_path) 2>/dev/null || {
        echo "remediation_phase="
        echo "remediation_attempts_per_tier={}"
        echo "remediation_attempts_global=0"
        return 0
    }
    if [[ ! -f "$_sf" ]]; then
        echo "remediation_phase="
        echo "remediation_attempts_per_tier={}"
        echo "remediation_attempts_global=0"
        return 0
    fi
    _DSO_SF="$_sf" python3 -c "
import json, os
try:
    with open(os.environ['_DSO_SF']) as f:
        d = json.load(f)
    phase = d.get('remediation_phase', '')
    per_tier = d.get('remediation_attempts_per_tier', {})
    global_cnt = d.get('remediation_attempts_global', 0)
    if isinstance(per_tier, dict):
        per_tier_str = json.dumps(per_tier)
    else:
        per_tier_str = str(per_tier)
    print('remediation_phase=' + str(phase))
    print('remediation_attempts_per_tier=' + per_tier_str)
    print('remediation_attempts_global=' + str(int(global_cnt)))
except Exception:
    print('remediation_phase=')
    print('remediation_attempts_per_tier={}')
    print('remediation_attempts_global=0')
" 2>/dev/null || {
        echo "remediation_phase="
        echo "remediation_attempts_per_tier={}"
        echo "remediation_attempts_global=0"
    }
    return 0
}

# Persist whether GitHub auto-merge is disabled at the repo level.
# When true, _phase_poll falls through to a manual `gh pr merge --merge`
# call after all checks pass, instead of waiting for auto-merge to fire.
# Args: $1 — "true" or "false"
_state_write_auto_merge_disabled() {
    local _val="$1"
    # Stored as JSON boolean — _state_get_field renders bools as "true"/"false" strings.
    if [[ "$_val" == "true" ]]; then
        _state_set_field "auto_merge_disabled" "true" "json"
    else
        _state_set_field "auto_merge_disabled" "false" "json"
    fi
}

# Read the auto_merge_disabled flag. Returns "true" or "false" on stdout.
# Default "false" when the state file is absent or the field is unset.
_state_read_auto_merge_disabled() {
    _state_get_field "auto_merge_disabled" "false"
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
# Ticket event JSON files (.tickets-tracker/<id>/*.json) may appear as conflicts # tickets-boundary-ok
# during rebase (e.g., during worktree sync). These are always safe to resolve by
# accepting our version (git add if present, git rm if absent).
# Non-ticket conflicts cause an immediate abort.
#
# The tickets directory is resolved from (in priority order):
#   1. TICKETS_TRACKER_DIR env var (allows test injection and custom config)
#   2. Default: .tickets-tracker
#
# Usage: call from the git pull --rebase failure handler in _phase_sync.
# Must be called while a rebase is in progress (REBASE_HEAD exists).
# Returns 0 on success (rebase continued), 1 on failure (rebase aborted).
_auto_resolve_archive_conflicts() {
    local _git_dir
    _git_dir=$(git rev-parse --git-dir 2>/dev/null) || return 1

    # Resolve configured tickets directory (TICKETS_TRACKER_DIR allows override
    # for non-default installs and test injection; default: .tickets-tracker).
    local _tickets_dir="${TICKETS_TRACKER_DIR:-.tickets-tracker}"
    # Strip any trailing slash for consistent prefix matching.
    _tickets_dir="${_tickets_dir%/}"
    # Escape glob metacharacters in the directory path so [[ == pattern ]] treats
    # the directory portion as a literal prefix, not a glob.
    local _tickets_dir_safe="${_tickets_dir//\*/\\*}"
    _tickets_dir_safe="${_tickets_dir_safe//\?/\\?}"
    _tickets_dir_safe="${_tickets_dir_safe//\[/\\[}"

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
    # Ticket data: v3 <tickets_dir>/<id>/*.json or <tickets_dir>/*.json (includes .index.json). # tickets-boundary-ok
    local _non_archive_conflicts=0
    while IFS= read -r _file; do
        [[ -z "$_file" ]] && continue
        # Use variable-based prefix matching since bash case arms cannot use variables.
        if [[ "$_file" == "${_tickets_dir_safe}"/*/*.json || "$_file" == "${_tickets_dir_safe}"/*.json ]]; then
            # v3 ticket event JSON — safe to auto-resolve
            :
        else
            _non_archive_conflicts=$(( _non_archive_conflicts + 1 ))
        fi
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

        # Use variable-based prefix matching since bash case arms cannot use variables. # tickets-boundary-ok
        if [[ "$_file" == "${_tickets_dir_safe}"/*.json || "$_file" == "${_tickets_dir_safe}"/*/*.json ]]; then
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
                # Use variable-based prefix matching since bash case arms cannot use variables. # tickets-boundary-ok
                if [[ "$_nf" != "${_tickets_dir_safe}"/*/*.json && "$_nf" != "${_tickets_dir_safe}"/*.json ]]; then
                    _new_non_archive=$(( _new_non_archive + 1 ))
                fi
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
                # Use variable-based prefix matching since bash case arms cannot use variables. # tickets-boundary-ok
                if [[ "$_nf" == "${_tickets_dir_safe}"/*.json || "$_nf" == "${_tickets_dir_safe}"/*/*.json ]]; then
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

    # (e.g., _phase_merge's recovery-failed branch in merge-to-main-direct.sh)
    # can populate CONFLICT_DATA after we return — otherwise the abort plus the
    # caller's `cd "$_MERGE_SAVED_DIR"` strips all conflict signal from the
    # working tree (fix for important finding 2026-05-01).
    export _SQUASH_REBASE_CONFLICTS="${_CONFLICTED_FILES:-}"

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

# --- Emit CONFLICT_DATA contract line ---
# Usage: _emit_conflict_data <branch> <base_branch> <resolution_strategy>
# Prints a single-line JSON contract describing a merge conflict, consumed by
# orchestrators (e.g., /dso:resolve-conflicts) and by the dispatcher tests.
#
# Schema (single line):
#   CONFLICT_DATA {"branch":"<branch>","base_branch":"<base_branch>",
#                  "conflicted_files":["<file>",...],
#                  "resolution_strategy":"<resolution_strategy>"}
#
# Conflicted files are computed via ms_get_conflicted_files (merge-state.sh) when
# available; falls back to `git diff --name-only --diff-filter=U`. The list is
# JSON-encoded with python3 (always available — already a hard dep of this lib).
# Emitting the line is best-effort — failures must not abort the caller.
#
# This helper is shared between merge-to-main-direct.sh (called before each
# exit 1 on the merge-failure path) and merge-to-main-pr.sh (S3a) so both
# strategies emit the same contract.
_emit_conflict_data() {
    local _branch="${1:-}"
    local _base_branch="${2:-main}"
    local _resolution_strategy="${3:-}"

    local _conflicted_files
    if type ms_get_conflicted_files >/dev/null 2>&1; then
        _conflicted_files=$(ms_get_conflicted_files 2>/dev/null || true)
    else
        _conflicted_files=$(git diff --name-only --diff-filter=U 2>/dev/null || true)
    fi

    # has already aborted the merge/rebase or cd'd to a non-conflicted repo),
    # fall back to _SQUASH_REBASE_CONFLICTS captured by _squash_rebase_recovery
    # before its rebase --abort. Preserves the contract on the recovery-failed
    # path in merge-to-main-direct.sh (fix for important finding 2026-05-01).
    if [[ -z "$_conflicted_files" && -n "${_SQUASH_REBASE_CONFLICTS:-}" ]]; then
        _conflicted_files="$_SQUASH_REBASE_CONFLICTS"
    fi

    # Build the JSON payload. Use python3 to safely encode the conflicted_files
    # list (handles spaces, quotes, unicode in filenames).
    local _payload
    _payload=$(BR="$_branch" BB="$_base_branch" RS="$_resolution_strategy" \
               CF="$_conflicted_files" \
               python3 -c '
import json, os
files = [ln for ln in os.environ.get("CF", "").splitlines() if ln.strip()]
print(json.dumps({
    "branch": os.environ.get("BR", ""),
    "base_branch": os.environ.get("BB", "main"),
    "conflicted_files": files,
    "resolution_strategy": os.environ.get("RS", ""),
}))
' 2>/dev/null) || _payload='{"branch":"'"$_branch"'","base_branch":"'"$_base_branch"'","conflicted_files":[],"resolution_strategy":"'"$_resolution_strategy"'"}'

    echo "CONFLICT_DATA $_payload"
    return 0
}

# =============================================================================
# PR Thread-Resolution Helpers
# =============================================================================
# These helpers wrap `gh api` calls for the PR review-thread resolution loop.
# They are designed to be tested via PATH-shadowed `gh` stubs (see T1 RED tests).
# All helpers exit 0 on success, exit 1 on API/parse error.
#
# Owner/repo is derived on first call and cached in _PR_REPO_NAME_WITH_OWNER.
# =============================================================================

# Module-level cache for owner/repo slug (populated on first call).
_PR_REPO_NAME_WITH_OWNER=""

# _pr_repo() — returns "owner/repo" slug (cached after first successful call).
# Exits 0 always; prints slug or empty string.
_pr_repo() {
    if [[ -n "${_PR_REPO_NAME_WITH_OWNER:-}" ]]; then
        echo "$_PR_REPO_NAME_WITH_OWNER"
        return 0
    fi
    local _slug
    _slug=$(gh repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null || echo "")
    # Only cache non-empty results — empty means auth/network failure; let next call retry.
    if [[ -n "$_slug" ]]; then
        _PR_REPO_NAME_WITH_OWNER="$_slug"
    fi
    echo "$_slug"
}

# _pr_fetch_unresolved_threads <pr_number>
# Fetches all review threads on the given PR via the reviewThreads GraphQL query.
# Filters to threads where isResolved=false.
# Prints one line per unresolved thread: <thread_node_id>\t<file_path>\t<line>\t<latest_comment_id>\t<body>
# Exit 0 on success (even if empty result); exit 1 on API/parse error.
_pr_fetch_unresolved_threads() {
    local _pr_number="$1"
    local _repo
    _repo=$(_pr_repo) || true

    local _query
    # shellcheck disable=SC2016  # GraphQL vars ($owner etc.) intentionally not expanded here
    _query='query($owner:String!,$repo:String!,$pr:Int!){repository(owner:$owner,name:$repo){pullRequest(number:$pr){reviewThreads(first:100){nodes{id,isResolved,path,line,comments(last:1){nodes{databaseId,body}}}}}}}'

    local _owner _reponame
    _owner="${_repo%%/*}"
    _reponame="${_repo##*/}"

    local _response
    _response=$(gh api graphql \
        -f query="$_query" \
        -f owner="$_owner" \
        -f repo="$_reponame" \
        -F pr="$_pr_number" 2>/dev/null) || {
        echo "ERROR: _pr_fetch_unresolved_threads: gh api graphql failed" >&2
        return 1
    }

    # Parse the response: extract unresolved threads and emit one line each.
    # Use python3 for JSON parsing (avoids jq dependency).
    # Write response to a temp file to avoid ARG_MAX limits on large PR responses.
    local _resp_tmp
    _resp_tmp=$(mktemp /tmp/pr-threads-resp.XXXXXX)
    printf '%s' "$_response" > "$_resp_tmp"
    # Capture python3's exit code via `|| _py_rc=$?`. The earlier pattern
    # (`<<'PYEOF' 2>/dev/null; local _py_rc=$?`) is wrong: the semicolon after
    # the heredoc terminator means $? captures the heredoc/list exit code
    # (always 0 here) instead of python3's exit code.
    local _py_rc=0
    python3 - "$_resp_tmp" <<'PYEOF' 2>/dev/null || _py_rc=$?
import sys, json, base64

response_str = open(sys.argv[1]).read()
try:
    data = json.loads(response_str)
except Exception as e:
    print(f"ERROR: failed to parse graphql response: {e}", file=sys.stderr)
    sys.exit(1)

try:
    nodes = data["data"]["repository"]["pullRequest"]["reviewThreads"]["nodes"]
except (KeyError, TypeError):
    # Empty or unexpected structure — treat as zero threads (not an error)
    sys.exit(0)

for node in nodes:
    if node.get("isResolved", True):
        continue
    thread_id = node.get("id", "")
    path = node.get("path", "")
    line = str(node.get("line") or "")
    comments = node.get("comments", {}).get("nodes", [])
    if comments:
        last_comment = comments[-1]
        comment_id = str(last_comment.get("databaseId", ""))
        body = last_comment.get("body", "")
        body_b64 = base64.b64encode(body.encode("utf-8")).decode("utf-8")
    else:
        comment_id = ""
        body_b64 = ""
    print(f"{thread_id}\t{path}\t{line}\t{comment_id}\t{body_b64}")
PYEOF
    rm -f "$_resp_tmp"
    [ "$_py_rc" -eq 0 ] || return 1
}

# _pr_thread_is_unresolved <thread_node_id>
# Idempotent precheck: queries the single thread by node ID.
# Prints "true" if isResolved=false; "false" otherwise (including missing/error).
# Exit 0 always (a missing thread is treated as "false").
_pr_thread_is_unresolved() {
    local _thread_id="$1"

    local _query
    # shellcheck disable=SC2016  # GraphQL vars ($threadId) intentionally not expanded here
    _query='query($threadId:ID!){node(id:$threadId){...on PullRequestReviewThread{id,isResolved}}}'

    local _response
    _response=$(gh api graphql \
        -f query="$_query" \
        -f threadId="$_thread_id" 2>/dev/null) || {
        echo "false"
        return 0
    }

    # Parse: extract isResolved from the node response.
    # Write response to a temp file to avoid ARG_MAX limits on large API responses.
    local _resp_tmp2
    _resp_tmp2=$(mktemp /tmp/pr-thread-check.XXXXXX)
    printf '%s' "$_response" > "$_resp_tmp2"
    # See companion fix in _pr_fetch_unresolved_threads: capture python3's
    # exit code via `|| _py2_rc=$?` rather than `; local _py2_rc=$?` after
    # the heredoc, which would always observe 0.
    local _py2_rc=0
    python3 - "$_resp_tmp2" "$_thread_id" <<'PYEOF' 2>/dev/null || _py2_rc=$?
import sys, json

response_str = open(sys.argv[1]).read()
try:
    data = json.loads(response_str)
except Exception:
    print("false")
    sys.exit(0)

# Check via node query result
try:
    node = data["data"]["node"]
    if node and not node.get("isResolved", True):
        print("true")
    else:
        print("false")
    sys.exit(0)
except (KeyError, TypeError):
    pass

# Fallback: check via reviewThreads list (when stub returns full reviewThreads structure)
# Only return true if the specific thread_node_id is unresolved.
thread_id_arg = sys.argv[2] if len(sys.argv) > 2 else ""
try:
    nodes = data["data"]["repository"]["pullRequest"]["reviewThreads"]["nodes"]
    for n in nodes:
        # Match by id when available; fall back to any-unresolved only when no id field
        if thread_id_arg and n.get("id") and n.get("id") != thread_id_arg:
            continue
        if not n.get("isResolved", True):
            print("true")
            sys.exit(0)
    print("false")
    sys.exit(0)
except (KeyError, TypeError):
    print("false")
    sys.exit(0)
PYEOF
    rm -f "$_resp_tmp2"
    if [ "$_py2_rc" -ne 0 ]; then
        echo "false"
        return 0
    fi
}

# _pr_post_thread_reply <pr_number> <comment_id> <reply_text>
# POSTs a reply to the given review comment via the REST API.
# Uses: gh api -X POST /repos/{owner}/{repo}/pulls/comments/{id}/replies
# (GitHub REST endpoint is scoped by comment_id only — no PR number in path.)
# Exit 0 on success; exit 1 on failure.
_pr_post_thread_reply() {
    local _pr_number="$1"
    local _comment_id="$2"
    local _reply_text="$3"
    local _repo
    _repo=$(_pr_repo) || true

    local _owner _reponame
    _owner="${_repo%%/*}"
    _reponame="${_repo##*/}"

    local _response
    _response=$(gh api \
        -X POST \
        "/repos/${_owner}/${_reponame}/pulls/comments/${_comment_id}/replies" \
        -f body="$_reply_text" 2>/dev/null) || {
        echo "ERROR: _pr_post_thread_reply: gh api POST failed" >&2
        return 1
    }

    return 0
}

# _pr_resolve_thread <thread_node_id>
# Resolves the given review thread via the resolveReviewThread GraphQL mutation.
# MUST first call _pr_thread_is_unresolved; only invokes the mutation when the
# result is "true". Idempotent: exit 0 on success or already-resolved no-op.
# Exit 1 on mutation error.
_pr_resolve_thread() {
    local _thread_id="$1"

    # Idempotent precheck: only resolve if not already resolved.
    local _is_unresolved
    _is_unresolved=$(_pr_thread_is_unresolved "$_thread_id") || true

    if [[ "$_is_unresolved" != "true" ]]; then
        # Already resolved — no-op.
        return 0
    fi

    # Invoke the resolveReviewThread mutation.
    local _mutation
    # shellcheck disable=SC2016  # GraphQL vars ($threadId) intentionally not expanded here
    _mutation='mutation($threadId:ID!){resolveReviewThread(input:{threadId:$threadId}){thread{id,isResolved}}}'

    local _response
    _response=$(gh api graphql \
        -f query="$_mutation" \
        -f threadId="$_thread_id" 2>/dev/null) || {
        echo "ERROR: _pr_resolve_thread: resolveReviewThread mutation failed" >&2
        return 1
    }

    return 0
}

# _pr_settling_check [--threads=<N>] [--quiet-window-elapsed=<true|false>]
# Heuristic: settled when BOTH hold:
#   1. Zero unresolved threads (--threads=0)
#   2. Quiet window has elapsed (--quiet-window-elapsed=true)
# CI state is not checked here — _phase_poll handles CI validation.
# --ci-green is accepted but ignored for backward compatibility.
# Exit 0 when settled; exit 1 when any condition is unmet.
_pr_settling_check() {
    local _threads="1"
    local _quiet_elapsed="false"

    for _arg in "$@"; do
        case "$_arg" in
            --ci-green=*)    : ;;  # accepted but ignored
            --threads=*)     _threads="${_arg#--threads=}" ;;
            --quiet-window-elapsed=*) _quiet_elapsed="${_arg#--quiet-window-elapsed=}" ;;
        esac
    done

    if [[ "$_threads" == "0" && "$_quiet_elapsed" == "true" ]]; then
        return 0
    fi
    return 1
}
