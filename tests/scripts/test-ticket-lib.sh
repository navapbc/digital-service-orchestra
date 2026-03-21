#!/usr/bin/env bash
# tests/scripts/test-ticket-lib.sh
# RED tests for plugins/dso/scripts/ticket-lib.sh — write_commit_event helper.
#
# All tests MUST FAIL until ticket-lib.sh is implemented.
# Covers: atomic write, flock serialization, specific-file git commit, gc.auto=0,
# and clean failure when ticket init has not been run.
#
# Usage: bash tests/scripts/test-ticket-lib.sh
# Returns: exit non-zero (RED) until ticket-lib.sh is implemented.

# NOTE: -e is intentionally omitted — test functions return non-zero by design
# (they assert against unimplemented features). -e would abort the runner.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"
TICKET_SCRIPT="$REPO_ROOT/plugins/dso/scripts/ticket"
TICKET_LIB="$REPO_ROOT/plugins/dso/scripts/ticket-lib.sh"

source "$REPO_ROOT/tests/lib/assert.sh"
source "$REPO_ROOT/tests/lib/git-fixtures.sh"

echo "=== test-ticket-lib.sh ==="

# ── Helper: create a fresh temp git repo ─────────────────────────────────────
_make_test_repo() {
    local tmp
    tmp=$(mktemp -d)
    _CLEANUP_DIRS+=("$tmp")
    clone_test_repo "$tmp/repo"
    echo "$tmp/repo"
}

# ── Helper: build a minimal event JSON file ──────────────────────────────────
# Usage: _make_event_json <dest_path> <ticket_id>
_make_event_json() {
    local dest="$1"
    local ticket_id="$2"
    local ts
    ts=$(python3 -c "import time; print(int(time.time()))")
    local uuid
    uuid=$(python3 -c "import uuid; print(uuid.uuid4())")
    python3 -c "
import json, sys
data = {
    'timestamp': $ts,
    'uuid': '$uuid',
    'event_type': 'CREATE',
    'env_id': '$uuid',
    'author': 'Test',
    'data': {
        'ticket_type': 'task',
        'title': 'Test ticket',
        'parent_id': None
    }
}
json.dump(data, sys.stdout)
" > "$dest"
}

# ── Test 1: write_commit_event writes atomic file with correct naming ─────────
echo "Test 1: write_commit_event writes atomic event file with correct naming convention"
test_write_commit_event_writes_atomic_file() {
    local repo
    repo=$(_make_test_repo)

    # Initialize ticket system
    (cd "$repo" && bash "$TICKET_SCRIPT" init 2>/dev/null) || true

    # ticket-lib.sh must exist for sourcing — RED: it does not exist yet
    if [ ! -f "$TICKET_LIB" ]; then
        assert_eq "ticket-lib.sh exists" "exists" "missing"
        return
    fi

    local ticket_id="test-abc1"
    local tmpdir
    tmpdir=$(mktemp -d)
    _CLEANUP_DIRS+=("$tmpdir")
    local event_json="$tmpdir/event.json"
    _make_event_json "$event_json" "$ticket_id"

    # Source the lib and call write_commit_event
    (cd "$repo" && source "$TICKET_LIB" && write_commit_event "$ticket_id" "$event_json") || true

    # Assert: ticket directory exists
    if [ -d "$repo/.tickets-tracker/$ticket_id" ]; then
        assert_eq "event file dir exists" "exists" "exists"
    else
        assert_eq "event file dir exists" "exists" "missing"
        return
    fi

    # Assert: exactly one event file exists matching <timestamp>-<uuid>-CREATE.json
    local event_files
    event_files=$(find "$repo/.tickets-tracker/$ticket_id" -maxdepth 1 \
        -name '*-CREATE.json' ! -name '.*' 2>/dev/null | wc -l | tr -d ' ')
    assert_eq "event file count is 1" "1" "$event_files"

    # Assert: no partial/temp files remain (no files starting with '.')
    local temp_files
    temp_files=$(find "$repo/.tickets-tracker/$ticket_id" -maxdepth 1 \
        -name '.*' 2>/dev/null | wc -l | tr -d ' ')
    assert_eq "no temp files remain" "0" "$temp_files"

    # Assert: the event JSON is valid (parseable)
    local event_file
    event_file=$(find "$repo/.tickets-tracker/$ticket_id" -maxdepth 1 \
        -name '*-CREATE.json' ! -name '.*' 2>/dev/null | head -1)
    if [ -n "$event_file" ]; then
        local parse_exit=0
        python3 -c "import json,sys; json.load(sys.stdin)" < "$event_file" 2>/dev/null || parse_exit=$?
        assert_eq "event JSON is valid" "0" "$parse_exit"
    else
        assert_eq "event file found for JSON validation" "found" "not-found"
    fi
}
test_write_commit_event_writes_atomic_file

# ── Test 2: write_commit_event uses flock ─────────────────────────────────────
echo "Test 2: write_commit_event uses flock — lock file created at expected path"
test_write_commit_event_uses_flock() {
    local repo
    repo=$(_make_test_repo)

    # Initialize ticket system
    (cd "$repo" && bash "$TICKET_SCRIPT" init 2>/dev/null) || true

    # ticket-lib.sh must exist — RED: it does not exist yet
    if [ ! -f "$TICKET_LIB" ]; then
        assert_eq "ticket-lib.sh exists for flock test" "exists" "missing"
        return
    fi

    # Assert: the lock file path is defined in ticket-lib.sh
    local lock_path=".tickets-tracker/.ticket-write.lock"
    local lock_defined
    lock_defined=$(grep -c '\.ticket-write\.lock' "$TICKET_LIB" 2>/dev/null || echo "0")
    assert_eq "lock file path defined in ticket-lib.sh" "1" "$([ "$lock_defined" -ge 1 ] && echo 1 || echo 0)"

    # Assert: ticket-lib.sh references flock
    local flock_used
    flock_used=$(grep -c 'flock' "$TICKET_LIB" 2>/dev/null || echo "0")
    assert_eq "flock referenced in ticket-lib.sh" "1" "$([ "$flock_used" -ge 1 ] && echo 1 || echo 0)"

    local ticket_id="test-flock1"
    local tmpdir
    tmpdir=$(mktemp -d)
    _CLEANUP_DIRS+=("$tmpdir")
    local event_json="$tmpdir/event.json"
    _make_event_json "$event_json" "$ticket_id"

    # After write_commit_event, lock file must not be held (released)
    (cd "$repo" && source "$TICKET_LIB" && write_commit_event "$ticket_id" "$event_json") || true

    # Assert: ticket-lib.sh invokes flock with the expected lock path
    local flock_with_lock_path
    flock_with_lock_path=$(grep -c "flock.*$lock_path\|$lock_path.*flock" "$TICKET_LIB" 2>/dev/null || echo "0")
    assert_eq "flock invoked with .tickets-tracker/.ticket-write.lock" \
        "1" "$([ "$flock_with_lock_path" -ge 1 ] && echo 1 || echo 0)"
}
test_write_commit_event_uses_flock

# ── Test 3: write_commit_event commits only the specific event file ────────────
echo "Test 3: write_commit_event commits only the specific event file (not git add -A)"
test_write_commit_event_commits_specific_file() {
    local repo
    repo=$(_make_test_repo)

    # Initialize ticket system
    (cd "$repo" && bash "$TICKET_SCRIPT" init 2>/dev/null) || true

    # ticket-lib.sh must exist — RED: it does not exist yet
    if [ ! -f "$TICKET_LIB" ]; then
        assert_eq "ticket-lib.sh exists for commit test" "exists" "missing"
        return
    fi

    local ticket_id="test-commit1"
    local tmpdir
    tmpdir=$(mktemp -d)
    _CLEANUP_DIRS+=("$tmpdir")
    local event_json="$tmpdir/event.json"
    _make_event_json "$event_json" "$ticket_id"

    # Create an untracked distractor file in .tickets-tracker that should NOT be committed
    mkdir -p "$repo/.tickets-tracker/unrelated-dir"
    echo "should not be committed" > "$repo/.tickets-tracker/unrelated-dir/stray.txt"

    (cd "$repo" && source "$TICKET_LIB" && write_commit_event "$ticket_id" "$event_json") || true

    # Assert: git log shows a commit was made
    local commit_count
    commit_count=$(git -C "$repo/.tickets-tracker" log --oneline 2>/dev/null | wc -l | tr -d ' ')
    # Should have at least 2 commits (init + event commit)
    assert_eq "at least one event commit exists" "1" "$([ "$commit_count" -ge 2 ] && echo 1 || echo 0)"

    # Assert: the last commit contains only the specific event file (not stray.txt)
    local committed_files
    committed_files=$(git -C "$repo/.tickets-tracker" log --name-only --pretty=format: -1 2>/dev/null \
        | grep -v '^$' | tr -d ' ')

    # stray.txt must NOT be in the committed files
    if echo "$committed_files" | grep -q 'stray.txt'; then
        assert_eq "stray file not committed" "not-committed" "committed"
    else
        assert_eq "stray file not committed" "not-committed" "not-committed"
    fi

    # The event file for our ticket_id must be in the committed files
    if echo "$committed_files" | grep -q "$ticket_id"; then
        assert_eq "event file for ticket committed" "committed" "committed"
    else
        assert_eq "event file for ticket committed" "committed" "not-committed"
    fi
}
test_write_commit_event_commits_specific_file

# ── Test 4: write_commit_event sets gc.auto=0 in the tickets worktree ─────────
echo "Test 4: write_commit_event — gc.auto=0 is set in the tickets worktree"
test_write_commit_event_sets_gc_auto_zero() {
    local repo
    repo=$(_make_test_repo)

    # Initialize ticket system (ticket-init.sh sets gc.auto=0, but we verify
    # ticket-lib.sh also ensures it or relies on init's guarantee)
    (cd "$repo" && bash "$TICKET_SCRIPT" init 2>/dev/null) || true

    # ticket-lib.sh must exist — RED: it does not exist yet
    if [ ! -f "$TICKET_LIB" ]; then
        assert_eq "ticket-lib.sh exists for gc.auto test" "exists" "missing"
        return
    fi

    local ticket_id="test-gc1"
    local tmpdir
    tmpdir=$(mktemp -d)
    _CLEANUP_DIRS+=("$tmpdir")
    local event_json="$tmpdir/event.json"
    _make_event_json "$event_json" "$ticket_id"

    (cd "$repo" && source "$TICKET_LIB" && write_commit_event "$ticket_id" "$event_json") || true

    # Assert: gc.auto is 0 in the tickets worktree
    local gc_auto
    gc_auto="$(git -C "$repo/.tickets-tracker" config gc.auto 2>/dev/null || echo "unset")"
    assert_eq "gc.auto=0 in tickets worktree" "0" "$gc_auto"
}
test_write_commit_event_sets_gc_auto_zero

# ── Test 5: write_commit_event fails cleanly without prior ticket init ─────────
echo "Test 5: write_commit_event exits non-zero with error when ticket init not run"
test_write_commit_event_fails_cleanly_if_no_init() {
    local repo
    repo=$(_make_test_repo)

    # Do NOT run ticket init — .tickets-tracker should not exist

    # ticket-lib.sh must exist — RED: it does not exist yet
    if [ ! -f "$TICKET_LIB" ]; then
        assert_eq "ticket-lib.sh exists for no-init test" "exists" "missing"
        return
    fi

    local ticket_id="test-noinit1"
    local tmpdir
    tmpdir=$(mktemp -d)
    _CLEANUP_DIRS+=("$tmpdir")
    local event_json="$tmpdir/event.json"
    _make_event_json "$event_json" "$ticket_id"

    # Source ticket-lib.sh first — fail fast if source itself fails (separate from the tested call)
    # Run write_commit_event without init — must exit non-zero
    local exit_code=0
    local stderr_out
    # shellcheck source=/dev/null
    if ! (cd "$repo" && source "$TICKET_LIB") 2>/dev/null; then
        assert_eq "ticket-lib.sh sources without error" "ok" "source-failed"
        return
    fi
    stderr_out=$(cd "$repo" && source "$TICKET_LIB" && \
        write_commit_event "$ticket_id" "$event_json" 2>&1) || exit_code=$?

    assert_eq "exits non-zero without init" "1" "$([ "$exit_code" -ne 0 ] && echo 1 || echo 0)"

    # Assert: stderr contains an error message (not silent failure)
    if [ -n "$stderr_out" ]; then
        assert_eq "error message printed on no-init" "has-message" "has-message"
    else
        assert_eq "error message printed on no-init" "has-message" "silent"
    fi
}
test_write_commit_event_fails_cleanly_if_no_init

print_summary
