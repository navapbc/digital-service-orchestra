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

# ── Test 8: close reports newly unblocked ticket ──────────────────────────────
echo "Test 8: ticket A closed; stdout contains 'UNBLOCKED: <B>' when B was blocked only by A"
test_close_ticket_reports_newly_unblocked() {
    _snapshot_fail

    local repo
    repo=$(_make_test_repo)

    # Create ticket A (the one we will close)
    local ticket_a
    ticket_a=$(_create_ticket "$repo" task "Ticket A - to be closed")

    # Create ticket B (blocked only by A)
    local ticket_b
    ticket_b=$(_create_ticket "$repo" task "Ticket B - blocked by A")

    if [ -z "$ticket_a" ] || [ -z "$ticket_b" ]; then
        assert_eq "setup: both tickets created" "non-empty" "empty"
        assert_pass_if_clean "test_close_ticket_reports_newly_unblocked"
        return
    fi

    # Link: B depends_on A  (B is blocked by A)
    (cd "$repo" && bash "$TICKET_SCRIPT" link "$ticket_b" "$ticket_a" depends_on 2>/dev/null) || true

    # Transition A: open → closed; capture stdout
    local stdout_out
    local exit_code=0
    stdout_out=$(cd "$repo" && bash "$TICKET_SCRIPT" transition "$ticket_a" open closed 2>/dev/null) || exit_code=$?

    # Assert: transition exits 0
    assert_eq "unblocked-report: transition exits 0" "0" "$exit_code"

    # Assert: stdout contains 'UNBLOCKED: ' with ticket_b listed
    # RED: ticket-transition.sh does not call ticket-unblock.py yet → this will FAIL
    if echo "$stdout_out" | grep -qE "UNBLOCKED:.*$ticket_b"; then
        assert_eq "unblocked-report: stdout contains UNBLOCKED: <B>" "has-unblocked-B" "has-unblocked-B"
    else
        assert_eq "unblocked-report: stdout contains UNBLOCKED: <B>" "has-unblocked-B" "missing: $stdout_out"
    fi

    assert_pass_if_clean "test_close_ticket_reports_newly_unblocked"
}
test_close_ticket_reports_newly_unblocked

# ── Test 9: close reports 'UNBLOCKED: none' when no tickets are freed ─────────
echo "Test 9: ticket A closed with no dependent tickets; stdout contains 'UNBLOCKED: none'"
test_close_ticket_reports_no_unblocked() {
    _snapshot_fail

    local repo
    repo=$(_make_test_repo)

    # Create a lone ticket (no other tickets depend on it)
    local ticket_a
    ticket_a=$(_create_ticket "$repo" task "Lone ticket with no dependents")

    if [ -z "$ticket_a" ]; then
        assert_eq "setup: ticket created" "non-empty" "empty"
        assert_pass_if_clean "test_close_ticket_reports_no_unblocked"
        return
    fi

    # Transition A: open → closed; capture stdout
    local stdout_out
    local exit_code=0
    stdout_out=$(cd "$repo" && bash "$TICKET_SCRIPT" transition "$ticket_a" open closed 2>/dev/null) || exit_code=$?

    # Assert: transition exits 0
    assert_eq "no-unblocked: transition exits 0" "0" "$exit_code"

    # Assert: stdout contains 'UNBLOCKED: none'
    # RED: ticket-transition.sh does not emit UNBLOCKED output yet → this will FAIL
    if echo "$stdout_out" | grep -q "UNBLOCKED: none"; then
        assert_eq "no-unblocked: stdout contains UNBLOCKED: none" "has-none" "has-none"
    else
        assert_eq "no-unblocked: stdout contains UNBLOCKED: none" "has-none" "missing: $stdout_out"
    fi

    assert_pass_if_clean "test_close_ticket_reports_no_unblocked"
}
test_close_ticket_reports_no_unblocked

# ── Test 10: UNBLOCKED output only on close, not on other transitions ─────────
echo "Test 10: transition to in_progress does NOT emit 'UNBLOCKED:' in stdout"
test_close_ticket_unblocked_output_only_on_close() {
    _snapshot_fail

    local repo
    repo=$(_make_test_repo)

    local ticket_a
    ticket_a=$(_create_ticket "$repo" task "Ticket for in_progress transition")

    if [ -z "$ticket_a" ]; then
        assert_eq "setup: ticket created" "non-empty" "empty"
        assert_pass_if_clean "test_close_ticket_unblocked_output_only_on_close"
        return
    fi

    # Transition open → in_progress (NOT a close); capture stdout
    local stdout_out
    local exit_code=0
    stdout_out=$(cd "$repo" && bash "$TICKET_SCRIPT" transition "$ticket_a" open in_progress 2>/dev/null) || exit_code=$?

    # Assert: transition exits 0
    assert_eq "only-on-close: in_progress transition exits 0" "0" "$exit_code"

    # Assert: stdout does NOT contain 'UNBLOCKED:'
    # This test should PASS even before implementation (the script doesn't emit UNBLOCKED yet).
    # After implementation it must still pass (guard: only emit on close).
    if echo "$stdout_out" | grep -q "UNBLOCKED:"; then
        assert_eq "only-on-close: no UNBLOCKED in stdout for non-close transition" "no-unblocked" "has-unblocked: $stdout_out"
    else
        assert_eq "only-on-close: no UNBLOCKED in stdout for non-close transition" "no-unblocked" "no-unblocked"
    fi

    assert_pass_if_clean "test_close_ticket_unblocked_output_only_on_close"
}
test_close_ticket_unblocked_output_only_on_close

# ── Test 11: transition succeeds even if unblock detection fails ──────────────
echo "Test 11: transition exits 0 and emits stderr warning even if ticket-unblock.py is unavailable"
test_close_ticket_succeeds_even_if_unblock_fails() {
    _snapshot_fail

    local repo
    repo=$(_make_test_repo)

    local ticket_a
    ticket_a=$(_create_ticket "$repo" task "Ticket to close with broken unblock script")

    if [ -z "$ticket_a" ]; then
        assert_eq "setup: ticket created" "non-empty" "empty"
        assert_pass_if_clean "test_close_ticket_succeeds_even_if_unblock_fails"
        return
    fi

    # Simulate ticket-unblock.py being unavailable by pointing TRACKER_DIR to an
    # invalid path via a wrapper that overrides the unblock script invocation.
    # We do this by creating a broken ticket-unblock.py in a temp bin dir and
    # prepending it to PATH so it shadows the real one (if it exists).
    local fake_bin
    fake_bin=$(mktemp -d)
    _CLEANUP_DIRS+=("$fake_bin")
    # Write a broken ticket-unblock.py that always exits 1 with an error
    cat > "$fake_bin/ticket-unblock.py" <<'PYEOF'
import sys
print("simulated unblock failure", file=sys.stderr)
sys.exit(1)
PYEOF

    # Run transition with a modified environment: override UNBLOCK_SCRIPT if the
    # implementation uses it, otherwise pass an invalid tracker_dir suffix via env
    # so detect_newly_unblocked fails.
    # Strategy: set DSO_UNBLOCK_SCRIPT env to the broken script so ticket-transition.sh
    # uses it when calling ticket-unblock.py (the implementation should honor this).
    # RED: regardless of strategy, the test verifies exit 0 + stderr warning.
    local stdout_out stderr_out
    local exit_code=0
    stdout_out=$(cd "$repo" && DSO_UNBLOCK_SCRIPT="$fake_bin/ticket-unblock.py" \
        bash "$TICKET_SCRIPT" transition "$ticket_a" open closed 2>/tmp/test-unblock-fail-stderr-$$) || exit_code=$?
    stderr_out=$(cat /tmp/test-unblock-fail-stderr-$$ 2>/dev/null || true)
    rm -f /tmp/test-unblock-fail-stderr-$$

    # Assert: transition exits 0 (non-blocking — close succeeded even if unblock fails)
    # RED: current ticket-transition.sh doesn't call unblock at all → this assertion
    # will currently PASS. The test becomes meaningful after dso-f8xn implements
    # unblock calling with non-blocking error handling.
    assert_eq "unblock-fail: transition exits 0 (non-blocking)" "0" "$exit_code"

    # Assert: if unblock was attempted and failed, a warning appears on stderr.
    # RED: current implementation doesn't call unblock → no warning emitted.
    # After dso-f8xn: warning should appear when DSO_UNBLOCK_SCRIPT exits non-zero.
    # We can only assert on the warning presence AFTER implementation calls the script.
    # For now this assertion is the RED trigger: warn on stderr when unblock fails.
    # Note: this specific assertion fails RED only after dso-f8xn adds the call.
    # The exit-0 assertion above validates the non-blocking contract at GREEN time.
    #
    # Check if either: (a) a warning was emitted to stderr, OR (b) UNBLOCKED: none
    # appears in stdout (meaning unblock ran and returned no results — still valid).
    # If neither, the implementation hasn't added unblock support yet (RED for now).
    if echo "$stderr_out" | grep -qiE 'warn|unblock|fail|error' || \
       echo "$stdout_out" | grep -q "UNBLOCKED:"; then
        assert_eq "unblock-fail: stderr warning or UNBLOCKED output present (unblock called)" "unblock-called" "unblock-called"
    else
        # RED: unblock not called yet — this assertion fails until dso-f8xn is implemented
        assert_eq "unblock-fail: stderr warning or UNBLOCKED output present (unblock called)" "unblock-called" "not-called: stdout='$stdout_out' stderr='$stderr_out'"
    fi

    assert_pass_if_clean "test_close_ticket_succeeds_even_if_unblock_fails"
}
test_close_ticket_succeeds_even_if_unblock_fails

# ── Test 12 (RED): bug close requires --reason flag ───────────────────────────
echo "Test 12 (RED): closing a bug ticket without --reason exits non-zero"
test_transition_bug_close_requires_reason() {
    _snapshot_fail

    local repo
    repo=$(_make_test_repo)

    # Create a bug ticket
    local ticket_id
    ticket_id=$(_create_ticket "$repo" bug "Bug that needs a reason to close")

    if [ -z "$ticket_id" ]; then
        assert_eq "bug ticket created" "non-empty" "empty"
        assert_pass_if_clean "test_transition_bug_close_requires_reason"
        return
    fi

    # Attempt to close the bug WITHOUT --reason — must exit non-zero
    # RED: current ticket-transition.sh does not enforce this guard → exits 0
    local exit_code=0
    local stderr_out
    stderr_out=$(cd "$repo" && bash "$TICKET_SCRIPT" transition "$ticket_id" open closed 2>&1) || exit_code=$?

    # Assert: exits non-zero (guard not yet implemented → currently exits 0, so FAILS RED)
    assert_eq "bug-close-no-reason: exits non-zero" "1" "$([ "$exit_code" -ne 0 ] && echo 1 || echo 0)"

    # Assert: error message mentions '--reason' or 'reason' (guard feedback)
    if echo "$stderr_out" | grep -qiE 'reason|--reason'; then
        assert_eq "bug-close-no-reason: error mentions --reason" "has-reason-hint" "has-reason-hint"
    else
        assert_eq "bug-close-no-reason: error mentions --reason" "has-reason-hint" "no-hint: $stderr_out"
    fi

    assert_pass_if_clean "test_transition_bug_close_requires_reason"
}
test_transition_bug_close_requires_reason

# ── Test 13 (RED): bug close with --reason succeeds ──────────────────────────
echo "Test 13 (RED): closing a bug ticket WITH --reason exits 0"
test_transition_bug_close_with_reason_succeeds() {
    _snapshot_fail

    local repo
    repo=$(_make_test_repo)

    # Create a bug ticket
    local ticket_id
    ticket_id=$(_create_ticket "$repo" bug "Bug with a reason to close")

    if [ -z "$ticket_id" ]; then
        assert_eq "bug ticket created for reason-close test" "non-empty" "empty"
        assert_pass_if_clean "test_transition_bug_close_with_reason_succeeds"
        return
    fi

    # Close the bug WITH --reason — must exit 0
    # RED: current ticket-transition.sh does not accept --reason → may exit 0 for wrong reason
    # (it exits 0 because it doesn't validate, but after guard implementation it must only exit 0
    # when --reason is supplied). We verify the STATUS event is written to confirm it succeeded.
    local exit_code=0
    local stderr_out
    stderr_out=$(cd "$repo" && bash "$TICKET_SCRIPT" transition "$ticket_id" open closed --reason "Fixed in commit abc123" 2>&1) || exit_code=$?

    # Assert: exits 0
    assert_eq "bug-close-with-reason: exits 0" "0" "$exit_code"

    # Assert: a STATUS event for 'closed' was written (confirms the transition happened)
    local tracker_dir="$repo/.tickets-tracker"
    local status_count
    status_count=$(_count_status_events "$tracker_dir" "$ticket_id")
    assert_eq "bug-close-with-reason: STATUS event written" "1" "$status_count"

    # Assert: compiled status is now closed
    local compiled_status
    compiled_status=$(_get_ticket_status "$repo" "$ticket_id")
    assert_eq "bug-close-with-reason: compiled status is closed" "closed" "$compiled_status"

    assert_pass_if_clean "test_transition_bug_close_with_reason_succeeds"
}
test_transition_bug_close_with_reason_succeeds

# ── Test 14 (RED): close blocked by open children ─────────────────────────────
echo "Test 14 (RED): closing a ticket with open children exits non-zero"
test_transition_close_blocked_with_open_children() {
    _snapshot_fail

    local repo
    repo=$(_make_test_repo)

    # Create a parent epic ticket
    local parent_id
    parent_id=$(_create_ticket "$repo" epic "Epic with open children")

    if [ -z "$parent_id" ]; then
        assert_eq "parent epic ticket created" "non-empty" "empty"
        assert_pass_if_clean "test_transition_close_blocked_with_open_children"
        return
    fi

    # Create a child ticket under the parent
    local child_id
    child_id=$(cd "$repo" && bash "$TICKET_SCRIPT" create task "Open child task" --parent "$parent_id" 2>/dev/null) || true
    child_id=$(echo "$child_id" | tail -1)

    if [ -z "$child_id" ]; then
        # Child creation with --parent may not yet exist; this test should still fail RED
        # by detecting open children via ticket_find_open_children which won't be implemented yet.
        # If children can't be created, guard can't be triggered — assert failure to stay RED.
        assert_eq "child ticket created under parent" "non-empty" "empty"
        assert_pass_if_clean "test_transition_close_blocked_with_open_children"
        return
    fi

    # Attempt to close the parent epic while it has an open child — must exit non-zero
    # RED: current ticket-transition.sh does not check open children → exits 0
    local exit_code=0
    local stderr_out
    stderr_out=$(cd "$repo" && bash "$TICKET_SCRIPT" transition "$parent_id" open closed 2>&1) || exit_code=$?

    # Assert: exits non-zero (guard not yet implemented → currently exits 0, so FAILS RED)
    assert_eq "close-with-open-children: exits non-zero" "1" "$([ "$exit_code" -ne 0 ] && echo 1 || echo 0)"

    # Assert: error message mentions children or open tickets
    if echo "$stderr_out" | grep -qiE 'child|children|open|block'; then
        assert_eq "close-with-open-children: error mentions children" "has-children-hint" "has-children-hint"
    else
        assert_eq "close-with-open-children: error mentions children" "has-children-hint" "no-hint: $stderr_out"
    fi

    # Assert: the parent's status is still open (transition was blocked)
    local compiled_status
    compiled_status=$(_get_ticket_status "$repo" "$parent_id")
    assert_eq "close-with-open-children: parent status unchanged (still open)" "open" "$compiled_status"

    assert_pass_if_clean "test_transition_close_blocked_with_open_children"
}
test_transition_close_blocked_with_open_children

print_summary
