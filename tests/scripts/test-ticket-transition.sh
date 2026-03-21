#!/usr/bin/env bash
# tests/scripts/test-ticket-transition.sh
# RED tests for plugins/dso/scripts/ticket-transition.sh — `ticket transition` subcommand.
#
# All test functions MUST FAIL until ticket-transition.sh is implemented.
# Covers: optimistic concurrency rejection, ghost ticket prevention (no dir,
# no CREATE event), idempotent no-op, invalid target_status, concurrent safety,
# and flock serialization via write_commit_event.
#
# Usage: bash tests/scripts/test-ticket-transition.sh
# Returns: exit non-zero (RED) until ticket-transition.sh is implemented.

# NOTE: -e is intentionally omitted — test functions return non-zero by design
# (they assert against unimplemented features). -e would abort the runner.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"
TICKET_SCRIPT="$REPO_ROOT/plugins/dso/scripts/ticket"
TICKET_TRANSITION_SCRIPT="$REPO_ROOT/plugins/dso/scripts/ticket-transition.sh"

source "$REPO_ROOT/tests/lib/assert.sh"
source "$REPO_ROOT/tests/lib/git-fixtures.sh"

echo "=== test-ticket-transition.sh ==="

# ── Helper: create a fresh temp git repo with ticket system initialized ────────
_make_test_repo() {
    local tmp
    tmp=$(mktemp -d)
    _CLEANUP_DIRS+=("$tmp")
    clone_test_repo "$tmp/repo"
    (cd "$tmp/repo" && bash "$TICKET_SCRIPT" init >/dev/null 2>/dev/null) || true
    echo "$tmp/repo"
}

# ── Helper: create a ticket and return its ID ─────────────────────────────────
_create_ticket() {
    local repo="$1"
    local ticket_type="${2:-task}"
    local title="${3:-Test ticket}"
    local out
    out=$(cd "$repo" && bash "$TICKET_SCRIPT" create "$ticket_type" "$title" 2>/dev/null) || true
    echo "$out"
}

# ── Helper: count STATUS event files in a ticket directory ────────────────────
_count_status_events() {
    local tracker_dir="$1"
    local ticket_id="$2"
    find "$tracker_dir/$ticket_id" -maxdepth 1 -name '*-STATUS.json' ! -name '.*' 2>/dev/null | wc -l | tr -d ' '
}

# ── Helper: get compiled status from reducer ──────────────────────────────────
_get_ticket_status() {
    local repo="$1"
    local ticket_id="$2"
    local tracker_dir="$repo/.tickets-tracker"
    python3 "$REPO_ROOT/plugins/dso/scripts/ticket-reducer.py" "$tracker_dir/$ticket_id" 2>/dev/null \
        | python3 -c "import json,sys; d=json.loads(sys.stdin.read()); print(d.get('status',''))" 2>/dev/null || true
}

# ── Test 1: happy path — transition exits 0 and writes STATUS event ────────────
echo "Test 1: transition open->in_progress exits 0 and writes STATUS event with correct fields"
test_transition_happy_path() {
    _snapshot_fail

    # RED: ticket-transition.sh must not exist yet
    if [ ! -f "$TICKET_TRANSITION_SCRIPT" ]; then
        assert_eq "ticket-transition.sh exists" "exists" "missing"
        assert_pass_if_clean "test_transition_happy_path"
        return
    fi

    local repo
    repo=$(_make_test_repo)
    local ticket_id
    ticket_id=$(_create_ticket "$repo" task "Happy path ticket")

    if [ -z "$ticket_id" ]; then
        assert_eq "happy path: create returned ticket ID" "non-empty" "empty"
        return
    fi

    local tracker_dir="$repo/.tickets-tracker"

    # Record STATUS event count before
    local before_count
    before_count=$(_count_status_events "$tracker_dir" "$ticket_id")

    # Run transition: open → in_progress
    local exit_code=0
    (cd "$repo" && bash "$TICKET_SCRIPT" transition "$ticket_id" open in_progress 2>/dev/null) || exit_code=$?
    assert_eq "happy path: transition exits 0" "0" "$exit_code"

    # Assert: exactly one new STATUS event was written
    local after_count
    after_count=$(_count_status_events "$tracker_dir" "$ticket_id")
    local new_events
    new_events=$(( after_count - before_count ))
    assert_eq "happy path: exactly one STATUS event written" "1" "$new_events"

    # Assert: STATUS event JSON contains required fields
    local status_file
    status_file=$(find "$tracker_dir/$ticket_id" -maxdepth 1 -name '*-STATUS.json' ! -name '.*' 2>/dev/null | sort | tail -1)

    if [ -z "$status_file" ]; then
        assert_eq "happy path: STATUS event file found" "found" "not-found"
        assert_pass_if_clean "test_transition_happy_path"
        return
    fi

    local field_check
    field_check=$(python3 - "$status_file" <<'PYEOF'
import json, sys
try:
    with open(sys.argv[1], encoding='utf-8') as f:
        ev = json.load(f)
except Exception as e:
    print(f"PARSE_ERROR:{e}")
    sys.exit(1)

errors = []

# Base schema
if not isinstance(ev.get('timestamp'), int):
    errors.append(f"timestamp not int: {type(ev.get('timestamp'))}")
if not isinstance(ev.get('uuid'), str) or not ev.get('uuid'):
    errors.append(f"uuid missing or not str: {ev.get('uuid')!r}")
if ev.get('event_type') != 'STATUS':
    errors.append(f"event_type not STATUS: {ev.get('event_type')!r}")
if not isinstance(ev.get('env_id'), str) or not ev.get('env_id'):
    errors.append(f"env_id missing or not str: {ev.get('env_id')!r}")
if not isinstance(ev.get('author'), str) or not ev.get('author'):
    errors.append(f"author missing or not str: {ev.get('author')!r}")

# STATUS-specific data fields
data = ev.get('data', {})
if not isinstance(data, dict):
    errors.append(f"data not dict: {type(data)}")
else:
    if data.get('status') != 'in_progress':
        errors.append(f"data.status not in_progress: {data.get('status')!r}")
    if data.get('current_status') != 'open':
        errors.append(f"data.current_status not open: {data.get('current_status')!r}")

if errors:
    print("ERRORS:" + "; ".join(errors))
    sys.exit(2)
else:
    print("OK")
PYEOF
) || true

    if [ "$field_check" = "OK" ]; then
        assert_eq "happy path: STATUS event has correct fields" "OK" "OK"
    else
        assert_eq "happy path: STATUS event has correct fields" "OK" "$field_check"
    fi

    # Assert: compiled status updated to in_progress
    local compiled_status
    compiled_status=$(_get_ticket_status "$repo" "$ticket_id")
    assert_eq "happy path: compiled status is in_progress" "in_progress" "$compiled_status"

    assert_pass_if_clean "test_transition_happy_path"
}
test_transition_happy_path

# ── Test 2: optimistic concurrency rejection — wrong current_status ────────────
echo "Test 2: transition rejected when current_status does not match actual status"
test_transition_optimistic_concurrency_rejection() {
    _snapshot_fail

    # RED: ticket-transition.sh must not exist yet
    if [ ! -f "$TICKET_TRANSITION_SCRIPT" ]; then
        assert_eq "ticket-transition.sh exists" "exists" "missing"
        assert_pass_if_clean "test_transition_optimistic_concurrency_rejection"
        return
    fi

    local repo
    repo=$(_make_test_repo)
    local ticket_id
    ticket_id=$(_create_ticket "$repo" task "Concurrency test ticket")

    if [ -z "$ticket_id" ]; then
        assert_eq "concurrency: create returned ticket ID" "non-empty" "empty"
        return
    fi

    local tracker_dir="$repo/.tickets-tracker"

    # Actual status is open; claim it is in_progress (wrong)
    local exit_code=0
    local stderr_out
    stderr_out=$(cd "$repo" && bash "$TICKET_SCRIPT" transition "$ticket_id" in_progress closed 2>&1) || exit_code=$?

    # Assert: exits non-zero
    assert_eq "concurrency: wrong current_status exits non-zero" "1" "$([ "$exit_code" -ne 0 ] && echo 1 || echo 0)"

    # Assert: stderr mentions the actual status
    if echo "$stderr_out" | grep -qE 'open|actual|current'; then
        assert_eq "concurrency: error output mentions actual status" "has-status-info" "has-status-info"
    else
        assert_eq "concurrency: error output mentions actual status" "has-status-info" "no-status-info: $stderr_out"
    fi

    # Assert: NO STATUS event was written
    local status_count
    status_count=$(_count_status_events "$tracker_dir" "$ticket_id")
    assert_eq "concurrency: no STATUS event written on rejection" "0" "$status_count"

    assert_pass_if_clean "test_transition_optimistic_concurrency_rejection"
}
test_transition_optimistic_concurrency_rejection

# ── Test 3: ghost prevention — non-existent ticket directory ──────────────────
echo "Test 3: transition on a non-existent ticket ID fails with clear error"
test_transition_ghost_prevention_no_dir() {
    _snapshot_fail

    # RED: ticket-transition.sh must not exist yet
    if [ ! -f "$TICKET_TRANSITION_SCRIPT" ]; then
        assert_eq "ticket-transition.sh exists" "exists" "missing"
        assert_pass_if_clean "test_transition_ghost_prevention_no_dir"
        return
    fi

    local repo
    repo=$(_make_test_repo)

    local fake_id="xxxx-0000"
    local exit_code=0
    local stderr_out
    stderr_out=$(cd "$repo" && bash "$TICKET_SCRIPT" transition "$fake_id" open in_progress 2>&1) || exit_code=$?

    # Assert: exits non-zero
    assert_eq "ghost-no-dir: exits non-zero for missing ticket" "1" "$([ "$exit_code" -ne 0 ] && echo 1 || echo 0)"

    # Assert: error message is printed (not silent)
    if [ -n "$stderr_out" ]; then
        assert_eq "ghost-no-dir: error message printed" "has-message" "has-message"
    else
        assert_eq "ghost-no-dir: error message printed" "has-message" "silent"
    fi

    assert_pass_if_clean "test_transition_ghost_prevention_no_dir"
}
test_transition_ghost_prevention_no_dir

# ── Test 4: ghost prevention — ticket dir exists but has no CREATE event ───────
echo "Test 4: transition on a ticket dir with no CREATE event fails with clear error"
test_transition_ghost_prevention_no_create_event() {
    _snapshot_fail

    # RED: ticket-transition.sh must not exist yet
    if [ ! -f "$TICKET_TRANSITION_SCRIPT" ]; then
        assert_eq "ticket-transition.sh exists" "exists" "missing"
        assert_pass_if_clean "test_transition_ghost_prevention_no_create_event"
        return
    fi

    local repo
    repo=$(_make_test_repo)
    local tracker_dir="$repo/.tickets-tracker"

    # Manually create a ticket dir without a CREATE event (ghost ticket)
    local ghost_id="ghost-0001"
    mkdir -p "$tracker_dir/$ghost_id"

    local exit_code=0
    local stderr_out
    stderr_out=$(cd "$repo" && bash "$TICKET_SCRIPT" transition "$ghost_id" open in_progress 2>&1) || exit_code=$?

    # Assert: exits non-zero
    assert_eq "ghost-no-create: exits non-zero" "1" "$([ "$exit_code" -ne 0 ] && echo 1 || echo 0)"

    # Assert: error message is printed
    if [ -n "$stderr_out" ]; then
        assert_eq "ghost-no-create: error message printed" "has-message" "has-message"
    else
        assert_eq "ghost-no-create: error message printed" "has-message" "silent"
    fi

    # Assert: no STATUS event written
    local status_count
    status_count=$(_count_status_events "$tracker_dir" "$ghost_id")
    assert_eq "ghost-no-create: no STATUS event written" "0" "$status_count"

    assert_pass_if_clean "test_transition_ghost_prevention_no_create_event"
}
test_transition_ghost_prevention_no_create_event

# ── Test 5: idempotent no-op — current equals target status ───────────────────
echo "Test 5: transition open->open is a no-op (exits 0, no new STATUS event written)"
test_transition_idempotent_noop() {
    _snapshot_fail

    # RED: ticket-transition.sh must not exist yet
    if [ ! -f "$TICKET_TRANSITION_SCRIPT" ]; then
        assert_eq "ticket-transition.sh exists" "exists" "missing"
        assert_pass_if_clean "test_transition_idempotent_noop"
        return
    fi

    local repo
    repo=$(_make_test_repo)
    local ticket_id
    ticket_id=$(_create_ticket "$repo" task "Idempotent no-op ticket")

    if [ -z "$ticket_id" ]; then
        assert_eq "noop: create returned ticket ID" "non-empty" "empty"
        return
    fi

    local tracker_dir="$repo/.tickets-tracker"

    # Transition open → open (same status)
    local exit_code=0
    (cd "$repo" && bash "$TICKET_SCRIPT" transition "$ticket_id" open open 2>/dev/null) || exit_code=$?

    # Assert: exits 0
    assert_eq "noop: transition exits 0" "0" "$exit_code"

    # Assert: NO new STATUS event written
    local status_count
    status_count=$(_count_status_events "$tracker_dir" "$ticket_id")
    assert_eq "noop: no STATUS event written" "0" "$status_count"

    assert_pass_if_clean "test_transition_idempotent_noop"
}
test_transition_idempotent_noop

# ── Test 6: invalid target_status — rejected with error ───────────────────────
echo "Test 6: transition with invalid target_status exits non-zero with error"
test_transition_invalid_target_status() {
    _snapshot_fail

    # RED: ticket-transition.sh must not exist yet
    if [ ! -f "$TICKET_TRANSITION_SCRIPT" ]; then
        assert_eq "ticket-transition.sh exists" "exists" "missing"
        assert_pass_if_clean "test_transition_invalid_target_status"
        return
    fi

    local repo
    repo=$(_make_test_repo)
    local ticket_id
    ticket_id=$(_create_ticket "$repo" task "Invalid status ticket")

    if [ -z "$ticket_id" ]; then
        assert_eq "invalid-status: create returned ticket ID" "non-empty" "empty"
        return
    fi

    local tracker_dir="$repo/.tickets-tracker"

    local exit_code=0
    local stderr_out
    stderr_out=$(cd "$repo" && bash "$TICKET_SCRIPT" transition "$ticket_id" open invalid_status 2>&1) || exit_code=$?

    # Assert: exits non-zero
    assert_eq "invalid-status: exits non-zero" "1" "$([ "$exit_code" -ne 0 ] && echo 1 || echo 0)"

    # Assert: error message mentions the invalid status or valid values
    if echo "$stderr_out" | grep -qiE 'invalid|status|open|in_progress|closed|blocked'; then
        assert_eq "invalid-status: error message mentions status info" "has-status-info" "has-status-info"
    else
        assert_eq "invalid-status: error message mentions status info" "has-status-info" "no-status-info: $stderr_out"
    fi

    # Assert: no STATUS event written on invalid status
    local status_count
    status_count=$(_count_status_events "$tracker_dir" "$ticket_id")
    assert_eq "invalid-status: no STATUS event written" "0" "$status_count"

    assert_pass_if_clean "test_transition_invalid_target_status"
}
test_transition_invalid_target_status

# ── Test 7: concurrent safety — two transitions; at most one succeeds ──────────
echo "Test 7: two concurrent transitions on same ticket; at most one succeeds, no corrupt events"
test_transition_concurrent_safety() {
    _snapshot_fail

    # RED: ticket-transition.sh must not exist yet
    if [ ! -f "$TICKET_TRANSITION_SCRIPT" ]; then
        assert_eq "ticket-transition.sh exists" "exists" "missing"
        assert_pass_if_clean "test_transition_concurrent_safety"
        return
    fi

    local repo
    repo=$(_make_test_repo)
    local ticket_id
    ticket_id=$(_create_ticket "$repo" task "Concurrent transition ticket")

    if [ -z "$ticket_id" ]; then
        assert_eq "concurrent: create returned ticket ID" "non-empty" "empty"
        return
    fi

    local tracker_dir="$repo/.tickets-tracker"
    local tmp_out_dir
    tmp_out_dir=$(mktemp -d)
    _CLEANUP_DIRS+=("$tmp_out_dir")

    # Launch two concurrent transitions from the same starting status (open)
    # Both claim current=open; only one can write the STATUS event atomically
    local exit1=0 exit2=0
    (cd "$repo" && bash "$TICKET_SCRIPT" transition "$ticket_id" open in_progress >"$tmp_out_dir/out1" 2>"$tmp_out_dir/err1") &
    local pid1=$!
    (cd "$repo" && bash "$TICKET_SCRIPT" transition "$ticket_id" open closed >"$tmp_out_dir/out2" 2>"$tmp_out_dir/err2") &
    local pid2=$!

    wait "$pid1" || exit1=$?
    wait "$pid2" || exit2=$?

    # Assert: at most one exited 0 (one or both may succeed — but no corruption)
    local success_count=0
    [ "$exit1" -eq 0 ] && success_count=$((success_count + 1))
    [ "$exit2" -eq 0 ] && success_count=$((success_count + 1))

    if [ "$success_count" -le 1 ]; then
        assert_eq "concurrent: at most one transition succeeds" "at-most-1" "at-most-1"
    else
        assert_eq "concurrent: at most one transition succeeds" "at-most-1" "both-succeeded"
    fi

    # Assert: at most one STATUS event written (zero or one — matches 'at most one succeeds' invariant)
    local status_count
    status_count=$(_count_status_events "$tracker_dir" "$ticket_id")
    if [ "$status_count" -le 1 ]; then
        assert_eq "concurrent: at most one STATUS event written" "at-most-1" "at-most-1"
    else
        assert_eq "concurrent: at most one STATUS event written" "at-most-1" "$status_count-events"
    fi

    # Assert: the STATUS event file is valid JSON (no corruption), if present
    local status_file
    status_file=$(find "$tracker_dir/$ticket_id" -maxdepth 1 -name '*-STATUS.json' ! -name '.*' 2>/dev/null | head -1)

    if [ -n "$status_file" ]; then
        local parse_exit=0
        python3 -c "import json,sys; json.load(sys.stdin)" < "$status_file" 2>/dev/null || parse_exit=$?
        assert_eq "concurrent: STATUS event is valid JSON (no corruption)" "0" "$parse_exit"
    fi
    # If no STATUS event was written (both concurrent transitions rejected each other),
    # that is also a valid outcome — no assertion needed in the empty case.

    assert_pass_if_clean "test_transition_concurrent_safety"
}
test_transition_concurrent_safety

print_summary
