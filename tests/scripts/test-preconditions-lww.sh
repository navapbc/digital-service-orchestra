#!/usr/bin/env bash
# tests/scripts/test-preconditions-lww.sh
# RED tests for _read_latest_preconditions() in plugins/dso/scripts/ticket-lib.sh.
#
# This function does NOT yet exist — all tests are expected to FAIL (RED phase).
#
# Covers:
#   1. Returns the most-recent PRECONDITIONS.json for a composite key (gate_name + session_id)
#   2. LWW: when multiple files share the same composite key, the one with the
#      lexicographically highest ISO8601 timestamp prefix wins
#   3. Concurrency: two background write processes both complete; reader returns
#      the latest without data corruption or missing files
#
# Usage: bash tests/scripts/test-preconditions-lww.sh

# NOTE: -e is intentionally omitted — test functions return non-zero by design
# (they assert against unimplemented features). -e would abort the runner.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"
TICKET_LIB="$REPO_ROOT/plugins/dso/scripts/ticket-lib.sh"
TICKET_SCRIPT="$REPO_ROOT/plugins/dso/scripts/ticket"

source "$REPO_ROOT/tests/lib/assert.sh"
source "$REPO_ROOT/tests/lib/git-fixtures.sh"

echo "=== test-preconditions-lww.sh ==="

# ── Helper: create a fresh ticket-ready test repo ─────────────────────────────
_make_ticket_repo() {
    local tmp
    tmp=$(mktemp -d)
    _CLEANUP_DIRS+=("$tmp")
    clone_test_repo "$tmp/repo"
    # Initialize ticket system
    (cd "$tmp/repo" && _TICKET_TEST_NO_SYNC=1 bash "$TICKET_SCRIPT" init 2>/dev/null) || true
    echo "$tmp/repo"
}

# ── Helper: write a PRECONDITIONS event file into the ticket dir ───────────────
# Usage: _write_preconditions_file <ticket_dir> <iso_ts> <uuid> <gate_name> <session_id> [outcome]
# Creates: <ticket_dir>/<iso_ts>-<uuid>-PRECONDITIONS.json
_write_preconditions_file() {
    local ticket_dir="$1"
    local iso_ts="$2"
    local file_uuid="$3"
    local gate_name="$4"
    local session_id="$5"
    local outcome="${6:-pass}"

    mkdir -p "$ticket_dir"
    local filename="${iso_ts}-${file_uuid}-PRECONDITIONS.json"
    python3 -c "
import json, sys
data = {
    'timestamp': sys.argv[1],
    'uuid': sys.argv[2],
    'event_type': 'PRECONDITIONS',
    'gate_name': sys.argv[3],
    'session_id': sys.argv[4],
    'outcome': sys.argv[5]
}
with open(sys.argv[6], 'w', encoding='utf-8') as f:
    json.dump(data, f)
" "$iso_ts" "$file_uuid" "$gate_name" "$session_id" "$outcome" "$ticket_dir/$filename"

    echo "$ticket_dir/$filename"
}

# ── Test 1: returns most-recently-written PRECONDITIONS for composite key ─────
echo "Test 1: _read_latest_preconditions returns the newest PRECONDITIONS.json for the composite key (gate_name + session_id)"
test_read_latest_preconditions_returns_newest() {
    local repo
    repo=$(_make_ticket_repo)

    local tracker_dir="$repo/.tickets-tracker"
    local ticket_id="test-prec-1"
    local ticket_dir="$tracker_dir/$ticket_id"

    # ticket-lib.sh must be sourceable and define _read_latest_preconditions — RED: not yet
    if [ ! -f "$TICKET_LIB" ]; then
        assert_eq "_read_latest_preconditions function available" "available" "ticket-lib.sh missing"
        return
    fi
    if ! (source "$TICKET_LIB" 2>/dev/null && declare -f _read_latest_preconditions >/dev/null 2>&1); then
        assert_eq "_read_latest_preconditions is defined in ticket-lib.sh" "defined" "not_defined"
        return
    fi

    # Write two PRECONDITIONS files for the same composite key with different timestamps
    # Older file
    _write_preconditions_file \
        "$ticket_dir" \
        "2026-04-20T10:00:00Z" \
        "aaaa1111-0000-0000-0000-000000000001" \
        "review-gate" \
        "session-abc" \
        "pass" >/dev/null

    # Newer file (higher ISO8601 timestamp = lexicographically greater)
    local newer_file
    newer_file=$(_write_preconditions_file \
        "$ticket_dir" \
        "2026-04-20T11:00:00Z" \
        "aaaa1111-0000-0000-0000-000000000002" \
        "review-gate" \
        "session-abc" \
        "pass")

    # Load ticket-lib and call the function
    local result
    result=$(cd "$repo" && source "$TICKET_LIB" 2>/dev/null && \
        _read_latest_preconditions "$ticket_id" "review-gate" "session-abc" 2>/dev/null) || true

    # Should return the content of the newer file
    local expected_uuid
    expected_uuid=$(python3 -c "import json,sys; d=json.load(sys.stdin); print(d['uuid'])" < "$newer_file" 2>/dev/null || echo "")
    local actual_uuid
    actual_uuid=$(echo "$result" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d['uuid'])" 2>/dev/null || echo "")

    assert_eq "_read_latest_preconditions returns newest uuid" \
        "aaaa1111-0000-0000-0000-000000000002" "$actual_uuid"
}
test_read_latest_preconditions_returns_newest

# ── Test 2: LWW — highest ISO8601 timestamp prefix wins ───────────────────────
echo "Test 2: LWW — lexicographic sort on ISO8601 timestamp prefix picks the latest when multiple files share the composite key"
test_read_latest_preconditions_lww_timestamp_order() {
    local repo
    repo=$(_make_ticket_repo)

    local tracker_dir="$repo/.tickets-tracker"
    local ticket_id="test-prec-lww"
    local ticket_dir="$tracker_dir/$ticket_id"

    if [ ! -f "$TICKET_LIB" ]; then
        assert_eq "_read_latest_preconditions LWW available" "available" "ticket-lib.sh missing"
        return
    fi
    if ! (source "$TICKET_LIB" 2>/dev/null && declare -f _read_latest_preconditions >/dev/null 2>&1); then
        assert_eq "_read_latest_preconditions is defined (LWW test)" "defined" "not_defined"
        return
    fi

    # Write three files with the same composite key, out-of-order by uuid
    # but with deterministic ISO8601 timestamps so sort order is unambiguous.
    _write_preconditions_file \
        "$ticket_dir" \
        "2026-04-20T08:00:00Z" \
        "bbbb2222-0000-0000-0000-000000000001" \
        "test-gate" \
        "sess-xyz" \
        "fail" >/dev/null

    _write_preconditions_file \
        "$ticket_dir" \
        "2026-04-20T12:00:00Z" \
        "bbbb2222-0000-0000-0000-000000000003" \
        "test-gate" \
        "sess-xyz" \
        "pass" >/dev/null

    _write_preconditions_file \
        "$ticket_dir" \
        "2026-04-20T09:30:00Z" \
        "bbbb2222-0000-0000-0000-000000000002" \
        "test-gate" \
        "sess-xyz" \
        "pass" >/dev/null

    local result
    result=$(cd "$repo" && source "$TICKET_LIB" 2>/dev/null && \
        _read_latest_preconditions "$ticket_id" "test-gate" "sess-xyz" 2>/dev/null) || true

    # Expected: the 12:00 file has uuid ...000003
    local actual_uuid
    actual_uuid=$(echo "$result" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d['uuid'])" 2>/dev/null || echo "")

    assert_eq "_read_latest_preconditions LWW picks highest timestamp" \
        "bbbb2222-0000-0000-0000-000000000003" "$actual_uuid"

    # Also verify the outcome field of the winner is "pass"
    local actual_outcome
    actual_outcome=$(echo "$result" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('outcome',''))" 2>/dev/null || echo "")
    assert_eq "_read_latest_preconditions LWW winner has correct outcome" \
        "pass" "$actual_outcome"
}
test_read_latest_preconditions_lww_timestamp_order

# ── Test 3: concurrency — two background writers; reader returns the latest ────
echo "Test 3: concurrent writers both complete without data corruption; reader returns the latest without missing files"
test_read_latest_preconditions_concurrent_writes() {
    local repo
    repo=$(_make_ticket_repo)

    local tracker_dir="$repo/.tickets-tracker"
    local ticket_id="test-prec-concurrent"
    local ticket_dir="$tracker_dir/$ticket_id"
    mkdir -p "$ticket_dir"

    if [ ! -f "$TICKET_LIB" ]; then
        assert_eq "_read_latest_preconditions concurrency available" "available" "ticket-lib.sh missing"
        return
    fi
    if ! (source "$TICKET_LIB" 2>/dev/null && declare -f _read_latest_preconditions >/dev/null 2>&1); then
        assert_eq "_read_latest_preconditions is defined (concurrency test)" "defined" "not_defined"
        return
    fi

    # Two background processes write PRECONDITIONS files with distinct timestamps.
    # Use distinct UUIDs so we can verify both files were written.
    local ts_early="2026-04-20T14:00:00Z"
    local ts_late="2026-04-20T15:00:00Z"
    local uuid_early="cccc3333-0000-0000-0000-000000000001"
    local uuid_late="cccc3333-0000-0000-0000-000000000002"

    # Background writer 1 (early timestamp)
    (
        _write_preconditions_file \
            "$ticket_dir" \
            "$ts_early" \
            "$uuid_early" \
            "commit-gate" \
            "sess-concurrent" \
            "pass" >/dev/null
    ) &
    local pid1=$!

    # Background writer 2 (late timestamp — should win)
    (
        _write_preconditions_file \
            "$ticket_dir" \
            "$ts_late" \
            "$uuid_late" \
            "commit-gate" \
            "sess-concurrent" \
            "pass" >/dev/null
    ) &
    local pid2=$!

    # Wait for both background writers to complete
    wait "$pid1" "$pid2"

    # Assert both files exist (no data corruption / missing files)
    local early_file="$ticket_dir/${ts_early}-${uuid_early}-PRECONDITIONS.json"
    local late_file="$ticket_dir/${ts_late}-${uuid_late}-PRECONDITIONS.json"

    if [ -f "$early_file" ]; then
        assert_eq "concurrent write 1 file exists" "exists" "exists"
    else
        assert_eq "concurrent write 1 file exists" "exists" "missing"
    fi

    if [ -f "$late_file" ]; then
        assert_eq "concurrent write 2 file exists" "exists" "exists"
    else
        assert_eq "concurrent write 2 file exists" "exists" "missing"
    fi

    # Both files must be valid JSON (no partial writes / corruption)
    local parse_exit1=0
    python3 -c "import json,sys; json.load(sys.stdin)" < "$early_file" 2>/dev/null || parse_exit1=$?
    assert_eq "concurrent write 1 file is valid JSON" "0" "$parse_exit1"

    local parse_exit2=0
    python3 -c "import json,sys; json.load(sys.stdin)" < "$late_file" 2>/dev/null || parse_exit2=$?
    assert_eq "concurrent write 2 file is valid JSON" "0" "$parse_exit2"

    # _read_latest_preconditions must return the LATE file (highest timestamp)
    local result
    result=$(cd "$repo" && source "$TICKET_LIB" 2>/dev/null && \
        _read_latest_preconditions "$ticket_id" "commit-gate" "sess-concurrent" 2>/dev/null) || true

    local actual_uuid
    actual_uuid=$(echo "$result" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d['uuid'])" 2>/dev/null || echo "")

    assert_eq "_read_latest_preconditions returns latest after concurrent writes" \
        "$uuid_late" "$actual_uuid"
}
test_read_latest_preconditions_concurrent_writes

print_summary
