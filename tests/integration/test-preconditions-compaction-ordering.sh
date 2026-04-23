#!/usr/bin/env bash
# tests/integration/test-preconditions-compaction-ordering.sh
# Integration tests for compaction ordering contract:
#   - Snapshot timestamp is >= all source event timestamps
#   - LWW: later timestamp wins per composite key (gate_name, session_id, worktree_id)
#   - Multiple sessions: distinct composite keys preserve all gate verdicts
#
# Tests:
#   1. test_snapshot_timestamp_gte_all_source_events — snapshot ts >= max source ts
#   2. test_lww_later_event_wins_per_composite_key — LWW within same composite key
#   3. test_multiple_sessions_preserve_all_gate_verdicts — distinct keys all present
#
# Usage: bash tests/integration/test-preconditions-compaction-ordering.sh

# NOTE: -e is intentionally omitted — test functions return non-zero by design
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"
TICKET_LIB="$REPO_ROOT/plugins/dso/scripts/ticket-lib.sh"

source "$REPO_ROOT/tests/lib/assert.sh"

echo "=== test-preconditions-compaction-ordering.sh ==="

# ── Helpers ───────────────────────────────────────────────────────────────────

_CLEANUP_DIRS=()
_cleanup() {
    for d in "${_CLEANUP_DIRS[@]:-}"; do
        rm -rf "$d" 2>/dev/null || true
    done
}
trap _cleanup EXIT

_make_preconditions_event() {
    local dest_dir="$1"
    local ts="$2"
    local gate_name="${3:-gate_alpha}"
    local verdict="${4:-pass}"
    local session_id="${5:-sess-001}"
    local worktree_id="${6:-wt-001}"
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
        'session_id': sys.argv[5],
        'worktree_id': sys.argv[6],
        'verdict': sys.argv[4],
        'manifest_depth': 2,
        'gate_verdicts': {sys.argv[3]: sys.argv[4]}
    }
}
json.dump(data, sys.stdout)
" "$ts" "$uuid" "$gate_name" "$verdict" "$session_id" "$worktree_id" > "$dest_dir/$filename"
    echo "$filename"
}

# ── Test 1: Snapshot timestamp >= all source event timestamps ─────────────────
echo "Test 1: snapshot timestamp is >= all source event timestamps"
test_snapshot_timestamp_gte_all_source_events() {
    _snapshot_fail
    if [ ! -f "$TICKET_LIB" ]; then
        assert_eq "ticket-lib.sh exists" "exists" "missing"
        return
    fi

    local fn_exists="no"
    if (source "$TICKET_LIB" 2>/dev/null && declare -f _compact_preconditions >/dev/null 2>&1); then
        fn_exists="yes"
    fi
    if [ "$fn_exists" = "no" ]; then
        assert_eq "_compact_preconditions exists" "yes" "no"
        return
    fi

    local tmpdir
    tmpdir=$(mktemp -d)
    _CLEANUP_DIRS+=("$tmpdir")
    local ticket_dir="$tmpdir/ordering-ticket-001"
    mkdir -p "$ticket_dir"

    # Create 3 events with known timestamps
    _make_preconditions_event "$ticket_dir" "1700000001" "gate_a" "pass" "sess-001" "wt-001" >/dev/null
    _make_preconditions_event "$ticket_dir" "1700000050" "gate_b" "pass" "sess-001" "wt-001" >/dev/null
    _make_preconditions_event "$ticket_dir" "1700000099" "gate_c" "pass" "sess-001" "wt-001" >/dev/null
    local max_source_ts=1700000099

    # Compact
    local compact_exit=0
    (source "$TICKET_LIB" 2>/dev/null && _compact_preconditions "$ticket_dir" "ordering-ticket-001") 2>/dev/null || compact_exit=$?
    assert_eq "compaction exits 0" "0" "$compact_exit"

    # Read the snapshot file and check its timestamp
    local snap_file
    snap_file=$(find "$ticket_dir" -maxdepth 1 -name '*-PRECONDITIONS-SNAPSHOT.json' ! -name '*.retired' 2>/dev/null | head -1)

    if [ -z "$snap_file" ]; then
        assert_eq "snapshot file exists" "exists" "missing"
        return
    fi

    local ts_check
    ts_check=$(python3 -c "
import json, sys
try:
    with open(sys.argv[1], encoding='utf-8') as fh:
        snap = json.load(fh)
    snap_ts = snap.get('timestamp', 0)
    max_src_ts = int(sys.argv[2])
    if snap_ts >= max_src_ts:
        print('OK')
    else:
        print(f'FAIL: snap_ts={snap_ts} < max_source_ts={max_src_ts}')
except Exception as e:
    print(f'PARSE_ERROR:{e}')
" "$snap_file" "$max_source_ts" 2>/dev/null || echo "PARSE_ERROR")
    assert_eq "snapshot timestamp >= max source event timestamp" "OK" "$ts_check"

    assert_pass_if_clean "test_snapshot_timestamp_gte_all_source_events"
}
test_snapshot_timestamp_gte_all_source_events

# ── Test 2: LWW — later event wins per composite key ─────────────────────────
echo "Test 2: LWW — later event wins for same composite key (gate_name, session_id, worktree_id)"
test_lww_later_event_wins_per_composite_key() {
    _snapshot_fail
    if [ ! -f "$TICKET_LIB" ]; then
        assert_eq "ticket-lib.sh exists" "exists" "missing"
        return
    fi

    local fn_exists="no"
    if (source "$TICKET_LIB" 2>/dev/null && declare -f _compact_preconditions >/dev/null 2>&1); then
        fn_exists="yes"
    fi
    if [ "$fn_exists" = "no" ]; then
        assert_eq "_compact_preconditions exists" "yes" "no"
        return
    fi

    local tmpdir
    tmpdir=$(mktemp -d)
    _CLEANUP_DIRS+=("$tmpdir")
    local ticket_dir="$tmpdir/lww-ticket-001"
    mkdir -p "$ticket_dir"

    # Two events for the SAME composite key: gate_lint / sess-001 / wt-001
    # First: ts=1700000001, verdict=fail
    # Second (later): ts=1700000099, verdict=pass
    # LWW → later wins → gate_lint should be "pass"
    _make_preconditions_event "$ticket_dir" "1700000001" "gate_lint" "fail" "sess-001" "wt-001" >/dev/null
    _make_preconditions_event "$ticket_dir" "1700000099" "gate_lint" "pass" "sess-001" "wt-001" >/dev/null

    # Compact
    local compact_exit=0
    (source "$TICKET_LIB" 2>/dev/null && _compact_preconditions "$ticket_dir" "lww-ticket-001") 2>/dev/null || compact_exit=$?
    assert_eq "compaction exits 0" "0" "$compact_exit"

    # Read back via _read_latest_preconditions
    local read_output=""
    local read_exit=0
    read_output=$(source "$TICKET_LIB" 2>/dev/null && _read_latest_preconditions "$ticket_dir" 2>/dev/null) || read_exit=$?
    assert_eq "_read_latest_preconditions exits 0" "0" "$read_exit"

    local lww_check
    lww_check=$(python3 -c "
import json, sys
try:
    data = json.loads(sys.argv[1])
    gv = data.get('gate_verdicts', {})
    verdict = gv.get('gate_lint', 'missing')
    if verdict == 'pass':
        print('OK')
    else:
        print(f'FAIL: gate_lint verdict={verdict} (expected pass from later event)')
except Exception as e:
    print(f'PARSE_ERROR:{e}')
" "$read_output" 2>/dev/null || echo "PARSE_ERROR")
    assert_eq "LWW: later event (pass) wins over earlier event (fail) for same key" "OK" "$lww_check"

    assert_pass_if_clean "test_lww_later_event_wins_per_composite_key"
}
test_lww_later_event_wins_per_composite_key

# ── Test 3: Multiple sessions — distinct composite keys all preserved ──────────
echo "Test 3: distinct composite keys (different gate_name+session_id+worktree_id) all preserved"
test_multiple_sessions_preserve_all_gate_verdicts() {
    _snapshot_fail
    if [ ! -f "$TICKET_LIB" ]; then
        assert_eq "ticket-lib.sh exists" "exists" "missing"
        return
    fi

    local fn_exists="no"
    if (source "$TICKET_LIB" 2>/dev/null && declare -f _compact_preconditions >/dev/null 2>&1); then
        fn_exists="yes"
    fi
    if [ "$fn_exists" = "no" ]; then
        assert_eq "_compact_preconditions exists" "yes" "no"
        return
    fi

    local tmpdir
    tmpdir=$(mktemp -d)
    _CLEANUP_DIRS+=("$tmpdir")
    local ticket_dir="$tmpdir/multi-sess-ticket-001"
    mkdir -p "$ticket_dir"

    # 3 events with DISTINCT composite keys (different gate_name)
    # All should survive compaction (no LWW collision)
    _make_preconditions_event "$ticket_dir" "1700000001" "gate_lint" "pass" "sess-001" "wt-001" >/dev/null
    _make_preconditions_event "$ticket_dir" "1700000002" "gate_test" "pass" "sess-001" "wt-001" >/dev/null
    _make_preconditions_event "$ticket_dir" "1700000003" "gate_format" "pass" "sess-001" "wt-001" >/dev/null

    # Compact
    local compact_exit=0
    (source "$TICKET_LIB" 2>/dev/null && _compact_preconditions "$ticket_dir" "multi-sess-ticket-001") 2>/dev/null || compact_exit=$?
    assert_eq "compaction exits 0" "0" "$compact_exit"

    # Read back
    local read_output=""
    local read_exit=0
    read_output=$(source "$TICKET_LIB" 2>/dev/null && _read_latest_preconditions "$ticket_dir" 2>/dev/null) || read_exit=$?
    assert_eq "_read_latest_preconditions exits 0" "0" "$read_exit"

    local multi_check
    multi_check=$(python3 -c "
import json, sys
try:
    data = json.loads(sys.argv[1])
    gv = data.get('gate_verdicts', {})
    missing = [k for k in ['gate_lint', 'gate_test', 'gate_format'] if k not in gv]
    if not missing:
        print('OK')
    else:
        print(f'MISSING_KEYS:{missing}')
except Exception as e:
    print(f'PARSE_ERROR:{e}')
" "$read_output" 2>/dev/null || echo "PARSE_ERROR")
    assert_eq "all 3 distinct gate verdicts preserved after compaction" "OK" "$multi_check"

    assert_pass_if_clean "test_multiple_sessions_preserve_all_gate_verdicts"
}
test_multiple_sessions_preserve_all_gate_verdicts

print_summary
