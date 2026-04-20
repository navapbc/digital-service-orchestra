#!/usr/bin/env bash
# tests/scripts/test-preconditions-baseline.sh
# RED tests for plugins/dso/scripts/preconditions-baseline-collect.sh (does NOT exist yet).
#
# Covers:
#   1. Script writes a PRECONDITIONS event with gate_name=restart_rate_baseline
#      for a given epic and session.
#   2. The restart_count value captured from ticket REPLAN_TRIGGER comment history
#      is included in the event data field.
#   3. Second invocation for the same (epic_id, session_id) produces a new
#      timestamped LWW entry — does not fail; latest wins at read time.
#
# All tests are expected to FAIL (RED phase) because the script does not exist.
#
# Usage: bash tests/scripts/test-preconditions-baseline.sh

# NOTE: -e is intentionally omitted — test functions return non-zero by design
# (they assert against unimplemented features). -e would abort the runner.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"
BASELINE_SCRIPT="$REPO_ROOT/plugins/dso/scripts/preconditions-baseline-collect.sh"
TICKET_SCRIPT="$REPO_ROOT/plugins/dso/scripts/ticket"

source "$REPO_ROOT/tests/lib/assert.sh"
source "$REPO_ROOT/tests/lib/git-fixtures.sh"

echo "=== test-preconditions-baseline.sh ==="

# ── Helper: create a fresh test repo with ticket system initialized ───────────
_make_ticket_repo() {
    local tmp
    tmp=$(mktemp -d)
    _CLEANUP_DIRS+=("$tmp")
    clone_test_repo "$tmp/repo"
    (cd "$tmp/repo" && _TICKET_TEST_NO_SYNC=1 bash "$TICKET_SCRIPT" init >/dev/null 2>&1) || true
    echo "$tmp/repo"
}

# ── Helper: write a minimal CREATE event for an epic ticket ───────────────────
# This lets the comment writer do a ghost-check pass without the real ticket CLI.
_write_epic_create_event() {
    local tracker_dir="$1"
    local ticket_id="$2"
    local ticket_dir="$tracker_dir/$ticket_id"
    mkdir -p "$ticket_dir"
    local env_id
    env_id=$(cat "$tracker_dir/.env-id" 2>/dev/null || echo "test-env-id")
    python3 -c "
import json, time, uuid, sys

ticket_dir = sys.argv[1]
ticket_id  = sys.argv[2]
env_id     = sys.argv[3]

ts = time.time_ns()
uid = str(uuid.uuid4())
event = {
    'timestamp': ts,
    'uuid': uid,
    'event_type': 'CREATE',
    'env_id': env_id,
    'author': 'test',
    'data': {
        'ticket_id':   ticket_id,
        'ticket_type': 'epic',
        'title':       'Test Epic',
        'status':      'open',
        'priority':    2,
    }
}
filename = f'{ts}-{uid}-CREATE.json'
with open(f'{ticket_dir}/{filename}', 'w', encoding='utf-8') as f:
    json.dump(event, f)
" "$ticket_dir" "$ticket_id" "$env_id"
}

# ── Helper: write a COMMENT event with a REPLAN_TRIGGER body ─────────────────
# Simulates what the sprint orchestrator writes when it re-plans mid-execution.
_write_replan_trigger_comment() {
    local tracker_dir="$1"
    local ticket_id="$2"
    local replan_type="${3:-drift}"
    local ticket_dir="$tracker_dir/$ticket_id"
    mkdir -p "$ticket_dir"
    local env_id
    env_id=$(cat "$tracker_dir/.env-id" 2>/dev/null || echo "test-env-id")
    python3 -c "
import json, time, uuid, sys

ticket_dir  = sys.argv[1]
ticket_id   = sys.argv[2]
env_id      = sys.argv[3]
replan_type = sys.argv[4]

ts = time.time_ns()
uid = str(uuid.uuid4())
event = {
    'timestamp': ts,
    'uuid': uid,
    'event_type': 'COMMENT',
    'env_id': env_id,
    'author': 'test',
    'data': {
        'body': f'REPLAN_TRIGGER: {replan_type} — simulated restart for baseline test'
    }
}
filename = f'{ts}-{uid}-COMMENT.json'
with open(f'{ticket_dir}/{filename}', 'w', encoding='utf-8') as f:
    json.dump(event, f)
" "$ticket_dir" "$ticket_id" "$env_id" "$replan_type"
}

# ── Test 1: script writes a PRECONDITIONS event with gate_name=restart_rate_baseline
echo "Test 1: preconditions-baseline-collect.sh writes a PRECONDITIONS event with gate_name=restart_rate_baseline"
test_baseline_collect_writes_preconditions() {
    if [ ! -f "$BASELINE_SCRIPT" ]; then
        assert_eq "preconditions-baseline-collect.sh exists" "exists" "missing"
        return
    fi

    local repo
    repo=$(_make_ticket_repo)

    local epic_id="epic-bl01"
    local session_id="sess-baseline-001"
    local tracker_dir="$repo/.tickets-tracker"

    # Create a minimal epic ticket (no REPLAN_TRIGGER comments — baseline of 0)
    _write_epic_create_event "$tracker_dir" "$epic_id"

    local exit_code=0
    (cd "$repo" && bash "$BASELINE_SCRIPT" "$epic_id" "$session_id") || exit_code=$?

    assert_eq "exits zero with valid args" "0" "$exit_code"

    # A PRECONDITIONS file must appear in the per-ticket event directory
    local ticket_dir="$tracker_dir/$epic_id"
    local file_count
    file_count=$(find "$ticket_dir" -name '*-PRECONDITIONS.json' -type f 2>/dev/null | wc -l | tr -d ' ')
    assert_eq "one PRECONDITIONS.json written to per-ticket event dir" "1" "$file_count"

    # gate_name must be restart_rate_baseline
    local event_file
    event_file=$(find "$ticket_dir" -name '*-PRECONDITIONS.json' -type f 2>/dev/null | head -1)
    if [ -z "$event_file" ]; then
        assert_eq "event file present for gate_name check" "found" "not-found"
        return
    fi

    local gate_name
    gate_name=$(python3 -c "
import json, sys
with open(sys.argv[1], encoding='utf-8') as f:
    d = json.load(f)
print(d.get('gate_name', 'missing'))
" "$event_file" 2>/dev/null || echo "parse-error")

    assert_eq "gate_name is restart_rate_baseline" "restart_rate_baseline" "$gate_name"

    # session_id must match what we passed
    local actual_session
    actual_session=$(python3 -c "
import json, sys
with open(sys.argv[1], encoding='utf-8') as f:
    d = json.load(f)
print(d.get('session_id', 'missing'))
" "$event_file" 2>/dev/null || echo "parse-error")

    assert_eq "session_id matches argument" "$session_id" "$actual_session"
}
test_baseline_collect_writes_preconditions

# ── Test 2: restart_count from REPLAN_TRIGGER history is in data field ─────────
echo "Test 2: restart_count captured from REPLAN_TRIGGER comment history is in the event data field"
test_baseline_collect_restart_count_in_data() {
    if [ ! -f "$BASELINE_SCRIPT" ]; then
        assert_eq "preconditions-baseline-collect.sh exists for restart_count test" "exists" "missing"
        return
    fi

    local repo
    repo=$(_make_ticket_repo)

    local epic_id="epic-bl02"
    local session_id="sess-baseline-002"
    local tracker_dir="$repo/.tickets-tracker"

    # Create the epic ticket and add two REPLAN_TRIGGER comments
    _write_epic_create_event "$tracker_dir" "$epic_id"
    _write_replan_trigger_comment "$tracker_dir" "$epic_id" "drift"
    _write_replan_trigger_comment "$tracker_dir" "$epic_id" "failure"

    local exit_code=0
    (cd "$repo" && bash "$BASELINE_SCRIPT" "$epic_id" "$session_id") || exit_code=$?

    assert_eq "exits zero with replan triggers present" "0" "$exit_code"

    local ticket_dir="$tracker_dir/$epic_id"
    local event_file
    event_file=$(find "$ticket_dir" -name '*-PRECONDITIONS.json' -type f 2>/dev/null | head -1)

    if [ -z "$event_file" ]; then
        assert_eq "event file present for restart_count check" "found" "not-found"
        return
    fi

    # data.restart_count must equal 2 (the number of REPLAN_TRIGGER comments written)
    local restart_count
    restart_count=$(python3 -c "
import json, sys
with open(sys.argv[1], encoding='utf-8') as f:
    d = json.load(f)
data = d.get('data', {})
# restart_count may be at top-level data key
print(data.get('restart_count', d.get('restart_count', 'missing')))
" "$event_file" 2>/dev/null || echo "parse-error")

    assert_eq "restart_count equals number of REPLAN_TRIGGER comments" "2" "$restart_count"

    # data.timestamp must be present and non-empty
    local has_timestamp
    has_timestamp=$(python3 -c "
import json, sys
with open(sys.argv[1], encoding='utf-8') as f:
    d = json.load(f)
data = d.get('data', {})
ts = data.get('timestamp', d.get('timestamp', ''))
print('present' if ts else 'missing')
" "$event_file" 2>/dev/null || echo "parse-error")

    assert_eq "data.timestamp is present" "present" "$has_timestamp"
}
test_baseline_collect_restart_count_in_data

# ── Test 3: second invocation produces a new LWW entry (does not fail) ─────────
echo "Test 3: second invocation for the same (epic_id, session_id) produces a new timestamped LWW entry"
test_baseline_collect_second_invocation_lww() {
    if [ ! -f "$BASELINE_SCRIPT" ]; then
        assert_eq "preconditions-baseline-collect.sh exists for LWW test" "exists" "missing"
        return
    fi

    local repo
    repo=$(_make_ticket_repo)

    local epic_id="epic-bl03"
    local session_id="sess-baseline-003"
    local tracker_dir="$repo/.tickets-tracker"

    # Create the epic ticket with no REPLAN_TRIGGER comments
    _write_epic_create_event "$tracker_dir" "$epic_id"

    # First invocation
    local exit_code_first=0
    (cd "$repo" && bash "$BASELINE_SCRIPT" "$epic_id" "$session_id") || exit_code_first=$?
    assert_eq "first invocation exits zero" "0" "$exit_code_first"

    # Small sleep to ensure the second invocation gets a distinct timestamp
    sleep 0.05

    # Second invocation — same args; must NOT fail
    local exit_code_second=0
    (cd "$repo" && bash "$BASELINE_SCRIPT" "$epic_id" "$session_id") || exit_code_second=$?
    assert_eq "second invocation exits zero (no error on repeated call)" "0" "$exit_code_second"

    # Two separate PRECONDITIONS files must exist (append-only; LWW at read time)
    local ticket_dir="$tracker_dir/$epic_id"
    local file_count
    file_count=$(find "$ticket_dir" -name '*-PRECONDITIONS.json' -type f 2>/dev/null | wc -l | tr -d ' ')
    assert_eq "two invocations produce two distinct PRECONDITIONS files" "2" "$file_count"

    # The two files must have distinct names
    if [ "$file_count" -ge 2 ]; then
        local files
        files=$(find "$ticket_dir" -name '*-PRECONDITIONS.json' -type f 2>/dev/null | sort)
        local first second
        first=$(echo "$files" | head -1)
        second=$(echo "$files" | tail -1)
        assert_ne "two PRECONDITIONS files have distinct names" "$first" "$second"
    fi
}
test_baseline_collect_second_invocation_lww

print_summary
