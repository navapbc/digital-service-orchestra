#!/usr/bin/env bash
# tests/scripts/test-preconditions-record.sh
# RED tests for plugins/dso/scripts/preconditions-record.sh (does NOT exist yet).
#
# Covers:
#   1. Invocation with required args writes a PRECONDITIONS.json into per-ticket event dir
#   2. Missing required args exits non-zero with usage message
#   3. Output JSON contains required fields: event_type, gate_name, session_id,
#      worktree_id, tier, timestamp, data
#   4. Two invocations with same gate_name+session_id produce two separate timestamped files
#
# Usage: bash tests/scripts/test-preconditions-record.sh

# NOTE: -e is intentionally omitted — test functions return non-zero by design
# (they assert against unimplemented features). -e would abort the runner.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"
PRECONDITIONS_SCRIPT="$REPO_ROOT/plugins/dso/scripts/preconditions-record.sh"

source "$REPO_ROOT/tests/lib/assert.sh"
source "$REPO_ROOT/tests/lib/git-fixtures.sh"

echo "=== test-preconditions-record.sh ==="

# ── Helper: create a fresh temp git repo with ticket system initialized ──────
_make_test_repo() {
    local tmp
    tmp=$(mktemp -d)
    _CLEANUP_DIRS+=("$tmp")
    clone_test_repo "$tmp/repo"
    echo "$tmp/repo"
}

# ── Helper: initialize ticket system in a test repo ──────────────────────────
_init_tickets() {
    local repo="$1"
    (cd "$repo" && bash "$REPO_ROOT/plugins/dso/scripts/ticket-init.sh" 2>/dev/null) || true
}

# ── Test 1: invocation with required args writes PRECONDITIONS.json into per-ticket event dir
echo "Test 1: preconditions-record.sh writes a PRECONDITIONS.json file into the per-ticket event directory"
test_preconditions_record_writes_event() {
    if [ ! -f "$PRECONDITIONS_SCRIPT" ]; then
        assert_eq "preconditions-record.sh exists" "exists" "missing"
        return
    fi

    local repo
    repo=$(_make_test_repo)
    _init_tickets "$repo"

    local ticket_id="test-t1a2"
    local exit_code=0
    (cd "$repo" && bash "$PRECONDITIONS_SCRIPT" \
        --ticket-id "$ticket_id" \
        --gate-name "story_gate" \
        --session-id "sess-abc123" \
        --tier "standard") || exit_code=$?

    assert_eq "exits zero on valid args" "0" "$exit_code"

    # File must appear under .tickets-tracker/<ticket_id>/
    local ticket_event_dir="$repo/.tickets-tracker/$ticket_id"
    local file_count
    file_count=$(find "$ticket_event_dir" -name '*-PRECONDITIONS.json' -type f 2>/dev/null | wc -l | tr -d ' ')
    assert_eq "one PRECONDITIONS.json written to per-ticket event dir" "1" "$file_count"
}
test_preconditions_record_writes_event

# ── Test 2: missing required args exits non-zero with usage message ───────────
echo "Test 2: preconditions-record.sh exits non-zero with usage message when required args are missing"
test_missing_args_exits_nonzero() {
    if [ ! -f "$PRECONDITIONS_SCRIPT" ]; then
        assert_eq "preconditions-record.sh exists for missing-args test" "exists" "missing"
        return
    fi

    local repo
    repo=$(_make_test_repo)
    _init_tickets "$repo"

    # Test: missing --ticket-id
    local exit_no_ticket=0
    local stderr_no_ticket
    stderr_no_ticket=$(cd "$repo" && bash "$PRECONDITIONS_SCRIPT" \
        --gate-name "story_gate" \
        --session-id "sess-abc123" \
        --tier "standard" 2>&1) || exit_no_ticket=$?
    assert_eq "exits non-zero without --ticket-id" "1" "$([ "$exit_no_ticket" -ne 0 ] && echo 1 || echo 0)"
    local has_usage_no_ticket
    has_usage_no_ticket=$(echo "$stderr_no_ticket" | grep -ic "usage\|required\|error\|missing" || true)
    assert_eq "usage/error message shown without --ticket-id" "1" "$([ "${has_usage_no_ticket:-0}" -gt 0 ] && echo 1 || echo 0)"

    # Test: missing --gate-name
    local exit_no_gate=0
    local stderr_no_gate
    stderr_no_gate=$(cd "$repo" && bash "$PRECONDITIONS_SCRIPT" \
        --ticket-id "test-t1a2" \
        --session-id "sess-abc123" \
        --tier "standard" 2>&1) || exit_no_gate=$?
    assert_eq "exits non-zero without --gate-name" "1" "$([ "$exit_no_gate" -ne 0 ] && echo 1 || echo 0)"

    # Test: missing --session-id
    local exit_no_session=0
    local stderr_no_session
    stderr_no_session=$(cd "$repo" && bash "$PRECONDITIONS_SCRIPT" \
        --ticket-id "test-t1a2" \
        --gate-name "story_gate" \
        --tier "standard" 2>&1) || exit_no_session=$?
    assert_eq "exits non-zero without --session-id" "1" "$([ "$exit_no_session" -ne 0 ] && echo 1 || echo 0)"

    # Test: missing --tier
    local exit_no_tier=0
    local stderr_no_tier
    stderr_no_tier=$(cd "$repo" && bash "$PRECONDITIONS_SCRIPT" \
        --ticket-id "test-t1a2" \
        --gate-name "story_gate" \
        --session-id "sess-abc123" 2>&1) || exit_no_tier=$?
    assert_eq "exits non-zero without --tier" "1" "$([ "$exit_no_tier" -ne 0 ] && echo 1 || echo 0)"
}
test_missing_args_exits_nonzero

# ── Test 3: output JSON contains required fields ───────────────────────────────
echo "Test 3: preconditions-record.sh writes JSON with required fields (event_type, gate_name, session_id, worktree_id, tier, timestamp, data)"
test_required_json_fields() {
    if [ ! -f "$PRECONDITIONS_SCRIPT" ]; then
        assert_eq "preconditions-record.sh exists for required-fields test" "exists" "missing"
        return
    fi

    local repo
    repo=$(_make_test_repo)
    _init_tickets "$repo"

    local ticket_id="test-t1b2"
    (cd "$repo" && bash "$PRECONDITIONS_SCRIPT" \
        --ticket-id "$ticket_id" \
        --gate-name "epic_gate" \
        --session-id "sess-def456" \
        --tier "deep") 2>/dev/null || true

    local event_file
    event_file=$(find "$repo/.tickets-tracker/$ticket_id" -name '*-PRECONDITIONS.json' -type f 2>/dev/null | head -1)

    if [ -z "$event_file" ]; then
        assert_eq "event file written for field-check test" "found" "not-found"
        return
    fi

    local check_result
    check_result=$(python3 -c "
import json, sys
with open(sys.argv[1], encoding='utf-8') as f:
    data = json.load(f)
required = ['event_type', 'gate_name', 'session_id', 'worktree_id', 'tier', 'timestamp', 'data']
missing = [field for field in required if field not in data or data[field] is None]
if missing:
    print('missing:' + ','.join(missing))
else:
    # Verify field values match what we passed in
    errors = []
    if data.get('gate_name') != 'epic_gate':
        errors.append('gate_name=' + str(data.get('gate_name')))
    if data.get('session_id') != 'sess-def456':
        errors.append('session_id=' + str(data.get('session_id')))
    if data.get('tier') != 'deep':
        errors.append('tier=' + str(data.get('tier')))
    if data.get('event_type', '').upper() != 'PRECONDITIONS':
        errors.append('event_type=' + str(data.get('event_type')))
    if errors:
        print('wrong:' + ','.join(errors))
    else:
        print('ok')
" "$event_file" 2>/dev/null || echo "parse-error")

    assert_eq "all required fields present and correct" "ok" "$check_result"
}
test_required_json_fields

# ── Test 4: two invocations with same gate_name+session_id produce two separate files
echo "Test 4: two invocations with same gate_name+session_id produce two separate timestamped PRECONDITIONS files"
test_two_invocations_produce_two_files() {
    if [ ! -f "$PRECONDITIONS_SCRIPT" ]; then
        assert_eq "preconditions-record.sh exists for two-files test" "exists" "missing"
        return
    fi

    local repo
    repo=$(_make_test_repo)
    _init_tickets "$repo"

    local ticket_id="test-t1c2"

    # First invocation
    (cd "$repo" && bash "$PRECONDITIONS_SCRIPT" \
        --ticket-id "$ticket_id" \
        --gate-name "story_gate" \
        --session-id "sess-same-123" \
        --tier "light") 2>/dev/null || true

    # Brief pause to ensure distinct millisecond timestamps
    sleep 0.01

    # Second invocation — identical args
    (cd "$repo" && bash "$PRECONDITIONS_SCRIPT" \
        --ticket-id "$ticket_id" \
        --gate-name "story_gate" \
        --session-id "sess-same-123" \
        --tier "light") 2>/dev/null || true

    local ticket_event_dir="$repo/.tickets-tracker/$ticket_id"
    local file_count
    file_count=$(find "$ticket_event_dir" -name '*-PRECONDITIONS.json' -type f 2>/dev/null | wc -l | tr -d ' ')
    assert_eq "two invocations produce two separate files (LWW at read time)" "2" "$file_count"

    if [ "$file_count" -ge 2 ]; then
        local files
        files=$(find "$ticket_event_dir" -name '*-PRECONDITIONS.json' -type f 2>/dev/null | sort)
        local first second
        first=$(echo "$files" | head -1)
        second=$(echo "$files" | tail -1)
        assert_ne "two files have distinct names" "$first" "$second"
    fi
}
test_two_invocations_produce_two_files

print_summary
