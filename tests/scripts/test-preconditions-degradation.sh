#!/usr/bin/env bash
# tests/scripts/test-preconditions-degradation.sh
# RED tests for null-coalescing in _read_latest_preconditions() when a mixed
# corpus of PRECONDITIONS events exists — some with data.degradation, some without.
#
# Covers:
#   test_null_coalescing_in_mixed_fixture — _read_latest_preconditions() must
#     return exit 0 and valid JSON when some events have data.degradation and
#     some do not (absent field must be null-coalesced, not treated as an error).
#
# Usage: bash tests/scripts/test-preconditions-degradation.sh

# NOTE: -e is intentionally omitted — test functions return non-zero by design.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"
TICKET_LIB="$REPO_ROOT/plugins/dso/scripts/ticket-lib.sh"

source "$REPO_ROOT/tests/lib/assert.sh"

echo "=== test-preconditions-degradation.sh ==="

_CLEANUP_DIRS=()
trap 'rm -rf "${_CLEANUP_DIRS[@]:-}"' EXIT

# ── test_null_coalescing_in_mixed_fixture ─────────────────────────────────────
echo "Test 1: _read_latest_preconditions does not fail when some events have data.degradation and some do not"
test_null_coalescing_in_mixed_fixture() {
    if [ ! -f "$TICKET_LIB" ]; then
        assert_eq "ticket-lib.sh exists" "exists" "missing"
        return
    fi

    # Build a temp tracker dir with a stub .git file (required by _write_preconditions)
    local tmp_tracker
    tmp_tracker=$(mktemp -d)
    _CLEANUP_DIRS+=("$tmp_tracker")
    # Stub .git so the initialization check passes
    printf "gitdir: /dev/null\n" > "$tmp_tracker/.git"

    local story_dir="$tmp_tracker/story-nc01"
    mkdir -p "$story_dir"

    # Event 1: with degradation fields
    local ts1
    ts1=$(python3 -c "import time; print(int(time.time() * 1000))")
    local uuid1
    uuid1=$(python3 -c "import uuid; print(str(uuid.uuid4()))")
    python3 -c "
import json, sys
payload = {
    'event_type': 'PRECONDITIONS',
    'schema_version': 2,
    'manifest_depth': 'standard',
    'gate_name': 'test_gate',
    'session_id': 'sess-1',
    'worktree_id': 'branch-a',
    'tier': 'standard',
    'timestamp': int(sys.argv[1]),
    'gate_verdicts': [],
    'evidence_ref': {},
    'affects_fields': [],
    'data': {'degradation': True, 'degradation_type': 'inferred_decision'},
}
with open(sys.argv[2], 'w', encoding='utf-8') as f:
    json.dump(payload, f)
" "$ts1" "$story_dir/${ts1}-${uuid1}-PRECONDITIONS.json"

    # Brief pause to ensure distinct millisecond timestamps
    sleep 0.01

    # Event 2: without degradation fields (simulates pre-feature events in the corpus)
    local ts2
    ts2=$(python3 -c "import time; print(int(time.time() * 1000))")
    local uuid2
    uuid2=$(python3 -c "import uuid; print(str(uuid.uuid4()))")
    python3 -c "
import json, sys
payload = {
    'event_type': 'PRECONDITIONS',
    'schema_version': 2,
    'manifest_depth': 'standard',
    'gate_name': 'test_gate',
    'session_id': 'sess-2',
    'worktree_id': 'branch-b',
    'tier': 'standard',
    'timestamp': int(sys.argv[1]),
    'gate_verdicts': [],
    'evidence_ref': {},
    'affects_fields': [],
    'data': {'foo': 'bar'},
}
with open(sys.argv[2], 'w', encoding='utf-8') as f:
    json.dump(payload, f)
" "$ts2" "$story_dir/${ts2}-${uuid2}-PRECONDITIONS.json"

    # Call _read_latest_preconditions in 1-arg (absolute path) mode
    # This exercises the LWW-merge path over the entire ticket dir
    local result=""
    local exit_code=0
    # Source ticket-lib and call the function directly
    result=$(bash -c "
source '$TICKET_LIB'
_read_latest_preconditions '$story_dir'
" 2>&1) || exit_code=$?

    assert_eq "_read_latest_preconditions exits 0 on mixed degradation corpus" "0" "$exit_code"

    # Verify the output is valid JSON
    local is_valid_json
    is_valid_json=$(echo "$result" | python3 -c "
import json, sys
try:
    data = json.load(sys.stdin)
    print('ok')
except Exception as e:
    print('invalid-json:' + str(e))
" 2>/dev/null || echo "python-error")
    assert_eq "_read_latest_preconditions returns valid JSON for mixed corpus" "ok" "$is_valid_json"

    # Also call in 3-arg mode for sess-1 (has degradation) — must not fail
    local result_sess1=""
    local exit_sess1=0
    result_sess1=$(bash -c "
export TICKETS_TRACKER_DIR='$tmp_tracker'
source '$TICKET_LIB'
_read_latest_preconditions 'story-nc01' 'test_gate' 'sess-1'
" 2>&1) || exit_sess1=$?
    assert_eq "_read_latest_preconditions exits 0 for sess-1 (has degradation)" "0" "$exit_sess1"

    # 3-arg mode for sess-2 (no degradation) — must not fail
    local result_sess2=""
    local exit_sess2=0
    result_sess2=$(bash -c "
export TICKETS_TRACKER_DIR='$tmp_tracker'
source '$TICKET_LIB'
_read_latest_preconditions 'story-nc01' 'test_gate' 'sess-2'
" 2>&1) || exit_sess2=$?
    assert_eq "_read_latest_preconditions exits 0 for sess-2 (no degradation)" "0" "$exit_sess2"

    # sess-2 output must be valid JSON (absent degradation must not cause a crash)
    if [ -n "$result_sess2" ]; then
        local is_valid_sess2
        is_valid_sess2=$(echo "$result_sess2" | python3 -c "
import json, sys
try:
    json.load(sys.stdin)
    print('ok')
except Exception as e:
    print('invalid-json:' + str(e))
" 2>/dev/null || echo "python-error")
        assert_eq "_read_latest_preconditions returns valid JSON for sess-2 (absent degradation null-coalesced)" "ok" "$is_valid_sess2"
    fi
}
test_null_coalescing_in_mixed_fixture

print_summary
