#!/usr/bin/env bash
# tests/scripts/test-compact-sync-precondition.sh
# RED tests for sync-before-compact precondition in ticket-compact.sh.
#
# Asserts that ticket-compact.sh calls ticket sync before compacting when sync
# is available, skips tickets with remote SNAPSHOTs, aborts on sync failure,
# and proceeds normally when no remote SNAPSHOT exists.
#
# Tests MUST FAIL (RED) until ticket-compact.sh implements sync-before-compact.
#
# Usage: bash tests/scripts/test-compact-sync-precondition.sh
# Returns: exit non-zero (RED) until sync-before-compact is implemented.

# NOTE: -e is intentionally omitted — test functions return non-zero by design.
# -e would abort the runner on expected assertion mismatches.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"
TICKET_SCRIPT="$REPO_ROOT/plugins/dso/scripts/ticket"
COMPACT_SCRIPT="$REPO_ROOT/plugins/dso/scripts/ticket-compact.sh"

source "$REPO_ROOT/tests/lib/assert.sh"
source "$REPO_ROOT/tests/lib/git-fixtures.sh"

echo "=== test-compact-sync-precondition.sh ==="

# ── Suite-runner guard: skip when sync-before-compact is not yet implemented ──
# ticket-compact.sh exists but does NOT yet call sync. When auto-discovered by
# run-script-tests.sh, these RED tests would break `bash tests/run-all.sh`.
# Skip with exit 0 when running under the suite runner AND the feature is absent
# (detected by the absence of a sync invocation inside ticket-compact.sh).
_sync_implemented() {
    grep -q 'ticket.*sync\|sync.*subcommand\|TICKET_SYNC_CMD\|ticket-sync' "$COMPACT_SCRIPT" 2>/dev/null
}

if [ "${_RUN_ALL_ACTIVE:-0}" = "1" ] && ! _sync_implemented; then
    echo "SKIP: sync-before-compact not yet implemented (RED) — tests deferred"
    echo ""
    printf "PASSED: 0  FAILED: 0\n"
    exit 0
fi

# ── Helper: create a fresh temp git repo with ticket system initialized ────────
_make_test_repo() {
    local tmp
    tmp=$(mktemp -d)
    _CLEANUP_DIRS+=("$tmp")
    clone_test_repo "$tmp/repo"
    (cd "$tmp/repo" && bash "$TICKET_SCRIPT" init >/dev/null 2>/dev/null) || true
    echo "$tmp/repo"
}

# ── Helper: write an event file to a ticket dir ───────────────────────────────
# Usage: _write_event <ticket_dir> <timestamp> <uuid> <event_type> <data_json>
_write_event() {
    local ticket_dir="$1"
    local timestamp="$2"
    local uuid="$3"
    local event_type="$4"
    local data_json="$5"
    local env_id="${6:-00000000-0000-4000-8000-000000000001}"
    local author="${7:-Test User}"
    local filename="${timestamp}-${uuid}-${event_type}.json"

    python3 -c "
import json, sys
payload = {
    'timestamp': $timestamp,
    'uuid': '$uuid',
    'event_type': '$event_type',
    'env_id': '$env_id',
    'author': '$author',
    'data': json.loads('''$data_json''')
}
json.dump(payload, sys.stdout)
" > "$ticket_dir/$filename"
}

# ── Helper: create a ticket with N events (1 CREATE + N-1 STATUS) ─────────────
# Usage: _create_ticket_with_events <repo> <ticket_id> <event_count>
# Returns the ticket dir path via stdout.
_create_ticket_with_events() {
    local repo="$1"
    local ticket_id="$2"
    local event_count="$3"
    local ticket_dir="$repo/.tickets-tracker/$ticket_id"
    mkdir -p "$ticket_dir"

    local create_uuid="00000000-0000-4000-8000-create000001"
    _write_event "$ticket_dir" "1742605200" "$create_uuid" "CREATE" \
        '{"ticket_type": "task", "title": "Sync precondition test ticket", "parent_id": null}'

    local i
    for (( i=1; i<event_count; i++ )); do
        local ts=$((1742605200 + i * 100))
        local uuid
        uuid=$(printf "00000000-0000-4000-8000-%012d" "$i")
        _write_event "$ticket_dir" "$ts" "$uuid" "STATUS" \
            '{"status": "in_progress", "current_status": "open"}'
    done

    echo "$ticket_dir"
}

# ── Helper: create a fake 'ticket' shim that records calls ────────────────────
# The shim is placed in a temp bin dir added to PATH. It logs each invocation to
# a call-log file and exits 0 by default.
# Usage: _install_sync_shim <bin_dir> <call_log> [sync_exit_code]
_install_sync_shim() {
    local bin_dir="$1"
    local call_log="$2"
    local sync_exit="${3:-0}"

    mkdir -p "$bin_dir"

    # Write a 'ticket' shim that intercepts the 'sync' subcommand
    cat > "$bin_dir/ticket" << SHIM_EOF
#!/usr/bin/env bash
# Shim: log calls and control sync exit code for testing
echo "\$@" >> "$call_log"
if [ "\$1" = "sync" ]; then
    exit $sync_exit
fi
# For all other subcommands, delegate to the real script
exec bash "$TICKET_SCRIPT" "\$@"
SHIM_EOF
    chmod +x "$bin_dir/ticket"
}

# ── Test 1: compact calls sync before compacting ──────────────────────────────
echo "Test 1: test_compact_calls_sync_before_compacting"
test_compact_calls_sync_before_compacting() {
    _snapshot_fail

    local repo
    repo=$(_make_test_repo)
    local ticket_id="tkt-sync-call"
    _create_ticket_with_events "$repo" "$ticket_id" 12

    # Set up shim to intercept and log ticket sync invocations
    local bin_dir
    bin_dir=$(mktemp -d)
    _CLEANUP_DIRS+=("$bin_dir")
    local call_log
    call_log=$(mktemp)
    _CLEANUP_DIRS+=("$call_log")
    _install_sync_shim "$bin_dir" "$call_log" 0

    # Run compaction with the shim on PATH and TICKET_SYNC_CMD override
    # ticket-compact.sh is expected to honour TICKET_SYNC_CMD when set, or
    # call "ticket sync" via the PATH shim.
    local snapshot_before_sync=""
    local ticket_dir="$repo/.tickets-tracker/$ticket_id"

    (
        export PATH="$bin_dir:$PATH"
        export TICKET_SYNC_CMD="$bin_dir/ticket sync"
        cd "$repo"
        COMPACT_THRESHOLD=5 bash "$COMPACT_SCRIPT" "$ticket_id"
    ) 2>/dev/null || true

    # Assert: sync was called (call_log contains a "sync" entry)
    local sync_called
    if grep -q '^sync' "$call_log" 2>/dev/null; then
        sync_called="yes"
    else
        sync_called="no"
    fi
    assert_eq "sync was called during compact" "yes" "$sync_called"

    # Assert: sync was called BEFORE any SNAPSHOT was written
    # Strategy: install a shim that records the timestamp when sync is called,
    # then verify the SNAPSHOT file timestamp is >= the sync call timestamp.
    # Here we verify via call log ordering: sync log entry must precede SNAPSHOT.
    local snapshot_file
    snapshot_file=$(find "$ticket_dir" -maxdepth 1 -name '*-SNAPSHOT.json' 2>/dev/null | head -1)
    if [ -n "$snapshot_file" ]; then
        local snapshot_mtime
        if [[ "$(uname)" == "Darwin" ]]; then
            snapshot_mtime=$(stat -f '%m' "$snapshot_file" 2>/dev/null || echo "0")
        else
            snapshot_mtime=$(stat -c '%Y' "$snapshot_file" 2>/dev/null || echo "0")
        fi
        local sync_log_mtime
        if [[ "$(uname)" == "Darwin" ]]; then
            sync_log_mtime=$(stat -f '%m' "$call_log" 2>/dev/null || echo "0")
        else
            sync_log_mtime=$(stat -c '%Y' "$call_log" 2>/dev/null || echo "0")
        fi
        # call_log was written DURING sync (before SNAPSHOT creation).
        # If sync ran first, call_log mtime <= snapshot mtime.
        assert_eq "sync logged before SNAPSHOT creation" "ordered" \
            "$([ "$sync_log_mtime" -le "$snapshot_mtime" ] && echo ordered || echo unordered)"
    else
        # SNAPSHOT not found — compact did not proceed, which is also a failure
        assert_eq "SNAPSHOT written after sync" "created" "missing"
    fi

    assert_pass_if_clean "test_compact_calls_sync_before_compacting"
}
test_compact_calls_sync_before_compacting

# ── Test 2: compact skips ticket with remote SNAPSHOT ─────────────────────────
echo "Test 2: test_compact_skips_ticket_with_remote_snapshot"
test_compact_skips_ticket_with_remote_snapshot() {
    _snapshot_fail

    local repo
    repo=$(_make_test_repo)
    local ticket_id="tkt-remote-snap"
    local ticket_dir
    ticket_dir=$(_create_ticket_with_events "$repo" "$ticket_id" 12)

    # Simulate a remote SNAPSHOT: write a SNAPSHOT file into the ticket dir
    # that would be detected as coming from a remote environment (different env_id).
    local remote_snap_ts=1742605100
    local remote_snap_uuid="aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
    local remote_env_id="99999999-9999-4000-8000-999999999999"
    local remote_snap_file="$ticket_dir/${remote_snap_ts}-${remote_snap_uuid}-SNAPSHOT.json"

    python3 -c "
import json, sys
payload = {
    'event_type': 'SNAPSHOT',
    'timestamp': $remote_snap_ts,
    'uuid': '$remote_snap_uuid',
    'env_id': '$remote_env_id',
    'author': 'remote-agent',
    'data': {
        'compiled_state': {'title': 'Remote snapshot ticket', 'status': 'open', 'ticket_type': 'task'},
        'source_event_uuids': ['src-uuid-1'],
        'compacted_at': $remote_snap_ts,
    }
}
json.dump(payload, sys.stdout)
" > "$remote_snap_file"

    # Count files before attempted compaction
    local before_count
    before_count=$(find "$ticket_dir" -maxdepth 1 -name '*.json' ! -name '.*' 2>/dev/null | wc -l | tr -d ' ')

    # Run compaction (sync shim exits 0 — not blocking, just checking skip logic)
    local bin_dir
    bin_dir=$(mktemp -d)
    _CLEANUP_DIRS+=("$bin_dir")
    local call_log
    call_log=$(mktemp)
    _CLEANUP_DIRS+=("$call_log")
    _install_sync_shim "$bin_dir" "$call_log" 0

    local compact_output
    compact_output=$(
        export PATH="$bin_dir:$PATH"
        export TICKET_SYNC_CMD="$bin_dir/ticket sync"
        cd "$repo"
        COMPACT_THRESHOLD=5 bash "$COMPACT_SCRIPT" "$ticket_id" 2>&1
    ) || true

    # Assert: compact exits 0 (graceful skip)
    local compact_exit=0
    (
        export PATH="$bin_dir:$PATH"
        export TICKET_SYNC_CMD="$bin_dir/ticket sync"
        cd "$repo"
        COMPACT_THRESHOLD=5 bash "$COMPACT_SCRIPT" "$ticket_id"
    ) 2>/dev/null || compact_exit=$?
    assert_eq "compact exits 0 when remote SNAPSHOT present" "0" "$compact_exit"

    # Assert: output mentions skip
    if echo "$compact_output" | grep -qi 'skip\|remote.*snapshot\|snapshot.*remote\|already.*compacted'; then
        assert_eq "skip message for remote SNAPSHOT" "present" "present"
    else
        assert_eq "skip message for remote SNAPSHOT" "present" "missing"
    fi

    # Assert: no new local SNAPSHOT was written (the remote one is preserved,
    # but no additional SNAPSHOT beyond the injected remote one should exist)
    local new_snapshot_count
    new_snapshot_count=$(find "$ticket_dir" -maxdepth 1 -name '*-SNAPSHOT.json' ! -name "${remote_snap_ts}-*" 2>/dev/null | wc -l | tr -d ' ')
    assert_eq "no new SNAPSHOT written when remote SNAPSHOT present" "0" "$new_snapshot_count"

    assert_pass_if_clean "test_compact_skips_ticket_with_remote_snapshot"
}
test_compact_skips_ticket_with_remote_snapshot

# ── Test 3: sync failure aborts compact ───────────────────────────────────────
echo "Test 3: test_compact_sync_failure_aborts_compact"
test_compact_sync_failure_aborts_compact() {
    _snapshot_fail

    local repo
    repo=$(_make_test_repo)
    local ticket_id="tkt-sync-fail"
    local ticket_dir
    ticket_dir=$(_create_ticket_with_events "$repo" "$ticket_id" 12)

    # Install sync shim that returns non-zero (simulates sync failure)
    local bin_dir
    bin_dir=$(mktemp -d)
    _CLEANUP_DIRS+=("$bin_dir")
    local call_log
    call_log=$(mktemp)
    _CLEANUP_DIRS+=("$call_log")
    _install_sync_shim "$bin_dir" "$call_log" 1  # exit 1 = sync failure

    # Run compaction — should abort due to sync failure
    local compact_exit=0
    (
        export PATH="$bin_dir:$PATH"
        export TICKET_SYNC_CMD="$bin_dir/ticket sync"
        cd "$repo"
        COMPACT_THRESHOLD=5 bash "$COMPACT_SCRIPT" "$ticket_id"
    ) 2>/dev/null || compact_exit=$?

    # Assert: compact exits non-zero (aborted)
    assert_ne "compact aborts with non-zero exit on sync failure" "0" "$compact_exit"

    # Assert: no SNAPSHOT was written (compact did not proceed)
    local snapshot_count
    snapshot_count=$(find "$ticket_dir" -maxdepth 1 -name '*-SNAPSHOT.json' 2>/dev/null | wc -l | tr -d ' ')
    assert_eq "no SNAPSHOT written when sync fails" "0" "$snapshot_count"

    assert_pass_if_clean "test_compact_sync_failure_aborts_compact"
}
test_compact_sync_failure_aborts_compact

# ── Test 4: compact proceeds normally when no remote SNAPSHOT exists ──────────
echo "Test 4: test_compact_proceeds_if_no_remote_snapshot"
test_compact_proceeds_if_no_remote_snapshot() {
    _snapshot_fail

    local repo
    repo=$(_make_test_repo)
    local ticket_id="tkt-no-remote"
    local ticket_dir
    ticket_dir=$(_create_ticket_with_events "$repo" "$ticket_id" 12)

    # Install sync shim that exits 0 — no remote SNAPSHOT injected
    local bin_dir
    bin_dir=$(mktemp -d)
    _CLEANUP_DIRS+=("$bin_dir")
    local call_log
    call_log=$(mktemp)
    _CLEANUP_DIRS+=("$call_log")
    _install_sync_shim "$bin_dir" "$call_log" 0

    # Run compaction
    local compact_exit=0
    (
        export PATH="$bin_dir:$PATH"
        export TICKET_SYNC_CMD="$bin_dir/ticket sync"
        cd "$repo"
        COMPACT_THRESHOLD=5 bash "$COMPACT_SCRIPT" "$ticket_id"
    ) 2>/dev/null || compact_exit=$?

    # Assert: compact exits 0
    assert_eq "compact exits 0 when no remote SNAPSHOT" "0" "$compact_exit"

    # Assert: SNAPSHOT was created (compaction proceeded)
    local snapshot_count
    snapshot_count=$(find "$ticket_dir" -maxdepth 1 -name '*-SNAPSHOT.json' 2>/dev/null | wc -l | tr -d ' ')
    assert_eq "SNAPSHOT written when no remote SNAPSHOT" "1" "$snapshot_count"

    # Assert: original event files removed
    local non_snapshot_count
    non_snapshot_count=$(find "$ticket_dir" -maxdepth 1 -name '*.json' ! -name '*-SNAPSHOT.json' ! -name '.*' 2>/dev/null | wc -l | tr -d ' ')
    assert_eq "original events removed after compact with sync" "0" "$non_snapshot_count"

    assert_pass_if_clean "test_compact_proceeds_if_no_remote_snapshot"
}
test_compact_proceeds_if_no_remote_snapshot

# ── Test 5: graceful behavior when sync subcommand is absent ──────────────────
# Covers the case where w21-6k7v (ticket sync) is not yet merged.
# compact should behave gracefully — either skip the sync step or proceed
# with a warning — rather than hard-failing with a command-not-found error.
echo "Test 5: test_compact_sync_subcommand_absent_graceful"
test_compact_sync_subcommand_absent_graceful() {
    _snapshot_fail

    local repo
    repo=$(_make_test_repo)
    local ticket_id="tkt-no-sync-subcmd"
    local ticket_dir
    ticket_dir=$(_create_ticket_with_events "$repo" "$ticket_id" 12)

    # Install a 'ticket' shim that returns exit 127 (command not found) for
    # the 'sync' subcommand, simulating a version of ticket without sync.
    local bin_dir
    bin_dir=$(mktemp -d)
    _CLEANUP_DIRS+=("$bin_dir")

    mkdir -p "$bin_dir"
    cat > "$bin_dir/ticket" << 'SHIM_EOF'
#!/usr/bin/env bash
# Shim: sync subcommand is absent (returns 127 = command not found)
if [ "$1" = "sync" ]; then
    echo "Error: unknown subcommand 'sync'" >&2
    exit 127
fi
# Delegate all other subcommands to the real script
exec bash "REAL_TICKET_SCRIPT" "$@"
SHIM_EOF
    # Replace placeholder with real path
    sed -i.bak "s|REAL_TICKET_SCRIPT|$TICKET_SCRIPT|g" "$bin_dir/ticket"
    rm -f "$bin_dir/ticket.bak"
    chmod +x "$bin_dir/ticket"

    # Run compaction — compact should not crash with command-not-found
    local compact_exit=0
    local compact_output=""
    compact_output=$(
        export PATH="$bin_dir:$PATH"
        export TICKET_SYNC_CMD="$bin_dir/ticket sync"
        cd "$repo"
        COMPACT_THRESHOLD=5 bash "$COMPACT_SCRIPT" "$ticket_id" 2>&1
    ) || compact_exit=$?

    # Assert: compact does NOT exit with 127 (command-not-found propagated)
    # Acceptable exits: 0 (proceeded without sync) or a documented skip exit.
    # The key invariant is: compact must handle the absent-sync case gracefully,
    # not abort with a raw 127 that gives no useful error message.
    assert_ne "compact does not exit 127 when sync subcommand absent" "127" "$compact_exit"

    # Assert: output contains a useful message about sync being unavailable
    # (not a raw shell "command not found" trace)
    if echo "$compact_output" | grep -qi \
        'sync.*absent\|no.*sync.*subcommand\|sync_subcommand_missing\|sync.*not.*available\|sync.*unavailable\|skip.*sync'; then
        assert_eq "graceful message when sync absent" "present" "present"
    else
        assert_eq "graceful message when sync absent" "present" "missing"
    fi

    assert_pass_if_clean "test_compact_sync_subcommand_absent_graceful"
}
test_compact_sync_subcommand_absent_graceful

print_summary
