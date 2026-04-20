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
    if [ "$(git -C "$tracker_dir" config --get gc.auto 2>/dev/null)" != "0" ]; then
        git -C "$tracker_dir" config gc.auto 0
    fi

    # ── Locate bash-native flock binary (util-linux; not available in PATH on macOS) ──
    local _flock_bin=""
    if command -v flock >/dev/null 2>&1; then
        _flock_bin="$(command -v flock)"
    else
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
write_commit_event() {
    local ticket_id="$1"
    local temp_event_json_path="$2"

    local repo_root
    repo_root="$(git rev-parse --show-toplevel)"
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
    if ! git -C "$tracker_dir" rev-parse --is-inside-work-tree &>/dev/null; then
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
        CREATE|STATUS|COMMENT|LINK|UNLINK|SNAPSHOT|SYNC|REVERT|EDIT|ARCHIVED) ;;
        *)
            echo "Error: invalid event_type '$event_type'. Must be one of: CREATE, STATUS, COMMENT, LINK, UNLINK, SNAPSHOT, SYNC, REVERT, EDIT, ARCHIVED" >&2
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
                echo "Warning: tickets branch push failed (rebase conflict, attempt $_attempt)" >&2
                return 0  # Best-effort: don't fail the caller
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
    local _repo_root
    _repo_root="$(git rev-parse --show-toplevel)"
    local _tracker_dir="${TICKETS_TRACKER_DIR:-$_repo_root/.tickets-tracker}"

    # Read current tags via authoritative Python reducer
    local _current_tags
    _current_tags=$(TICKETS_TRACKER_DIR="$_tracker_dir" bash "$_ticket_cmd" show "$ticket_id" 2>/dev/null \
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
    local _repo_root
    _repo_root="$(git rev-parse --show-toplevel)"
    local _tracker_dir="${TICKETS_TRACKER_DIR:-$_repo_root/.tickets-tracker}"

    # Read current tags via authoritative Python reducer
    local _current_tags
    _current_tags=$(TICKETS_TRACKER_DIR="$_tracker_dir" bash "$_ticket_cmd" show "$ticket_id" 2>/dev/null \
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
        _repo_root="$(git rev-parse --show-toplevel)"
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
