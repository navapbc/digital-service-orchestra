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

# ── Test 5: --degradation and --degradation-type CLI flags ────────────────────
echo "Test 5: --degradation / --degradation-type flags write expected fields into the PRECONDITIONS event"
test_degradation_cli_flags() {
    if [ ! -f "$PRECONDITIONS_SCRIPT" ]; then
        assert_eq "preconditions-record.sh exists for degradation-flags test" "exists" "missing"
        return
    fi

    local repo
    repo=$(_make_test_repo)
    _init_tickets "$repo"

    # ── 5a: --degradation alone sets data.degradation=true ────────────────────
    local ticket_a="test-deg-a1"
    local exit_a=0
    (cd "$repo" && DSO_TICKETS_TRACKER_DIR="$repo/.tickets-tracker" bash "$PRECONDITIONS_SCRIPT" \
        --ticket-id "$ticket_a" \
        --gate-name "story_gate" \
        --session-id "sess-deg-a1" \
        --tier "standard" \
        --degradation) || exit_a=$?
    assert_eq "--degradation flag: exits zero" "0" "$exit_a"

    local event_a
    event_a=$(find "$repo/.tickets-tracker/$ticket_a" -name '*-PRECONDITIONS.json' -type f 2>/dev/null | head -1)
    if [ -z "$event_a" ]; then
        assert_eq "--degradation: event file written" "found" "not-found"
    else
        local check_a
        check_a=$(python3 -c "
import json, sys
with open(sys.argv[1], encoding='utf-8') as f:
    ev = json.load(f)
d = ev.get('data', {})
if d.get('degradation') is True:
    print('ok')
else:
    print('got:' + repr(d.get('degradation')))
" "$event_a" 2>/dev/null || echo "parse-error")
        assert_eq "--degradation sets data.degradation=true" "ok" "$check_a"
    fi

    # ── 5b: --degradation-type inferred_decision sets data.degradation_type ───
    local ticket_b="test-deg-b1"
    local exit_b=0
    (cd "$repo" && DSO_TICKETS_TRACKER_DIR="$repo/.tickets-tracker" bash "$PRECONDITIONS_SCRIPT" \
        --ticket-id "$ticket_b" \
        --gate-name "story_gate" \
        --session-id "sess-deg-b1" \
        --tier "standard" \
        --degradation-type "inferred_decision") || exit_b=$?
    assert_eq "--degradation-type flag: exits zero" "0" "$exit_b"

    local event_b
    event_b=$(find "$repo/.tickets-tracker/$ticket_b" -name '*-PRECONDITIONS.json' -type f 2>/dev/null | head -1)
    if [ -z "$event_b" ]; then
        assert_eq "--degradation-type: event file written" "found" "not-found"
    else
        local check_b
        check_b=$(python3 -c "
import json, sys
with open(sys.argv[1], encoding='utf-8') as f:
    ev = json.load(f)
d = ev.get('data', {})
if d.get('degradation_type') == 'inferred_decision':
    print('ok')
else:
    print('got:' + repr(d.get('degradation_type')))
" "$event_b" 2>/dev/null || echo "parse-error")
        assert_eq "--degradation-type sets data.degradation_type=inferred_decision" "ok" "$check_b"
    fi

    # ── 5c: both flags together → event has BOTH fields ────────────────────────
    local ticket_c="test-deg-c1"
    local exit_c=0
    (cd "$repo" && DSO_TICKETS_TRACKER_DIR="$repo/.tickets-tracker" bash "$PRECONDITIONS_SCRIPT" \
        --ticket-id "$ticket_c" \
        --gate-name "story_gate" \
        --session-id "sess-deg-c1" \
        --tier "standard" \
        --degradation \
        --degradation-type "unresolved_question") || exit_c=$?
    assert_eq "both flags: exits zero" "0" "$exit_c"

    local event_c
    event_c=$(find "$repo/.tickets-tracker/$ticket_c" -name '*-PRECONDITIONS.json' -type f 2>/dev/null | head -1)
    if [ -z "$event_c" ]; then
        assert_eq "both flags: event file written" "found" "not-found"
    else
        local check_c
        check_c=$(python3 -c "
import json, sys
with open(sys.argv[1], encoding='utf-8') as f:
    ev = json.load(f)
d = ev.get('data', {})
errors = []
if d.get('degradation') is not True:
    errors.append('degradation=' + repr(d.get('degradation')))
if d.get('degradation_type') != 'unresolved_question':
    errors.append('degradation_type=' + repr(d.get('degradation_type')))
print('ok' if not errors else 'FAIL:' + ';'.join(errors))
" "$event_c" 2>/dev/null || echo "parse-error")
        assert_eq "both flags: event has degradation=true AND degradation_type=unresolved_question" "ok" "$check_c"
    fi

    # ── 5d: --degradation-type invalid_value → exits 1 with error message ──────
    local exit_d=0
    local stderr_d
    stderr_d=$(cd "$repo" && DSO_TICKETS_TRACKER_DIR="$repo/.tickets-tracker" bash "$PRECONDITIONS_SCRIPT" \
        --ticket-id "test-deg-d1" \
        --gate-name "story_gate" \
        --session-id "sess-deg-d1" \
        --tier "standard" \
        --degradation-type "not_a_valid_value" 2>&1) || exit_d=$?
    assert_eq "--degradation-type invalid value: exits 1" "1" "$exit_d"
    local has_valid_values_msg
    has_valid_values_msg=$(echo "$stderr_d" | grep -ic "inferred_decision\|unresolved_question\|valid\|invalid" || true)
    assert_eq "--degradation-type invalid value: error lists valid values" "1" "$([ "${has_valid_values_msg:-0}" -gt 0 ] && echo 1 || echo 0)"

    # ── 5e: --data merged with --degradation-type (no overwrite) ──────────────
    local ticket_e="test-deg-e1"
    local exit_e=0
    (cd "$repo" && DSO_TICKETS_TRACKER_DIR="$repo/.tickets-tracker" bash "$PRECONDITIONS_SCRIPT" \
        --ticket-id "$ticket_e" \
        --gate-name "story_gate" \
        --session-id "sess-deg-e1" \
        --tier "standard" \
        --data '{"foo":"bar"}' \
        --degradation-type "inferred_decision") || exit_e=$?
    assert_eq "--data + --degradation-type: exits zero" "0" "$exit_e"

    local event_e
    event_e=$(find "$repo/.tickets-tracker/$ticket_e" -name '*-PRECONDITIONS.json' -type f 2>/dev/null | head -1)
    if [ -z "$event_e" ]; then
        assert_eq "--data + --degradation-type: event file written" "found" "not-found"
    else
        local check_e
        check_e=$(python3 -c "
import json, sys
with open(sys.argv[1], encoding='utf-8') as f:
    ev = json.load(f)
d = ev.get('data', {})
errors = []
if d.get('foo') != 'bar':
    errors.append('foo=' + repr(d.get('foo')))
if d.get('degradation_type') != 'inferred_decision':
    errors.append('degradation_type=' + repr(d.get('degradation_type')))
print('ok' if not errors else 'FAIL:' + ';'.join(errors))
" "$event_e" 2>/dev/null || echo "parse-error")
        assert_eq "--data + --degradation-type: both foo:bar AND degradation_type present (merge not overwrite)" "ok" "$check_e"
    fi
}
test_degradation_cli_flags

print_summary
