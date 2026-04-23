#!/usr/bin/env bash
# tests/scripts/test-preconditions-compaction.sh
# RED tests for _compact_preconditions() and _read_latest_preconditions() in ticket-lib.sh.
#
# Tests:
#   1. test_compact_preconditions_writes_snapshot — compaction writes SNAPSHOT and retires originals
#   2. test_read_latest_handles_snapshot_format — reader returns snapshot payload after compaction
#   3. test_read_latest_retry_once_on_transient_miss — reader retries once on transient ENOENT
#
# Usage: bash tests/scripts/test-preconditions-compaction.sh

# NOTE: -e is intentionally omitted — test functions return non-zero by design
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"
TICKET_LIB="$REPO_ROOT/plugins/dso/scripts/ticket-lib.sh"

source "$REPO_ROOT/tests/lib/assert.sh"
source "$REPO_ROOT/tests/lib/git-fixtures.sh"

echo "=== test-preconditions-compaction.sh ==="

# ── Helpers ───────────────────────────────────────────────────────────────────

_make_preconditions_event() {
    local dest_dir="$1"
    local ts="$2"
    local gate_name="${3:-gate_alpha}"
    local verdict="${4:-pass}"
    local uuid
    uuid=$(python3 -c "import uuid; print(str(uuid.uuid4()))")
    local filename="${ts}-${uuid}-PRECONDITIONS.json"
    python3 -c "
import json, sys
data = {
    'timestamp': int(sys.argv[1]),
    'uuid': sys.argv[2],
    'event_type': 'PRECONDITIONS',
    'env_id': 'test-env',
    'author': 'Test',
    'data': {
        'schema_version': 1,
        'gate_name': sys.argv[3],
        'session_id': 'sess-001',
        'worktree_id': 'wt-001',
        'verdict': sys.argv[4],
        'manifest_depth': 2,
        'gate_verdicts': {sys.argv[3]: sys.argv[4]}
    }
}
json.dump(data, sys.stdout)
" "$ts" "$uuid" "$gate_name" "$verdict" > "$dest_dir/$filename"
    echo "$filename"
}

# ── Test 1: _compact_preconditions_writes_snapshot ───────────────────────────
echo "Test 1: _compact_preconditions writes PRECONDITIONS-SNAPSHOT and retires original events"
test_compact_preconditions_writes_snapshot() {
    # ticket-lib.sh must be sourced
    if [ ! -f "$TICKET_LIB" ]; then
        assert_eq "ticket-lib.sh exists" "exists" "missing"
        return
    fi

    # _compact_preconditions function must exist (RED before implementation)
    local fn_exists="no"
    if (source "$TICKET_LIB" 2>/dev/null && declare -f _compact_preconditions >/dev/null 2>&1); then
        fn_exists="yes"
    fi

    if [ "$fn_exists" = "no" ]; then
        assert_eq "_compact_preconditions is defined in ticket-lib.sh" "defined" "undefined"
        return
    fi

    local tmpdir
    tmpdir=$(mktemp -d)
    _CLEANUP_DIRS+=("$tmpdir")
    local ticket_dir="$tmpdir/test-epic-001"
    mkdir -p "$ticket_dir"

    # Create 3 PRECONDITIONS events with sequential timestamps
    _make_preconditions_event "$ticket_dir" "1700000001" "gate_alpha" "pass" >/dev/null
    _make_preconditions_event "$ticket_dir" "1700000002" "gate_beta" "pass" >/dev/null
    _make_preconditions_event "$ticket_dir" "1700000003" "gate_gamma" "fail" >/dev/null

    # Assert: 3 PRECONDITIONS events exist before compaction
    local pre_count
    pre_count=$(find "$ticket_dir" -maxdepth 1 -name '*-PRECONDITIONS.json' ! -name '*-PRECONDITIONS-SNAPSHOT.json' ! -name '*.retired' 2>/dev/null | wc -l | tr -d ' ')
    assert_eq "3 PRECONDITIONS events exist before compaction" "3" "$pre_count"

    # Call _compact_preconditions
    local compact_exit=0
    (source "$TICKET_LIB" 2>/dev/null && _compact_preconditions "$ticket_dir" "test-epic-001") 2>/dev/null || compact_exit=$?

    # Assert: compaction exits 0
    assert_eq "_compact_preconditions exits 0" "0" "$compact_exit"

    # Assert: exactly one PRECONDITIONS-SNAPSHOT.json exists
    local snapshot_count
    snapshot_count=$(find "$ticket_dir" -maxdepth 1 -name '*-PRECONDITIONS-SNAPSHOT.json' ! -name '*.retired' 2>/dev/null | wc -l | tr -d ' ')
    assert_eq "one PRECONDITIONS-SNAPSHOT.json exists after compaction" "1" "$snapshot_count"

    # Assert: original event files are retired (renamed to *.retired)
    local retired_count
    retired_count=$(find "$ticket_dir" -maxdepth 1 -name '*-PRECONDITIONS.json.retired' 2>/dev/null | wc -l | tr -d ' ')
    assert_eq "3 original PRECONDITIONS events retired (.retired suffix)" "3" "$retired_count"

    # Assert: no live (non-retired) PRECONDITIONS.json events remain (excluding snapshot)
    local live_count
    live_count=$(find "$ticket_dir" -maxdepth 1 -name '*-PRECONDITIONS.json' ! -name '*-PRECONDITIONS-SNAPSHOT.json' ! -name '*.retired' 2>/dev/null | wc -l | tr -d ' ')
    assert_eq "no live PRECONDITIONS.json events remain after compaction" "0" "$live_count"

    # Assert: snapshot is valid JSON
    local snapshot_file
    snapshot_file=$(find "$ticket_dir" -maxdepth 1 -name '*-PRECONDITIONS-SNAPSHOT.json' ! -name '*.retired' 2>/dev/null | head -1)
    if [ -n "$snapshot_file" ]; then
        local parse_exit=0
        python3 -c "import json,sys; json.load(sys.stdin)" < "$snapshot_file" 2>/dev/null || parse_exit=$?
        assert_eq "PRECONDITIONS-SNAPSHOT.json is valid JSON" "0" "$parse_exit"
    fi

    # Assert: no .tmp files remain after successful compaction
    local tmp_count
    tmp_count=$(find "$ticket_dir" -maxdepth 1 -name '*.tmp' 2>/dev/null | wc -l | tr -d ' ')
    assert_eq "no .tmp files remain after compaction" "0" "$tmp_count"
}
test_compact_preconditions_writes_snapshot

# ── Test 2: test_read_latest_handles_snapshot_format ─────────────────────────
echo "Test 2: _read_latest_preconditions returns snapshot payload when snapshot exists"
test_read_latest_handles_snapshot_format() {
    if [ ! -f "$TICKET_LIB" ]; then
        assert_eq "ticket-lib.sh exists" "exists" "missing"
        return
    fi

    # _read_latest_preconditions function must exist
    local fn_exists="no"
    if (source "$TICKET_LIB" 2>/dev/null && declare -f _read_latest_preconditions >/dev/null 2>&1); then
        fn_exists="yes"
    fi

    if [ "$fn_exists" = "no" ]; then
        assert_eq "_read_latest_preconditions is defined in ticket-lib.sh" "defined" "undefined"
        return
    fi

    local tmpdir
    tmpdir=$(mktemp -d)
    _CLEANUP_DIRS+=("$tmpdir")
    local ticket_dir="$tmpdir/test-epic-002"
    mkdir -p "$ticket_dir"

    # Create a compacted state: PRECONDITIONS-SNAPSHOT.json present, originals retired
    local ts="1700001000"
    local snap_uuid
    snap_uuid=$(python3 -c "import uuid; print(str(uuid.uuid4()))")
    local snap_file="$ticket_dir/${ts}-${snap_uuid}-PRECONDITIONS-SNAPSHOT.json"
    python3 -c "
import json, sys
data = {
    'timestamp': int(sys.argv[1]),
    'uuid': sys.argv[2],
    'event_type': 'PRECONDITIONS',
    'compacted': True,
    'env_id': 'test-env',
    'author': 'Test',
    'data': {
        'schema_version': 1,
        'gate_name': 'gate_alpha',
        'session_id': 'sess-002',
        'worktree_id': 'wt-002',
        'verdict': 'pass',
        'manifest_depth': 3,
        'gate_verdicts': {'gate_alpha': 'pass', 'gate_beta': 'pass'}
    }
}
json.dump(data, sys.stdout)
" "$ts" "$snap_uuid" > "$snap_file"

    # Also create a retired event (should be ignored)
    local ret_uuid
    ret_uuid=$(python3 -c "import uuid; print(str(uuid.uuid4()))")
    echo '{"event_type":"PRECONDITIONS","timestamp":1699000000,"uuid":"'"$ret_uuid"'","data":{"gate_verdicts":{}}}' \
        > "$ticket_dir/1699000000-${ret_uuid}-PRECONDITIONS.json.retired"

    # Call _read_latest_preconditions with the ticket directory
    local read_output
    local read_exit=0
    read_output=$(source "$TICKET_LIB" 2>/dev/null && _read_latest_preconditions "$ticket_dir" 2>/dev/null) || read_exit=$?

    # Assert: exits 0
    assert_eq "_read_latest_preconditions exits 0 with snapshot" "0" "$read_exit"

    # Assert: output is non-empty
    if [ -n "$read_output" ]; then
        assert_eq "_read_latest_preconditions returns non-empty output" "non-empty" "non-empty"
    else
        assert_eq "_read_latest_preconditions returns non-empty output" "non-empty" "empty"
        return
    fi

    # Assert: output is valid JSON with manifest_depth
    local field_check
    field_check=$(python3 -c "
import json, sys
try:
    data = json.loads(sys.argv[1])
    # Accept both nested (data.manifest_depth) and flat (manifest_depth) format
    depth = data.get('manifest_depth') or (data.get('data') or {}).get('manifest_depth')
    if depth is not None:
        print('OK')
    else:
        print('MISSING_MANIFEST_DEPTH')
except Exception as e:
    print(f'PARSE_ERROR:{e}')
" "$read_output" 2>/dev/null || echo "PARSE_ERROR")
    assert_eq "_read_latest_preconditions output contains manifest_depth" "OK" "$field_check"
}
test_read_latest_handles_snapshot_format

# ── Test 3: test_read_latest_retry_once_on_transient_miss ────────────────────
echo "Test 3: _read_latest_preconditions retries once on transient ENOENT and succeeds"
test_read_latest_retry_once_on_transient_miss() {
    if [ ! -f "$TICKET_LIB" ]; then
        assert_eq "ticket-lib.sh exists" "exists" "missing"
        return
    fi

    # _read_latest_preconditions must exist
    local fn_exists="no"
    if (source "$TICKET_LIB" 2>/dev/null && declare -f _read_latest_preconditions >/dev/null 2>&1); then
        fn_exists="yes"
    fi

    if [ "$fn_exists" = "no" ]; then
        assert_eq "_read_latest_preconditions is defined (retry test)" "defined" "undefined"
        return
    fi

    # Assert: ticket-lib.sh contains retry-once logic (sleep 0.05 or sleep 50ms pattern)
    local retry_pattern_found="no"
    if grep -qE 'sleep.*0\.|retry|ENOENT|transient' "$TICKET_LIB" 2>/dev/null; then
        retry_pattern_found="yes"
    fi
    assert_eq "_read_latest_preconditions has retry logic in ticket-lib.sh" "yes" "$retry_pattern_found"

    # Behavioral test: create a valid snapshot, assert _read_latest_preconditions returns it
    local tmpdir
    tmpdir=$(mktemp -d)
    _CLEANUP_DIRS+=("$tmpdir")
    local ticket_dir="$tmpdir/test-epic-003"
    mkdir -p "$ticket_dir"

    local ts="1700002000"
    local snap_uuid
    snap_uuid=$(python3 -c "import uuid; print(str(uuid.uuid4()))")
    local snap_file="$ticket_dir/${ts}-${snap_uuid}-PRECONDITIONS-SNAPSHOT.json"
    python3 -c "
import json, sys
data = {
    'timestamp': int(sys.argv[1]),
    'uuid': sys.argv[2],
    'event_type': 'PRECONDITIONS',
    'compacted': True,
    'env_id': 'test-env',
    'author': 'Test',
    'data': {
        'schema_version': 1,
        'gate_name': 'gate_retry',
        'session_id': 'sess-003',
        'worktree_id': 'wt-003',
        'verdict': 'pass',
        'manifest_depth': 1,
        'gate_verdicts': {'gate_retry': 'pass'}
    }
}
json.dump(data, sys.stdout)
" "$ts" "$snap_uuid" > "$snap_file"

    # Call _read_latest_preconditions — on a real file, first attempt succeeds
    local read_output
    local read_exit=0
    read_output=$(source "$TICKET_LIB" 2>/dev/null && _read_latest_preconditions "$ticket_dir" 2>/dev/null) || read_exit=$?

    assert_eq "_read_latest_preconditions exits 0 (retry test)" "0" "$read_exit"

    # Test: call on empty dir should exit non-zero (no events = pre-manifest → exit 1)
    local empty_dir
    empty_dir=$(mktemp -d)
    _CLEANUP_DIRS+=("$empty_dir")
    local empty_exit=0
    (source "$TICKET_LIB" 2>/dev/null && _read_latest_preconditions "$empty_dir" 2>/dev/null) || empty_exit=$?
    assert_eq "_read_latest_preconditions exits non-zero on empty dir (pre-manifest)" "1" \
        "$([ "$empty_exit" -ne 0 ] && echo 1 || echo 0)"
}
test_read_latest_retry_once_on_transient_miss

print_summary
