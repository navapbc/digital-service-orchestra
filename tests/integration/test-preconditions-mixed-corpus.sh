#!/usr/bin/env bash
# tests/integration/test-preconditions-mixed-corpus.sh
# Integration tests for PRECONDITIONS graceful-degrade with mixed corpus:
# legacy tickets (no events), rollout tickets (flat events), and compacted
# tickets (snapshot + retired originals).
#
# Tests:
#   1. test_mixed_corpus_legacy_ticket_no_events — zero events → pre-manifest
#   2. test_mixed_corpus_flat_events_lww_merged — flat events → LWW merged present
#   3. test_mixed_corpus_snapshot_supersedes_flat — snapshot → snapshot returned
#
# Usage: bash tests/integration/test-preconditions-mixed-corpus.sh

# NOTE: -e is intentionally omitted — test functions return non-zero by design
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"
TICKET_LIB="$REPO_ROOT/plugins/dso/scripts/ticket-lib.sh"

source "$REPO_ROOT/tests/lib/assert.sh"

echo "=== test-preconditions-mixed-corpus.sh ==="

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

# ── Test 1: Legacy ticket with zero events → pre-manifest ────────────────────
echo "Test 1: legacy ticket with zero PRECONDITIONS events returns pre-manifest"
test_mixed_corpus_legacy_ticket_no_events() {
    _snapshot_fail
    if [ ! -f "$TICKET_LIB" ]; then
        assert_eq "ticket-lib.sh exists" "exists" "missing"
        return
    fi

    local fn_exists="no"
    if (source "$TICKET_LIB" 2>/dev/null && declare -f _read_latest_preconditions >/dev/null 2>&1); then
        fn_exists="yes"
    fi
    if [ "$fn_exists" = "no" ]; then
        assert_eq "_read_latest_preconditions exists" "yes" "no"
        return
    fi

    local tmpdir
    tmpdir=$(mktemp -d)
    _CLEANUP_DIRS+=("$tmpdir")
    local ticket_dir="$tmpdir/legacy-ticket-001"
    mkdir -p "$ticket_dir"

    # No PRECONDITIONS events — directory is empty (legacy ticket state)
    local read_exit=0
    (source "$TICKET_LIB" 2>/dev/null && _read_latest_preconditions "$ticket_dir" 2>/dev/null) || read_exit=$?

    # Assert: exits non-zero for pre-manifest (no events)
    assert_eq "legacy ticket: _read_latest_preconditions exits non-zero (pre-manifest)" \
        "1" "$([ "$read_exit" -ne 0 ] && echo 1 || echo 0)"

    # Assert: no crash (exit code should be 1, not unexpected non-1 nonzero)
    assert_eq "legacy ticket: exit code is exactly 1 (pre-manifest sentinel)" "1" "$read_exit"

    assert_pass_if_clean "test_mixed_corpus_legacy_ticket_no_events"
}
test_mixed_corpus_legacy_ticket_no_events

# ── Test 2: Flat events → LWW merged present ─────────────────────────────────
echo "Test 2: flat PRECONDITIONS events → LWW-merged present result"
test_mixed_corpus_flat_events_lww_merged() {
    _snapshot_fail
    if [ ! -f "$TICKET_LIB" ]; then
        assert_eq "ticket-lib.sh exists" "exists" "missing"
        return
    fi

    local fn_exists="no"
    if (source "$TICKET_LIB" 2>/dev/null && declare -f _read_latest_preconditions >/dev/null 2>&1); then
        fn_exists="yes"
    fi
    if [ "$fn_exists" = "no" ]; then
        assert_eq "_read_latest_preconditions exists" "yes" "no"
        return
    fi

    local tmpdir
    tmpdir=$(mktemp -d)
    _CLEANUP_DIRS+=("$tmpdir")
    local ticket_dir="$tmpdir/rollout-ticket-001"
    mkdir -p "$ticket_dir"

    # Create 2 flat events for different gates
    _make_preconditions_event "$ticket_dir" "1700000001" "gate_lint" "pass" "sess-001" "wt-001" >/dev/null
    _make_preconditions_event "$ticket_dir" "1700000002" "gate_test" "pass" "sess-001" "wt-001" >/dev/null

    local read_output=""
    local read_exit=0
    read_output=$(source "$TICKET_LIB" 2>/dev/null && _read_latest_preconditions "$ticket_dir" 2>/dev/null) || read_exit=$?

    # Assert: exits 0 and returns valid JSON
    assert_eq "flat events: _read_latest_preconditions exits 0" "0" "$read_exit"

    local status_check
    status_check=$(python3 -c "
import json, sys
try:
    data = json.loads(sys.argv[1])
    status = data.get('status', 'missing')
    gv = data.get('gate_verdicts', {})
    if status == 'present' and 'gate_lint' in gv and 'gate_test' in gv:
        print('OK')
    else:
        print(f'UNEXPECTED: status={status} gate_verdicts={gv}')
except Exception as e:
    print(f'PARSE_ERROR:{e}')
" "$read_output" 2>/dev/null || echo "PARSE_ERROR")
    assert_eq "flat events: LWW-merged result has status=present and both gate verdicts" "OK" "$status_check"

    assert_pass_if_clean "test_mixed_corpus_flat_events_lww_merged"
}
test_mixed_corpus_flat_events_lww_merged

# ── Test 3: Snapshot supersedes flat events ───────────────────────────────────
echo "Test 3: compacted snapshot supersedes flat events"
test_mixed_corpus_snapshot_supersedes_flat() {
    _snapshot_fail
    if [ ! -f "$TICKET_LIB" ]; then
        assert_eq "ticket-lib.sh exists" "exists" "missing"
        return
    fi

    local fn_both="no"
    if (source "$TICKET_LIB" 2>/dev/null && \
        declare -f _read_latest_preconditions >/dev/null 2>&1 && \
        declare -f _compact_preconditions >/dev/null 2>&1); then
        fn_both="yes"
    fi
    if [ "$fn_both" = "no" ]; then
        assert_eq "both functions exist" "yes" "no"
        return
    fi

    local tmpdir
    tmpdir=$(mktemp -d)
    _CLEANUP_DIRS+=("$tmpdir")
    local ticket_dir="$tmpdir/compacted-ticket-001"
    mkdir -p "$ticket_dir"

    # Create 2 flat events, then compact them into a snapshot
    _make_preconditions_event "$ticket_dir" "1700000001" "gate_lint" "pass" "sess-001" "wt-001" >/dev/null
    _make_preconditions_event "$ticket_dir" "1700000002" "gate_test" "pass" "sess-001" "wt-001" >/dev/null

    # Compact to create snapshot
    local compact_exit=0
    (source "$TICKET_LIB" 2>/dev/null && _compact_preconditions "$ticket_dir" "compacted-ticket-001") 2>/dev/null || compact_exit=$?
    assert_eq "compaction exits 0" "0" "$compact_exit"

    # Assert snapshot exists and originals are retired
    local snap_count
    snap_count=$(find "$ticket_dir" -maxdepth 1 -name '*-PRECONDITIONS-SNAPSHOT.json' ! -name '*.retired' 2>/dev/null | wc -l | tr -d ' ')
    assert_eq "snapshot exists after compaction" "1" "$snap_count"

    local retired_count
    retired_count=$(find "$ticket_dir" -maxdepth 1 -name '*-PRECONDITIONS.json.retired' 2>/dev/null | wc -l | tr -d ' ')
    assert_eq "originals retired after compaction" "2" "$retired_count"

    # Read back — should return snapshot payload
    local read_output=""
    local read_exit=0
    read_output=$(source "$TICKET_LIB" 2>/dev/null && _read_latest_preconditions "$ticket_dir" 2>/dev/null) || read_exit=$?
    assert_eq "snapshot read exits 0" "0" "$read_exit"

    local snapshot_check
    snapshot_check=$(python3 -c "
import json, sys
try:
    data = json.loads(sys.argv[1])
    status = data.get('status', 'missing')
    gv = data.get('gate_verdicts', {})
    if status == 'present' or (gv and len(gv) >= 1):
        print('OK')
    else:
        print(f'UNEXPECTED: status={status} gate_verdicts={gv}')
except Exception as e:
    print(f'PARSE_ERROR:{e}')
" "$read_output" 2>/dev/null || echo "PARSE_ERROR")
    assert_eq "snapshot payload returned with gate_verdicts present" "OK" "$snapshot_check"

    assert_pass_if_clean "test_mixed_corpus_snapshot_supersedes_flat"
}
test_mixed_corpus_snapshot_supersedes_flat

print_summary
