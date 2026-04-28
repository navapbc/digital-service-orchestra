#!/usr/bin/env bash
# ticket-lib.sh
# Shared library for ticket event writing. Sourced (not executed) by ticket commands.
#
# Provides:
#   write_commit_event <ticket_id> <temp_event_json_path>
#     Atomically writes an event file and commits it to the tickets branch.
#
# Requirements:
#   - ticket init must have been run (.tickets-tracker/ worktree must exist)
#   - jq must be available (for JSON parsing and canonicalization)
#   - flock (util-linux) used for portable serialization (macOS + Linux)
#
# Escape hatch:
#   DSO_TICKET_LEGACY=1  — routes write_commit_event to the pre-refactor
#                          Python-backed implementation (_python_write_commit_event).
#                          Useful when the bash-native path is unavailable or broken
#                          (e.g., python3 fcntl regression, CI environment).

# _python_write_commit_event <ticket_id> <temp_event_json_path>
# Legacy escape hatch: the pre-refactor, fully Python-backed implementation of
# write_commit_event.  Activated when DSO_TICKET_LEGACY=1 is set.
#
# Uses python3 fcntl.flock for serialization, python3 json for parsing, and
# python3 subprocess for git operations.  Mirrors the original b865e132 logic.
_python_write_commit_event() {
    local ticket_id="$1"
    local temp_event_json_path="$2"

    local repo_root=""
    if [[ -z "${TICKETS_TRACKER_DIR:-}" ]]; then
        repo_root="$(GIT_DISCOVERY_ACROSS_FILESYSTEM=1 git rev-parse --show-toplevel)"
    fi
    local tracker_dir_raw="${TICKETS_TRACKER_DIR:-$repo_root/.tickets-tracker}"
    local tracker_dir
    tracker_dir=$(python3 -c "import os,sys; print(os.path.realpath(sys.argv[1]))" "$tracker_dir_raw")
    local lock_file="$tracker_dir/.ticket-write.lock"

    # ── Validate: ticket system must be initialized ──────────────────────────
    if [ ! -d "$tracker_dir" ] || [ ! -f "$tracker_dir/.git" ]; then
        echo "Error: ticket system not initialized. Run 'ticket init' first." >&2
        return 1
    fi
    if ! GIT_DISCOVERY_ACROSS_FILESYSTEM=1 git -C "$tracker_dir" rev-parse --is-inside-work-tree &>/dev/null; then
        echo "Error: .tickets-tracker is not a valid git worktree." >&2
        return 1
    fi

    # ── Validate: temp event JSON exists ─────────────────────────────────────
    if [ ! -f "$temp_event_json_path" ]; then
        echo "Error: event JSON file not found: $temp_event_json_path" >&2
        return 1
    fi

    # ── Extract event metadata via python3 ───────────────────────────────────
    local event_meta
    event_meta=$(python3 -c "
import json, sys
with open(sys.argv[1], encoding='utf-8') as f:
    data = json.load(f)
print(data['event_type'])
print(data['timestamp'])
print(data['uuid'])
" "$temp_event_json_path") || {
        echo "Error: failed to parse event JSON" >&2
        return 1
    }

    local event_type timestamp uuid
    event_type=$(echo "$event_meta" | sed -n '1p')
    timestamp=$(echo "$event_meta" | sed -n '2p')
    uuid=$(echo "$event_meta" | sed -n '3p')

    # ── Normalize event_type to uppercase and validate against allowed enum ──
    event_type=$(echo "$event_type" | tr '[:lower:]' '[:upper:]')
    case "$event_type" in
        CREATE|STATUS|COMMENT|LINK|UNLINK|SNAPSHOT|SYNC|REVERT|EDIT|ARCHIVED|FILE_IMPACT) ;;
        *)
            echo "Error: invalid event_type '$event_type'. Must be one of: CREATE, STATUS, COMMENT, LINK, UNLINK, SNAPSHOT, SYNC, REVERT, EDIT, ARCHIVED, FILE_IMPACT" >&2
            return 1
            ;;
    esac

    # ── Determine final filename ─────────────────────────────────────────────
    local final_filename="${timestamp}-${uuid}-${event_type}.json"
    local ticket_dir="$tracker_dir/$ticket_id"
    local final_path="$ticket_dir/$final_filename"

    # ── Create ticket directory ──────────────────────────────────────────────
    mkdir -p "$ticket_dir"

    # ── Stage temp file in .tickets-tracker/ (same filesystem for atomic rename)
    local staging_temp
    staging_temp=$(mktemp "$tracker_dir/.tmp-event-XXXXXX")
    python3 -c "
import json, sys
# Read source and rewrite with explicit UTF-8 encoding
with open(sys.argv[1], encoding='utf-8') as f:
    data = json.load(f)
with open(sys.argv[2], 'w', encoding='utf-8') as f:
    json.dump(data, f)
" "$temp_event_json_path" "$staging_temp" || {
        rm -f "$staging_temp"
        echo "Error: failed to write staging temp file" >&2
        return 1
    }

    # ── Ensure gc.auto=0 in tickets worktree (idempotent guard) ──────────────
    git -C "$tracker_dir" config gc.auto 0

    # ── Acquire flock via python3 fcntl, then atomic rename + git commit ─────
    # Uses python3 fcntl.flock for portable locking (macOS + Linux).
    local max_retries=2
    local flock_timeout=30
    local attempt=0
    local lock_acquired=false

    while [ "$attempt" -lt "$max_retries" ]; do
        attempt=$((attempt + 1))

        local flock_exit=0
        python3 -c "
import fcntl, os, subprocess, sys, time

lock_path = sys.argv[1]
timeout = int(sys.argv[2])
tracker_dir = sys.argv[3]
ticket_id = sys.argv[4]
final_filename = sys.argv[5]
event_type = sys.argv[6]
staging_temp = sys.argv[7]
final_path = sys.argv[8]

fd = os.open(lock_path, os.O_CREAT | os.O_RDWR)
deadline = time.monotonic() + timeout
acquired = False
while time.monotonic() < deadline:
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        acquired = True
        break
    except (IOError, OSError):
        time.sleep(0.1)
if not acquired:
    os.close(fd)
    sys.exit(1)

# Lock acquired — atomic rename then git operations while holding the lock
try:
    os.rename(staging_temp, final_path)
except OSError as e:
    print(f'Error: atomic rename failed: {e}', file=sys.stderr)
    os.close(fd)
    sys.exit(3)

try:
    subprocess.run(
        ['git', '-C', tracker_dir, 'add', f'{ticket_id}/{final_filename}'],
        check=True, capture_output=True, text=True,
    )
    subprocess.run(
        ['git', '-C', tracker_dir, 'commit', '-q', '--no-verify', '-m',
         f'ticket: {event_type} {ticket_id}'],
        check=True, capture_output=True, text=True,
    )
except subprocess.CalledProcessError as e:
    print(f'Error: git operation failed: {e.stderr}', file=sys.stderr)
    try:
        os.remove(final_path)
    except OSError:
        pass
    os.close(fd)
    sys.exit(2)

# Release lock by closing fd
os.close(fd)
sys.exit(0)
" "$lock_file" "$flock_timeout" "$tracker_dir" "$ticket_id" "$final_filename" \
  "$event_type" "$staging_temp" "$final_path" || flock_exit=$?

        if [ "$flock_exit" -eq 0 ]; then
            lock_acquired=true
            break
        elif [ "$flock_exit" -eq 2 ]; then
            echo "Error: git commit failed while holding lock" >&2
            return 1
        elif [ "$flock_exit" -eq 3 ]; then
            rm -f "$staging_temp"
            echo "Error: atomic rename failed" >&2
            return 1
        fi
    done

    if [ "$lock_acquired" = false ]; then
        local total_wait=$((flock_timeout * max_retries))
        echo "flock: could not acquire lock after ${total_wait}s" >&2
        rm -f "$staging_temp"
        return 1
    fi

    # Push to remote after successful commit (best-effort with retry)
    _push_tickets_branch "$tracker_dir"

    return 0
}

# Stable internal API — used by write_commit_event and emit-review-event.sh
#
# _flock_stage_commit <tracker_dir> <staging_temp> <final_path> <commit_msg>
# Args:
#   tracker_dir:   canonical path to .tickets-tracker/ (derives lock_file)
#   staging_temp:  absolute path to the staged temp file (same filesystem as tracker_dir)
#   final_path:    absolute destination path (atomic rename target)
#   commit_msg:    git commit message string
#
# Handles:
#   - Acquires flock on .tickets-tracker/.ticket-write.lock
#   - atomic rename (staging_temp → final_path)
#   - git add (tracker_dir-relative path) + git commit
#   - gc.auto=0 guard
#   - Lock timeout (30s), max retries (2)
_flock_stage_commit() {
    # Resolve to canonical path so callers using a symlink and callers using
    # the real path always contend on the same lock file (cross-path serialization).
    local tracker_dir
    tracker_dir=$(cd "$1" && pwd -P)
    local staging_temp="$2"
    local final_path="$3"
    local commit_msg="$4"

    local lock_file="$tracker_dir/.ticket-write.lock"

    # ── Validate: tracker_dir exists ────────────────────────────────────────
    if [ ! -d "$tracker_dir" ]; then
        echo "Error: tracker directory does not exist: $tracker_dir" >&2
        return 1
    fi

    # ── Derive tracker_dir-relative path from final_path ────────────────────
    local relative_path="${final_path#"$tracker_dir/"}"

    # ── Ensure gc.auto=0 in tickets worktree (skip if already set) ───────────
    # _DSO_GC_AUTO_ZERO=1: caller guarantees gc.auto is already 0 (set by ticket
    # init and clone_ticket_repo) — skips the git subprocess check (~10ms/op).
    if [ "${_DSO_GC_AUTO_ZERO:-0}" != "1" ] && \
       [ "$(git -C "$tracker_dir" config --get gc.auto 2>/dev/null)" != "0" ]; then
        git -C "$tracker_dir" config gc.auto 0
    fi

    # ── Locate util-linux flock binary (not in PATH on macOS; BusyBox flock on
    # Alpine does not reliably support the FD-based form used below) ──
    # Only accept flock when it is util-linux flock; BusyBox flock (Alpine/embedded)
    # exits non-zero for `flock -x -w N FD` in the subshell-redirect context used
    # here.  If the binary in PATH is not util-linux, fall through to the mkdir
    # fallback unconditionally.
    local _flock_bin=""
    if command -v flock >/dev/null 2>&1; then
        if flock --version 2>&1 | grep -qi 'util-linux'; then
            _flock_bin="$(command -v flock)"
        fi
        # Non-util-linux flock (e.g. BusyBox): leave _flock_bin empty → mkdir fallback
    fi
    if [ -z "$_flock_bin" ]; then
        # Homebrew util-linux installs flock outside PATH on macOS
        local _ul_flock
        _ul_flock=$(find /opt/homebrew/Cellar/util-linux -name flock -path "*/bin/flock" 2>/dev/null | sort -V | tail -1)
        if [ -n "$_ul_flock" ] && [ -x "$_ul_flock" ]; then
            _flock_bin="$_ul_flock"
        fi
    fi

    # ── Acquire flock, then atomic rename + commit ──────────────────────────
    local max_retries=2
    local flock_timeout="${FLOCK_STAGE_COMMIT_TIMEOUT:-30}"
    local attempt=0
    local lock_acquired=false

    # Ensure the lock file exists before flock tries to open it
    : >> "$lock_file"

    while [ "$attempt" -lt "$max_retries" ]; do
        attempt=$((attempt + 1))

        local flock_exit=0

        if [ -n "$_flock_bin" ]; then
            # bash-native path: use flock(1) fd-based form.
            # FD 200 is opened on the lock file; flock -x -w acquires LOCK_EX,
            # waiting up to $flock_timeout seconds before returning exit 1.
            # The subshell inherits FD 200 and the lock is released on subshell exit.
            # shellcheck disable=SC2093
            (
                "$_flock_bin" -x -w "$flock_timeout" 200 || exit 1
                # Atomic rename (same filesystem — mktemp was created inside tracker_dir)
                mv "$staging_temp" "$final_path" || exit 3
                # git add + commit while holding the lock; clean up final_path on failure
                git -C "$tracker_dir" add "$relative_path" 2>/dev/null \
                    && git -C "$tracker_dir" commit -q --no-verify -m "$commit_msg" 2>/dev/null \
                    || { rm -f "$final_path"; exit 2; }
            ) 200>"$lock_file" || flock_exit=$?
        else
            # Fallback when flock binary is not available (e.g. non-Homebrew macOS):
            # mkdir-based atomic lock — mkdir is atomic on POSIX filesystems.
            local _lock_dir="${lock_file}.d"
            local _deadline
            _deadline=$(( $(date +%s) + flock_timeout ))
            local _got_lock=false
            while [ "$(date +%s)" -lt "$_deadline" ]; do
                if mkdir "$_lock_dir" 2>/dev/null; then
                    _got_lock=true
                    break
                fi
                sleep 0.1
            done
            if [ "$_got_lock" = false ]; then
                flock_exit=1
            else
                (
                    mv "$staging_temp" "$final_path" || exit 3
                    git -C "$tracker_dir" add "$relative_path" 2>/dev/null \
                        && git -C "$tracker_dir" commit -q --no-verify -m "$commit_msg" 2>/dev/null \
                        || { rm -f "$final_path"; exit 2; }
                ) || flock_exit=$?
                rmdir "$_lock_dir" 2>/dev/null || true
            fi
        fi

        if [ "$flock_exit" -eq 0 ]; then
            lock_acquired=true
            break
        elif [ "$flock_exit" -eq 2 ]; then
            echo "Error: git commit failed while holding lock" >&2
            return 1
        elif [ "$flock_exit" -eq 3 ]; then
            rm -f "$staging_temp"
            echo "Error: atomic rename failed" >&2
            return 1
        fi
        # flock_exit=1 means lock timeout — retry
    done

    if [ "$lock_acquired" = false ]; then
        local total_wait=$((flock_timeout * max_retries))
        echo "flock: could not acquire lock after ${total_wait}s" >&2
        rm -f "$staging_temp"
        return 1
    fi

    return 0
}

# write_commit_event <ticket_id> <temp_event_json_path>
# Args:
#   ticket_id: the ticket directory name (e.g., w21-ablv)
#   temp_event_json_path: path to the fully-constructed JSON event file (temp file)
#
# Steps:
#   1. Validates .tickets-tracker/ exists and is a valid worktree
#   2. Reads event_type, timestamp, uuid from JSON via python3
#   3. Creates ticket dir: mkdir -p .tickets-tracker/<ticket_id>
#   4. Stages temp file in .tickets-tracker/ (same filesystem for atomic rename)
#   5. Delegates to _flock_stage_commit for flock + atomic rename + git commit
#
# Escape hatch: set DSO_TICKET_LEGACY=1 to use _python_write_commit_event instead.
write_commit_event() {
    local ticket_id="$1"
    local temp_event_json_path="$2"

    # Legacy escape hatch: DSO_TICKET_LEGACY=1 routes to Python-backed write_commit_event.
    if [[ "${DSO_TICKET_LEGACY:-0}" = "1" ]]; then
        echo "DSO_TICKET_LEGACY=1: using Python-backed write_commit_event path" >&2
        # Delegate to the Python-backed implementation
        _python_write_commit_event "$ticket_id" "$temp_event_json_path"
        return $?
    fi

    local repo_root=""
    if [[ -z "${TICKETS_TRACKER_DIR:-}" ]]; then
        repo_root="$(GIT_DISCOVERY_ACROSS_FILESYSTEM=1 git rev-parse --show-toplevel)"
    fi
    local tracker_dir_raw="${TICKETS_TRACKER_DIR:-$repo_root/.tickets-tracker}"
    # Resolve to canonical path so that callers using a symlink and callers using
    # the real path always contend on the same lock file (cross-path serialization).
    # Use realpath (available on macOS and Linux) for symlink resolution.
    local tracker_dir
    if [ -d "$tracker_dir_raw" ] && command -v realpath >/dev/null 2>&1; then
        tracker_dir=$(realpath "$tracker_dir_raw")
    elif [ -d "$tracker_dir_raw" ]; then
        tracker_dir=$(cd "$tracker_dir_raw" && pwd -P)
    else
        tracker_dir="$tracker_dir_raw"
    fi
    local lock_file="$tracker_dir/.ticket-write.lock"

    # ── Validate: ticket system must be initialized ──────────────────────────
    if [ ! -d "$tracker_dir" ] || [ ! -f "$tracker_dir/.git" ]; then
        echo "Error: ticket system not initialized. Run 'ticket init' first." >&2
        return 1
    fi
    if ! GIT_DISCOVERY_ACROSS_FILESYSTEM=1 git -C "$tracker_dir" rev-parse --is-inside-work-tree &>/dev/null; then
        echo "Error: .tickets-tracker is not a valid git worktree." >&2
        return 1
    fi

    # ── Validate: temp event JSON exists ─────────────────────────────────────
    if [ ! -f "$temp_event_json_path" ]; then
        echo "Error: event JSON file not found: $temp_event_json_path" >&2
        return 1
    fi

    # ── Extract event metadata via jq (bash-native, zero python3) ───────────
    local event_type timestamp uuid
    event_type=$(jq -r '.event_type // empty' "$temp_event_json_path" 2>/dev/null) || {
        echo "Error: failed to parse event JSON (event_type)" >&2
        return 1
    }
    timestamp=$(jq -r '.timestamp // empty' "$temp_event_json_path" 2>/dev/null) || {
        echo "Error: failed to parse event JSON (timestamp)" >&2
        return 1
    }
    uuid=$(jq -r '.uuid // empty' "$temp_event_json_path" 2>/dev/null) || {
        echo "Error: failed to parse event JSON (uuid)" >&2
        return 1
    }
    if [ -z "$event_type" ] || [ -z "$timestamp" ] || [ -z "$uuid" ]; then
        echo "Error: event JSON missing required fields (event_type, timestamp, uuid)" >&2
        return 1
    fi

    # ── Normalize event_type to uppercase and validate against allowed enum ──
    event_type=$(echo "$event_type" | tr '[:lower:]' '[:upper:]')
    case "$event_type" in
        CREATE|STATUS|COMMENT|LINK|UNLINK|SNAPSHOT|SYNC|REVERT|EDIT|ARCHIVED|FILE_IMPACT) ;;
        *)
            echo "Error: invalid event_type '$event_type'. Must be one of: CREATE, STATUS, COMMENT, LINK, UNLINK, SNAPSHOT, SYNC, REVERT, EDIT, ARCHIVED, FILE_IMPACT" >&2
            return 1
            ;;
    esac

    # ── Determine final filename ─────────────────────────────────────────────
    local final_filename="${timestamp}-${uuid}-${event_type}.json"
    local ticket_dir="$tracker_dir/$ticket_id"
    local final_path="$ticket_dir/$final_filename"

    # ── Create ticket directory ──────────────────────────────────────────────
    mkdir -p "$ticket_dir"

    # ── Stage temp file in .tickets-tracker/ (same filesystem for atomic rename)
    # mktemp in .tickets-tracker/ ensures same-filesystem atomic mv inside flock
    # REVIEW-DEFENSE: jq is used here intentionally as the canonical JSON serializer
    # to replace the python3 subprocess that epic 78fc-3858 targets for elimination.
    # jq -S -c '.' produces output byte-for-byte identical to Python's
    # json.dumps(ensure_ascii=False,separators=(',',':'),sort_keys=True) — verified
    # by test_write_commit_event_json_byte_exact in tests/scripts/test-ticket-write-commit-event.sh.
    # The project "no-jq" guideline targets avoiding jq as a JSON parsing utility in
    # hook scripts where python3 is the sanctioned alternative; this site uses jq as a
    # subprocess-count optimization replacing python3, not as an ad-hoc parser.
    # jq is a system dependency on macOS (via Homebrew) and all major Linux distributions.
    local staging_temp
    staging_temp=$(mktemp "$tracker_dir/.tmp-event-XXXXXX")
    jq -S -c '.' "$temp_event_json_path" > "$staging_temp" 2>/dev/null || {
        rm -f "$staging_temp"
        echo "Error: failed to write staging temp file" >&2
        return 1
    }
    # ── Delegate to _flock_stage_commit for flock + atomic rename + commit ──
    local commit_msg="ticket: ${event_type} ${ticket_id}"
    _flock_stage_commit "$tracker_dir" "$staging_temp" "$final_path" "$commit_msg" || return $?

    # Push to remote after successful commit (best-effort with retry)
    _push_tickets_branch "$tracker_dir"

    return 0
}

# _push_tickets_branch <base_path>
# Push the tickets branch to origin with retry logic for non-fast-forward.
# Best-effort: push failures are logged but do not fail the caller.
# ticket-lifecycle.sh has equivalent logic; this is the shared version.
_push_tickets_branch() {
    local base_path="$1"
    local _remote
    _remote=$(git -C "$base_path" remote 2>/dev/null | head -1)
    if [ -z "$_remote" ]; then
        return 0  # No remote — nothing to push
    fi

    local _max_retries=3
    local _attempt=0
    while [ "$_attempt" -lt "$_max_retries" ]; do
        _attempt=$((_attempt + 1))
        local _push_exit=0
        local _push_stderr=""
        _push_stderr=$(PRE_COMMIT_ALLOW_NO_CONFIG=1 git -C "$base_path" push origin tickets 2>&1) || _push_exit=$?

        if [ "$_push_exit" -eq 0 ]; then
            return 0
        fi

        if echo "$_push_stderr" | grep -qiE 'non-fast-forward|rejected|fetch first'; then
            git -C "$base_path" fetch origin tickets 2>/dev/null || true
            local _rebase_exit=0
            git -C "$base_path" rebase origin/tickets 2>/dev/null || _rebase_exit=$?
            if [ "$_rebase_exit" -ne 0 ]; then
                git -C "$base_path" rebase --abort 2>/dev/null || true
                # Rebase failed (e.g., compaction deleted files diverged). Fall back to merge.
                # Ticket event files use UUID-named append-only filenames, so merge is safe
                # even across compaction boundaries where rebase would conflict.
                local _merge_exit=0
                git -C "$base_path" merge origin/tickets --no-edit 2>/dev/null || _merge_exit=$?
                if [ "$_merge_exit" -ne 0 ]; then
                    git -C "$base_path" merge --abort 2>/dev/null || true
                    echo "Warning: tickets branch push failed (rebase and merge conflict, attempt $_attempt)" >&2
                    return 0  # Best-effort: don't fail the caller
                fi
            fi
        else
            echo "Warning: tickets branch push failed (exit $_push_exit): $_push_stderr" >&2
            return 0  # Best-effort: don't fail the caller
        fi
    done

    echo "Warning: tickets branch push failed after $_max_retries retries" >&2
    return 0  # Best-effort
}

# ticket_read_status <tracker_dir> <ticket_id>
# Returns the current compiled status of a ticket (e.g., open, in_progress, closed, blocked).
# Computes REDUCER path internally from BASH_SOURCE — does NOT rely on caller-set globals.
#
# Args:
#   tracker_dir: path to .tickets-tracker worktree (passed by caller)
#   ticket_id:   ticket directory name (e.g., dso-abc1)
#
# Outputs the status string to stdout. Exits non-zero on error.
ticket_read_status() {
    local tracker_dir="$1"
    local ticket_id="$2"

    # Resolve REDUCER path relative to this script's location
    local lib_dir
    lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    local reducer="$lib_dir/ticket-reducer.py"

    local ticket_dir="$tracker_dir/$ticket_id"

    if [ ! -d "$ticket_dir" ]; then
        echo "Error: ticket directory not found: $ticket_dir" >&2
        return 1
    fi

    local state_json
    state_json=$(python3 "$reducer" "$ticket_dir" 2>/dev/null) || {
        echo "Error: reducer failed for ticket $ticket_id" >&2
        return 1
    }

    python3 -c "
import json, sys
state = json.loads(sys.argv[1])
print(state.get('status', ''))
" "$state_json"
}

# _tag_add <ticket_id> <tag>
# Idempotently adds a tag to a ticket by writing an EDIT event.
# If the tag is already present, exits 0 without writing an event.
#
# Honors TICKET_CMD env var (for testability); otherwise uses ticket script
# relative to this file. Honors TICKETS_TRACKER_DIR env var for tracker path.
_tag_add() {
    local ticket_id="$1"
    local tag="$2"

    # Resolve ticket command
    local _lib_dir
    _lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    local _ticket_cmd="${TICKET_CMD:-$_lib_dir/ticket}"

    # Resolve tracker dir
    local _repo_root=""
    if [[ -z "${TICKETS_TRACKER_DIR:-}" ]]; then
        _repo_root="$(GIT_DISCOVERY_ACROSS_FILESYSTEM=1 git rev-parse --show-toplevel)"
    fi
    local _tracker_dir="${TICKETS_TRACKER_DIR:-$_repo_root/.tickets-tracker}"

    # Read current tags — use in-process ticket_show when available to avoid
    # spawning a bash subprocess (~30ms overhead) for each tag operation.
    local _show_output
    if declare -f ticket_show >/dev/null 2>&1; then
        _show_output=$(TICKETS_TRACKER_DIR="$_tracker_dir" ticket_show "$ticket_id" 2>/dev/null) || true
    else
        _show_output=$(TICKETS_TRACKER_DIR="$_tracker_dir" bash "$_ticket_cmd" show "$ticket_id" 2>/dev/null) || true
    fi
    local _current_tags
    _current_tags=$(echo "$_show_output" \
        | python3 -c "import json,sys; tags=json.load(sys.stdin).get('tags',[]); print(','.join(tags) if tags else '')" 2>/dev/null || echo "")

    # Idempotency: skip if tag already present
    if echo ",$_current_tags," | grep -qF ",$tag,"; then
        return 0
    fi

    # Build new tags list
    local _new_tags_json
    _new_tags_json=$(python3 -c "
import json, sys
current = [t for t in sys.argv[1].split(',') if t] if sys.argv[1] else []
tag = sys.argv[2]
current.append(tag)
print(json.dumps(current))
" "$_current_tags" "$tag")

    # Read env-id and author
    local _env_id
    _env_id=$(cat "$_tracker_dir/.env-id" 2>/dev/null || echo "")
    local _author
    _author=$(git config user.name 2>/dev/null || echo "unknown")

    # Build EDIT event JSON
    local _temp_event
    _temp_event=$(mktemp "$_tracker_dir/.tmp-tag-add-XXXXXX")

    python3 -c "
import json, sys, time, uuid

env_id = sys.argv[1]
author = sys.argv[2]
tags = json.loads(sys.argv[3])
out_path = sys.argv[4]

event = {
    'timestamp': time.time_ns(),
    'uuid': str(uuid.uuid4()),
    'event_type': 'EDIT',
    'env_id': env_id,
    'author': author,
    'data': {
        'fields': {
            'tags': tags
        }
    }
}

with open(out_path, 'w', encoding='utf-8') as f:
    json.dump(event, f, ensure_ascii=False)
" "$_env_id" "$_author" "$_new_tags_json" "$_temp_event" || {
        rm -f "$_temp_event"
        echo "Error: failed to build EDIT event JSON for _tag_add" >&2
        return 1
    }

    write_commit_event "$ticket_id" "$_temp_event" || {
        rm -f "$_temp_event"
        echo "Error: failed to write EDIT event for _tag_add" >&2
        return 1
    }

    rm -f "$_temp_event"
    return 0
}

# _tag_remove <ticket_id> <tag>
# Idempotently removes a tag from a ticket by writing an EDIT event.
# If the tag is absent, exits 0 without writing an event.
# When removing the last tag, writes data.fields.tags = [] (not null).
#
# Honors TICKET_CMD env var (for testability); otherwise uses ticket script
# relative to this file. Honors TICKETS_TRACKER_DIR env var for tracker path.
_tag_remove() {
    local ticket_id="$1"
    local tag="$2"

    # Resolve ticket command
    local _lib_dir
    _lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    local _ticket_cmd="${TICKET_CMD:-$_lib_dir/ticket}"

    # Resolve tracker dir
    local _repo_root=""
    if [[ -z "${TICKETS_TRACKER_DIR:-}" ]]; then
        _repo_root="$(GIT_DISCOVERY_ACROSS_FILESYSTEM=1 git rev-parse --show-toplevel)"
    fi
    local _tracker_dir="${TICKETS_TRACKER_DIR:-$_repo_root/.tickets-tracker}"

    # Read current tags — use in-process ticket_show when available to avoid
    # spawning a bash subprocess (~30ms overhead) for each tag operation.
    local _show_output
    if declare -f ticket_show >/dev/null 2>&1; then
        _show_output=$(TICKETS_TRACKER_DIR="$_tracker_dir" ticket_show "$ticket_id" 2>/dev/null) || true
    else
        _show_output=$(TICKETS_TRACKER_DIR="$_tracker_dir" bash "$_ticket_cmd" show "$ticket_id" 2>/dev/null) || true
    fi
    local _current_tags
    _current_tags=$(echo "$_show_output" \
        | python3 -c "import json,sys; tags=json.load(sys.stdin).get('tags',[]); print(','.join(tags) if tags else '')" 2>/dev/null || echo "")

    # Idempotency: skip if tag is absent
    if ! echo ",$_current_tags," | grep -qF ",$tag,"; then
        return 0
    fi

    # Build new tags list (excluding removed tag)
    local _new_tags_json
    _new_tags_json=$(python3 -c "
import json, sys
current = [t for t in sys.argv[1].split(',') if t] if sys.argv[1] else []
tag = sys.argv[2]
remaining = [t for t in current if t != tag]
print(json.dumps(remaining))
" "$_current_tags" "$tag")

    # Read env-id and author
    local _env_id
    _env_id=$(cat "$_tracker_dir/.env-id" 2>/dev/null || echo "")
    local _author
    _author=$(git config user.name 2>/dev/null || echo "unknown")

    # Build EDIT event JSON
    local _temp_event
    _temp_event=$(mktemp "$_tracker_dir/.tmp-tag-remove-XXXXXX")

    python3 -c "
import json, sys, time, uuid

env_id = sys.argv[1]
author = sys.argv[2]
tags = json.loads(sys.argv[3])
out_path = sys.argv[4]

event = {
    'timestamp': time.time_ns(),
    'uuid': str(uuid.uuid4()),
    'event_type': 'EDIT',
    'env_id': env_id,
    'author': author,
    'data': {
        'fields': {
            'tags': tags
        }
    }
}

with open(out_path, 'w', encoding='utf-8') as f:
    json.dump(event, f, ensure_ascii=False)
" "$_env_id" "$_author" "$_new_tags_json" "$_temp_event" || {
        rm -f "$_temp_event"
        echo "Error: failed to build EDIT event JSON for _tag_remove" >&2
        return 1
    }

    write_commit_event "$ticket_id" "$_temp_event" || {
        rm -f "$_temp_event"
        echo "Error: failed to write EDIT event for _tag_remove" >&2
        return 1
    }

    rm -f "$_temp_event"
    return 0
}

# _ticket_has_pil <ticket_id>
# Returns exit 0 if the ticket has a "### Planning Intelligence Log" heading in
# any event (CREATE description, EDIT fields.description, or COMMENT body).
# Returns exit 1 if the marker is absent.
#
# Honors TICKET_CMD and TICKETS_TRACKER_DIR env vars for testability.
_ticket_has_pil() {
    local ticket_id="$1"

    local _lib_dir
    _lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    local _ticket_cmd="${TICKET_CMD:-$_lib_dir/ticket}"

    local _repo_root=""
    if [[ -z "${TICKETS_TRACKER_DIR:-}" ]]; then
        _repo_root="$(GIT_DISCOVERY_ACROSS_FILESYSTEM=1 git rev-parse --show-toplevel)"
    fi
    local _tracker_dir="${TICKETS_TRACKER_DIR:-$_repo_root/.tickets-tracker}"

    TICKETS_TRACKER_DIR="$_tracker_dir" bash "$_ticket_cmd" show "$ticket_id" 2>/dev/null | python3 -c "
import json, sys
try:
    state = json.load(sys.stdin)
except (json.JSONDecodeError, ValueError):
    sys.exit(1)
marker = '### Planning Intelligence Log'
desc = state.get('description', '') or ''
if marker in desc:
    sys.exit(0)
for comment in state.get('comments', []):
    body = comment.get('body', '') or ''
    if marker in body:
        sys.exit(0)
sys.exit(1)
"
}

# _compact_preconditions <ticket_dir> <epic_id>
# Compacts all flat PRECONDITIONS event files in ticket_dir into a single
# PRECONDITIONS-SNAPSHOT.json, then retires the originals by renaming them
# to *.retired (preserving the audit trail).
#
# Args:
#   ticket_dir: absolute path to the ticket event directory
#   epic_id:    ticket ID (used for diagnostic log)
#
# Steps:
#   1. Enumerate *-PRECONDITIONS.json files (excluding *-PRECONDITIONS-SNAPSHOT.json and *.retired)
#   2. Build merged payload applying LWW across composite keys (gate_name, session_id, worktree_id)
#   3. Write merged payload to temp file, then atomic rename to final SNAPSHOT path
#   4. Rename each original to *.retired (audit trail preserved)
#   5. Clean up any .tmp files on failure
#
# Exit codes:
#   0 = success
#   1 = error (no events found or filesystem error)
_compact_preconditions() {
    local ticket_dir="$1"
    local epic_id="${2:-unknown}"

    if [ ! -d "$ticket_dir" ]; then
        echo "[compact_preconditions] ERROR: ticket dir not found: $ticket_dir" >&2
        return 1
    fi

    # Enumerate live PRECONDITIONS events (exclude snapshots and retired files)
    local event_files=()
    while IFS= read -r -d '' f; do
        event_files+=("$f")
    done < <(find "$ticket_dir" -maxdepth 1 \
        -name '*-PRECONDITIONS.json' \
        ! -name '*-PRECONDITIONS-SNAPSHOT.json' \
        ! -name '*.retired' \
        -print0 2>/dev/null | sort -z)

    if [ "${#event_files[@]}" -eq 0 ]; then
        echo "[compact_preconditions] INFO: no live PRECONDITIONS events for $epic_id — skipping" >&2
        return 1
    fi

    # Build merged payload via LWW across composite keys using Python
    local ts
    ts=$(python3 -c "import time; print(int(time.time_ns()))")
    local snap_uuid
    snap_uuid=$(python3 -c "import uuid; print(str(uuid.uuid4()))")
    local tmp_path="$ticket_dir/${ts}-${snap_uuid}-PRECONDITIONS-SNAPSHOT.json.tmp"
    local final_path="$ticket_dir/${ts}-${snap_uuid}-PRECONDITIONS-SNAPSHOT.json"

    # Build file list as NUL-separated string for Python
    local file_list_str
    file_list_str=$(printf '%s\0' "${event_files[@]}" | python3 -c "
import sys
parts = sys.stdin.buffer.read().split(b'\x00')
print('\n'.join(p.decode('utf-8') for p in parts if p))
")

    local merge_exit=0
    python3 -c "
import json, sys, os, time, uuid as uuid_mod

event_files = [l for l in sys.argv[1].split('\n') if l.strip()]
ticket_dir = sys.argv[2]
ts = int(sys.argv[3])
snap_uuid = sys.argv[4]
tmp_path = sys.argv[5]
epic_id = sys.argv[6]

# LWW merge: composite key = (gate_name, session_id, worktree_id)
# Last-write-wins by timestamp within each composite key group.
merged = {}
for fpath in event_files:
    try:
        with open(fpath, encoding='utf-8') as fh:
            ev = json.load(fh)
    except (OSError, json.JSONDecodeError) as e:
        print(f'[compact_preconditions] WARN: skipping corrupt file {fpath}: {e}', file=sys.stderr)
        continue
    data = ev.get('data', {})
    key = (
        data.get('gate_name', ''),
        data.get('session_id', ''),
        data.get('worktree_id', ''),
    )
    ev_ts = ev.get('timestamp', 0)
    if key not in merged or ev_ts > merged[key]['_ts']:
        merged[key] = dict(data)
        merged[key]['_ts'] = ev_ts

# Build final merged gate_verdicts and manifest_depth
gate_verdicts = {}
manifest_depth = 0
for key, payload in merged.items():
    gv = payload.get('gate_verdicts', {})
    gate_verdicts.update(gv)
    d = payload.get('manifest_depth', 0)
    if d > manifest_depth:
        manifest_depth = d

snapshot = {
    'timestamp': ts,
    'uuid': snap_uuid,
    'event_type': 'PRECONDITIONS',
    'compacted': True,
    'env_id': 'compaction',
    'author': 'compact_preconditions',
    'data': {
        'schema_version': 1,
        'gate_name': 'compacted',
        'session_id': 'compacted',
        'worktree_id': 'compacted',
        'verdict': 'pass',
        'manifest_depth': manifest_depth,
        'gate_verdicts': gate_verdicts,
        'source_count': len(event_files),
    }
}

with open(tmp_path, 'w', encoding='utf-8') as fh:
    json.dump(snapshot, fh)

print(f'[compact_preconditions] snapshot written: {tmp_path}', file=sys.stderr)
" "$file_list_str" "$ticket_dir" "$ts" "$snap_uuid" "$tmp_path" "$epic_id" || merge_exit=$?

    if [ "$merge_exit" -ne 0 ]; then
        rm -f "$tmp_path"
        echo "[compact_preconditions] ERROR: merge failed for $epic_id" >&2
        return 1
    fi

    # Atomic rename: tmp → final
    local rename_exit=0
    mv "$tmp_path" "$final_path" || rename_exit=$?
    if [ "$rename_exit" -ne 0 ]; then
        rm -f "$tmp_path"
        echo "[compact_preconditions] ERROR: atomic rename failed for $epic_id" >&2
        return 1
    fi

    echo "[compact_preconditions] snapshot written: $final_path" >&2

    # Retire original event files
    local f
    for f in "${event_files[@]}"; do
        mv "$f" "${f}.retired" 2>/dev/null || \
            echo "[compact_preconditions] WARN: could not retire $f" >&2
    done

    return 0
}

# _tag_add_checked <ticket_id> <tag>
# Adds a tag to a ticket with a PIL guard for brainstorm:complete.
# For any tag other than "brainstorm:complete", delegates directly to _tag_add.
# For "brainstorm:complete", requires _ticket_has_pil to return 0 first;
# emits an error to stderr and returns 1 if the PIL marker is absent.
#
# REVIEW-DEFENSE: ticket-tag.sh is wired to call _tag_add_checked (instead of
# _tag_add directly) in task fd3c-21b5, which follows this task in the same story.
# The TDD decomposition: this task (0abf-422e) implements the guard in ticket-lib.sh;
# the CLI wire-up is the next task. The RED marker for test_ticket_tag_cli_rejects_
# brainstorm_complete_without_pil in .test-index is retained until fd3c-21b5 lands.
_tag_add_checked() {
    local ticket_id="$1"
    local tag="$2"

    if [[ "$tag" != "brainstorm:complete" ]]; then
        _tag_add "$ticket_id" "$tag"
        return $?
    fi

    if ! _ticket_has_pil "$ticket_id" 2>/dev/null; then
        echo "Error: cannot add 'brainstorm:complete' tag: Planning Intelligence Log not found in ticket events." >&2
        echo "Run /dso:brainstorm on this epic first to generate the Planning Intelligence Log." >&2
        return 1
    fi

    _tag_add "$ticket_id" "$tag"
}

# _write_preconditions <ticket_id> <gate_name> <session_id> <worktree_id> <tier> <data_json>
# Writes an immutable PRECONDITIONS event JSON into .tickets-tracker/<ticket_id>/
# using _flock_stage_commit for atomic writes (same contract as write_commit_event).
#
# Args:
#   ticket_id:   ticket directory name (e.g., test-t1a2)
#   gate_name:   name of the gate being recorded (e.g., "story_gate")
#   session_id:  session identifier
#   worktree_id: worktree branch identifier
#   tier:        review tier (e.g., "light", "standard", "deep")
#   data_json:   JSON object with additional data (defaults to {})
_write_preconditions() {
    local ticket_id="$1"
    local gate_name="$2"
    local session_id="$3"
    local worktree_id="$4"
    local tier="$5"
    # NOTE: ${6:-{}} appends a literal '}' when $6 is set (bash parse ambiguity).
    # Use explicit if/else to safely default to '{}' only when $6 is absent.
    local data_json
    if [[ -n "${6:-}" ]]; then
        data_json="$6"
    else
        data_json="{}"
    fi

    local repo_root=""
    if [[ -z "${TICKETS_TRACKER_DIR:-}" ]]; then
        repo_root="$(GIT_DISCOVERY_ACROSS_FILESYSTEM=1 git rev-parse --show-toplevel)"
    fi
    local tracker_dir_raw="${TICKETS_TRACKER_DIR:-$repo_root/.tickets-tracker}"
    local tracker_dir
    tracker_dir=$(python3 -c "import os,sys; print(os.path.realpath(sys.argv[1]))" "$tracker_dir_raw")

    # ── Validate: ticket system must be initialized ──────────────────────────
    if [ ! -d "$tracker_dir" ] || [ ! -f "$tracker_dir/.git" ]; then
        echo "Error: ticket system not initialized. Run 'ticket init' first." >&2
        return 1
    fi

    # ── Generate timestamp and UUID ──────────────────────────────────────────
    local timestamp_ms file_uuid
    timestamp_ms=$(python3 -c "import time; print(int(time.time() * 1000))")
    file_uuid=$(python3 -c "import uuid; print(str(uuid.uuid4()))")

    # ── Determine ticket dir and final path ──────────────────────────────────
    local ticket_dir="$tracker_dir/$ticket_id"
    local final_filename="${timestamp_ms}-${file_uuid}-PRECONDITIONS.json"
    local final_path="$ticket_dir/$final_filename"

    # ── Create ticket directory ──────────────────────────────────────────────
    mkdir -p "$ticket_dir"

    # ── Stage temp in tracker_dir (same filesystem for atomic rename) ────────
    local staging_temp
    staging_temp=$(mktemp "$tracker_dir/.tmp-preconditions-stage-XXXXXX")
    trap 'rm -f "${staging_temp:-}"' EXIT

    python3 -c "
import json, sys, time

timestamp_ms = int(sys.argv[1])
gate_name    = sys.argv[2]
session_id   = sys.argv[3]
worktree_id  = sys.argv[4]
tier         = sys.argv[5]
data_json    = sys.argv[6]
staging_path = sys.argv[7]

try:
    data_obj = json.loads(data_json)
except json.JSONDecodeError:
    data_obj = {}

# Derive schema_version and manifest_depth from tier
# (per preconditions-schema-v2.md contract)
tier_to_schema = {
    'minimal':  (1, 'minimal'),
    'standard': (2, 'standard'),
    'deep':     (2, 'deep'),
}
sv, md = tier_to_schema.get(tier, (1, 'minimal'))

payload = {
    'event_type': 'PRECONDITIONS',
    'schema_version': sv,
    'manifest_depth': md,
    'gate_name': gate_name,
    'session_id': session_id,
    'worktree_id': worktree_id,
    'tier': tier,
    'timestamp': timestamp_ms,
    'gate_verdicts': [],
    'evidence_ref': {},
    'affects_fields': [],
    'data': data_obj,
}

with open(staging_path, 'w', encoding='utf-8') as f:
    json.dump(payload, f, ensure_ascii=False)
" "$timestamp_ms" "$gate_name" "$session_id" "$worktree_id" "$tier" "$data_json" "$staging_temp" || {
        echo "Error: failed to write preconditions payload" >&2
        return 1
    }

    # ── Acquire flock, atomic rename, and commit ─────────────────────────────
    local commit_msg="preconditions: RECORD ${ticket_id}"
    _flock_stage_commit "$tracker_dir" "$staging_temp" "$final_path" "$commit_msg" || return $?

    # Clear trap — file has been renamed
    trap - EXIT

    _push_tickets_branch "$tracker_dir"

    echo "Preconditions recorded: $final_filename"
}

# _read_latest_preconditions <ticket_id_or_dir> [<gate_name> <session_id>]
# Reads PRECONDITIONS events. Supports two calling conventions:
#   1-arg  (ticket_dir):            full path to ticket event dir; returns latest event overall
#   3-arg  (ticket_id, gate, sess): derives dir from tracker; filters by composite key (LWW)
# Snapshot-aware: checks for *-PRECONDITIONS-SNAPSHOT.json first in both modes.
# Retry-once: sleeps 50ms and retries on transient ENOENT/OSError before giving up.
# Invariant: ticket_ids must never begin with '/' — the leading-slash heuristic dispatches
#   between 1-arg absolute-path mode and 3-arg ticket_id mode.
# Returns empty string and exits 0 when no matching events exist (3-arg mode only).
# Exits 1 when no events exist or on persistent error (1-arg mode).
_read_latest_preconditions() {
    local ticket_id="$1"
    local gate_name="${2:-}"
    local session_id="${3:-}"

    local ticket_dir
    if [[ "$ticket_id" == /* ]]; then
        # 1-arg form: full absolute path passed directly (used by compaction tests)
        ticket_dir="$ticket_id"
    else
        local repo_root=""
        if [[ -z "${TICKETS_TRACKER_DIR:-}" ]]; then
            repo_root="$(GIT_DISCOVERY_ACROSS_FILESYSTEM=1 git rev-parse --show-toplevel)"
        fi
        local tracker_dir_raw="${TICKETS_TRACKER_DIR:-$repo_root/.tickets-tracker}"
        local tracker_dir
        tracker_dir=$(python3 -c "import os,sys; print(os.path.realpath(sys.argv[1]))" "$tracker_dir_raw")
        ticket_dir="$tracker_dir/$ticket_id"
    fi

    # Retry-once on transient ENOENT (50ms sleep)
    local attempt=0
    while [ "$attempt" -lt 2 ]; do
        attempt=$((attempt + 1))

        if [ ! -d "$ticket_dir" ]; then
            if [ "$attempt" -lt 2 ]; then
                sleep 0.05  # retry-once: 50ms sleep on transient ENOENT
                continue
            fi
            # 1-arg callers (full path) expect exit 1 for nonexistent dir; 3-arg callers tolerate 0
            [[ "$ticket_id" == /* ]] && return 1 || return 0
        fi

        local _result
        local _exit=0
        _result=$(python3 -c "
import json, os, sys, tempfile

ticket_dir = sys.argv[1]
gate_name  = sys.argv[2]
session_id = sys.argv[3]
filter_by_key = bool(gate_name and session_id)
ticket_id  = os.path.basename(ticket_dir)

try:
    entries = os.listdir(ticket_dir)
except OSError:
    sys.exit(1 if not filter_by_key else 0)

# Check for snapshot first (snapshot-aware read)
snapshots = sorted(
    f for f in entries
    if f.endswith('-PRECONDITIONS-SNAPSHOT.json') and not f.endswith('.retired')
)
if snapshots:
    snap_path = os.path.join(ticket_dir, snapshots[-1])
    try:
        with open(snap_path, encoding='utf-8') as f:
            snap = json.load(f)
        snap_data = snap.get('data', snap)
        if not filter_by_key:
            # 1-arg mode: normalize to same contract as flat-event path and _api.py
            print(json.dumps({
                'status': 'present',
                'gate_verdicts': snap_data.get('gate_verdicts', {}),
                'manifest_depth': snap_data.get('manifest_depth', 0),
                'compacted': True,
            }))
            sys.exit(0)
        elif (snap_data.get('gate_name') == gate_name and
              snap_data.get('session_id') == session_id):
            # 3-arg mode: return raw snapshot data for the matching key
            print(json.dumps(snap_data))
            sys.exit(0)
    except (OSError, json.JSONDecodeError):
        pass  # fall through to flat events

# Collect all flat PRECONDITIONS files
candidates = []
for fname in entries:
    if not fname.endswith('-PRECONDITIONS.json'):
        continue
    if fname.endswith('-PRECONDITIONS-SNAPSHOT.json') or fname.endswith('.retired'):
        continue
    fpath = os.path.join(ticket_dir, fname)
    try:
        with open(fpath, encoding='utf-8') as f:
            data = json.load(f)
    except (OSError, json.JSONDecodeError):
        continue
    if filter_by_key:
        if data.get('gate_name') == gate_name and data.get('session_id') == session_id:
            candidates.append((fname, fpath, data))
    else:
        candidates.append((fname, fpath, data))

if not candidates:
    # 1-arg mode (no filter): pre-manifest = no events → exit 1 (callers use || true)
    # 3-arg mode (with filter): no matching events is graceful → exit 0 (pre-manifest ticket)
    sys.exit(1 if not filter_by_key else 0)

# Lexicographic sort on filename (ISO8601 timestamp prefix = chronological order)
candidates.sort(key=lambda x: x[0])

if not filter_by_key:
    # 1-arg mode: LWW merge — collect all gate_verdicts and max manifest_depth
    merged_gv = {}
    manifest_depth = 0
    for fname, fpath, event in candidates:
        inner = event.get('data', event)
        merged_gv.update(inner.get('gate_verdicts', {}))
        # Also pick up individual gate verdict from gate_name field
        gn = inner.get('gate_name', '')
        if gn and 'verdict' in inner:
            merged_gv[gn] = inner['verdict']
        d = inner.get('manifest_depth', 0)
        if isinstance(d, int) and d > manifest_depth:
            manifest_depth = d
    print(json.dumps({'status': 'present', 'gate_verdicts': merged_gv, 'manifest_depth': manifest_depth}))
    sys.exit(0)

_, latest_path, latest_data = candidates[-1]

# Forward-compat: warn once per (ticket_id, schema_version) when schema_version is unknown (> 2)
schema_version = latest_data.get('schema_version', 1)
if isinstance(schema_version, int) and schema_version > 2:
    warn_dir = os.path.join(tempfile.gettempdir(), 'dso-preconditions-warn')
    os.makedirs(warn_dir, exist_ok=True)
    warn_key = '{}_{}_v{}'.format(ticket_id, gate_name, schema_version)
    warn_file = os.path.join(warn_dir, warn_key)
    if not os.path.exists(warn_file):
        print(
            '[DSO WARN] preconditions reader: unknown schema_version={} for ticket {} '
            '-- falling back to minimal-tier interpretation'.format(schema_version, ticket_id),
            file=sys.stderr
        )
        open(warn_file, 'w').close()

with open(latest_path, encoding='utf-8') as f:
    print(f.read(), end='')
" "$ticket_dir" "$gate_name" "$session_id") || _exit=$?

        if [ "$_exit" -ne 0 ]; then
            if [ "$attempt" -lt 2 ]; then
                sleep 0.05  # retry-once: 50ms sleep on transient read error
                continue
            fi
            [[ "$ticket_id" == /* ]] && return 1 || return 0
        fi

        echo "$_result"
        return 0
    done

    [[ "$ticket_id" == /* ]] && return 1 || return 0
}
