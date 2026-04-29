#!/usr/bin/env bash
# tests/acceptance/test-ticket-delete-e2e.sh
# E2E acceptance tests for the full ticket delete lifecycle.
#
# GREEN tests — these must PASS because ticket delete is already implemented.
# Covers: --user-approved guard, children-block deletion, list visibility,
# --include-archived visibility, ready_to_work unblocking after delete,
# transitioning a deleted ticket exits non-zero, archived==True in compiled
# state, parent epic closure with mixed closed+deleted children, and bridge
# routing verification (delete call, not status-transition).
#
# Usage: bash tests/acceptance/test-ticket-delete-e2e.sh

# NOTE: -e is intentionally omitted — assertion helpers and early-return guards
# use non-zero returns by design. -e would abort the runner.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"
TICKET_SCRIPT="$REPO_ROOT/plugins/dso/scripts/ticket"

source "$REPO_ROOT/tests/lib/assert.sh"
source "$REPO_ROOT/tests/lib/git-fixtures.sh"

echo "=== test-ticket-delete-e2e.sh ==="

# ── Helper: create a fresh ticket-enabled repo ────────────────────────────────
_make_test_repo() {
    local tmp
    tmp=$(mktemp -d)
    _CLEANUP_DIRS+=("$tmp")
    clone_ticket_repo "$tmp/repo"
    echo "$tmp/repo"
}

# ── Helper: create a ticket and return its ID ─────────────────────────────────
_create_ticket() {
    local repo="$1"
    local ticket_type="${2:-task}"
    local title="${3:-Test ticket}"
    local extra_args="${4:-}"
    local out
    # shellcheck disable=SC2086
    out=$(cd "$repo" && bash "$TICKET_SCRIPT" create "$ticket_type" "$title" $extra_args 2>/dev/null) || true
    echo "$out" | tail -1
}

# ── Helper: extract a JSON field from `ticket deps` output ───────────────────
_deps_field() {
    local repo="$1"
    local ticket_id="$2"
    local field="$3"
    local output
    output=$(cd "$repo" && bash "$TICKET_SCRIPT" deps "$ticket_id" 2>/dev/null) || output=""
    python3 -c "
import json, sys
try:
    d = json.loads(sys.argv[1])
    val = d.get(sys.argv[2])
    print(str(val).lower() if isinstance(val, bool) else (str(val) if val is not None else ''))
except Exception:
    print('')
" "$output" "$field" 2>/dev/null || true
}

# ── Helper: extract a field from `ticket show` output ────────────────────────
_show_field() {
    local repo="$1"
    local ticket_id="$2"
    local field="$3"
    local show_output
    show_output=$(cd "$repo" && bash "$TICKET_SCRIPT" show "$ticket_id" 2>/dev/null) || show_output=""
    python3 -c "
import json, sys
try:
    d = json.loads(sys.argv[1])
    val = d.get(sys.argv[2])
    print(str(val).lower() if isinstance(val, bool) else (str(val) if val is not None else ''))
except Exception:
    print('')
" "$show_output" "$field" 2>/dev/null || true
}

# ─────────────────────────────────────────────────────────────────────────────
# Test 1: Full lifecycle — epic with two child stories, delete one after closing
# the other; verifies status:deleted, archived:true, blocker removal, list
# visibility, transition rejection, and parent epic closure.
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "Test E2E-1: full lifecycle (epic+2 children, close one, delete other → parent closes)"
test_full_delete_lifecycle() {
    _snapshot_fail

    local repo
    repo=$(_make_test_repo)

    # Create epic E and two child stories S1, S2
    local epic_id s1_id s2_id
    epic_id=$(_create_ticket "$repo" epic "Parent epic")

    if [ -z "$epic_id" ]; then
        assert_eq "epic created" "non-empty" "empty"
        assert_pass_if_clean "test_full_delete_lifecycle"
        return
    fi

    s1_id=$(_create_ticket "$repo" story "Child story one" "--parent $epic_id")
    s2_id=$(_create_ticket "$repo" story "Child story two" "--parent $epic_id")

    if [ -z "$s1_id" ] || [ -z "$s2_id" ]; then
        assert_eq "both child stories created" "non-empty" "empty"
        assert_pass_if_clean "test_full_delete_lifecycle"
        return
    fi

    # Transition S1 to closed (so we have one closed + one open child)
    local close_exit=0
    (cd "$repo" && bash "$TICKET_SCRIPT" transition "$s1_id" open closed >/dev/null 2>&1) || close_exit=$?
    assert_eq "transition S1 to closed exits 0" "0" "$close_exit"

    # Delete S2 with --user-approved
    local delete_exit=0
    (cd "$repo" && bash "$TICKET_SCRIPT" delete "$s2_id" --user-approved >/dev/null 2>&1) || delete_exit=$?
    assert_eq "delete S2 exits 0" "0" "$delete_exit"

    # ticket show S2 should return status:deleted
    local status_val
    status_val=$(_show_field "$repo" "$s2_id" "status")
    assert_eq "ticket show returns status:deleted" "deleted" "$status_val"

    # ticket show S2 should return archived:true
    local archived_val
    archived_val=$(_show_field "$repo" "$s2_id" "archived")
    assert_eq "ticket show returns archived:true" "true" "$archived_val"

    # ticket list should NOT include S2 (deleted tickets excluded by default)
    local list_after
    list_after=$(cd "$repo" && bash "$TICKET_SCRIPT" list 2>/dev/null) || list_after=""
    local still_present=0
    [[ "$list_after" == *"$s2_id"* ]] && still_present=1
    assert_eq "deleted ticket absent from ticket list" "0" "$still_present"

    # Transitioning a deleted ticket should fail (deleted is terminal)
    local transition_exit=0
    (cd "$repo" && bash "$TICKET_SCRIPT" transition "$s2_id" deleted closed >/dev/null 2>&1) || transition_exit=$?
    assert_ne "transition deleted→closed exits non-zero" "0" "$transition_exit"

    # Parent epic should be closeable with one closed + one deleted child
    local epic_close_exit=0
    (cd "$repo" && bash "$TICKET_SCRIPT" transition "$epic_id" open closed >/dev/null 2>&1) || epic_close_exit=$?
    assert_eq "parent epic closes with mixed closed+deleted children" "0" "$epic_close_exit"

    assert_pass_if_clean "test_full_delete_lifecycle"
}
test_full_delete_lifecycle

# ─────────────────────────────────────────────────────────────────────────────
# Test 2: Deleting a blocker sets ready_to_work=true on the dependent ticket
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "Test E2E-2: deleting a blocker unblocks dependent (ready_to_work=true)"
test_delete_clears_blocker() {
    _snapshot_fail

    local repo
    repo=$(_make_test_repo)

    local tkt_a tkt_d
    tkt_a=$(_create_ticket "$repo" task "Blocking task A")
    tkt_d=$(_create_ticket "$repo" task "Dependent task D")

    if [ -z "$tkt_a" ] || [ -z "$tkt_d" ]; then
        assert_eq "both tickets created" "non-empty" "empty"
        assert_pass_if_clean "test_delete_clears_blocker"
        return
    fi

    # Link A blocks D
    local link_exit=0
    (cd "$repo" && bash "$TICKET_SCRIPT" link "$tkt_a" "$tkt_d" blocks >/dev/null 2>&1) || link_exit=$?
    assert_eq "link A blocks D exits 0" "0" "$link_exit"

    # D should NOT be ready_to_work before delete
    local rtw_before
    rtw_before=$(_deps_field "$repo" "$tkt_d" "ready_to_work")
    assert_eq "D not ready_to_work before delete" "false" "$rtw_before"

    # Delete A
    local delete_exit=0
    (cd "$repo" && bash "$TICKET_SCRIPT" delete "$tkt_a" --user-approved >/dev/null 2>&1) || delete_exit=$?
    assert_eq "delete A exits 0" "0" "$delete_exit"

    # D should now be ready_to_work=true
    local rtw_after
    rtw_after=$(_deps_field "$repo" "$tkt_d" "ready_to_work")
    assert_eq "D ready_to_work=true after blocker deleted" "true" "$rtw_after"

    assert_pass_if_clean "test_delete_clears_blocker"
}
test_delete_clears_blocker

# ─────────────────────────────────────────────────────────────────────────────
# Test 3: Children block deletion
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "Test E2E-3: children block deletion"
test_children_block_deletion() {
    _snapshot_fail

    local repo
    repo=$(_make_test_repo)

    local parent_id child_id
    parent_id=$(_create_ticket "$repo" epic "Epic with children")

    if [ -z "$parent_id" ]; then
        assert_eq "parent epic created" "non-empty" "empty"
        assert_pass_if_clean "test_children_block_deletion"
        return
    fi

    child_id=$(_create_ticket "$repo" story "Child story" "--parent $parent_id")

    if [ -z "$child_id" ]; then
        assert_eq "child story created" "non-empty" "empty"
        assert_pass_if_clean "test_children_block_deletion"
        return
    fi

    # Attempt to delete the parent — should be blocked
    local exit_code=0
    local combined_output
    combined_output=$(cd "$repo" && bash "$TICKET_SCRIPT" delete "$parent_id" --user-approved 2>&1) || exit_code=$?

    assert_ne "delete with children exits non-zero" "0" "$exit_code"
    assert_contains "output contains child ticket ID" "$child_id" "$combined_output"

    assert_pass_if_clean "test_children_block_deletion"
}
test_children_block_deletion

# ─────────────────────────────────────────────────────────────────────────────
# Test 4: Delete without --user-approved is rejected
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "Test E2E-4: delete without --user-approved exits non-zero with usage hint"
test_delete_requires_user_approved() {
    _snapshot_fail

    local repo
    repo=$(_make_test_repo)

    local ticket_id
    ticket_id=$(_create_ticket "$repo" task "Guard flag test")

    if [ -z "$ticket_id" ]; then
        assert_eq "ticket created for guard flag test" "non-empty" "empty"
        assert_pass_if_clean "test_delete_requires_user_approved"
        return
    fi

    local exit_code=0
    local combined_output
    combined_output=$(cd "$repo" && bash "$TICKET_SCRIPT" delete "$ticket_id" 2>&1) || exit_code=$?

    assert_ne "delete without --user-approved exits non-zero" "0" "$exit_code"
    assert_contains "output mentions --user-approved" "--user-approved" "$combined_output"

    assert_pass_if_clean "test_delete_requires_user_approved"
}
test_delete_requires_user_approved

# ─────────────────────────────────────────────────────────────────────────────
# Test 5: Deleted ticket absent from list; present with --include-archived
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "Test E2E-5: deleted ticket absent from list, present with --include-archived"
test_delete_list_visibility() {
    _snapshot_fail

    local repo
    repo=$(_make_test_repo)

    local ticket_id
    ticket_id=$(_create_ticket "$repo" task "Ticket for visibility test")

    if [ -z "$ticket_id" ]; then
        assert_eq "ticket created for visibility test" "non-empty" "empty"
        assert_pass_if_clean "test_delete_list_visibility"
        return
    fi

    # Confirm it's visible before deletion
    local list_before
    list_before=$(cd "$repo" && bash "$TICKET_SCRIPT" list 2>/dev/null) || list_before=""
    assert_contains "ticket visible before delete" "$ticket_id" "$list_before"

    # Delete the ticket
    local delete_exit=0
    (cd "$repo" && bash "$TICKET_SCRIPT" delete "$ticket_id" --user-approved >/dev/null 2>&1) || delete_exit=$?
    assert_eq "delete exits 0" "0" "$delete_exit"

    # Should NOT appear in default list
    local list_after
    list_after=$(cd "$repo" && bash "$TICKET_SCRIPT" list 2>/dev/null) || list_after=""
    local present_default=0
    [[ "$list_after" == *"$ticket_id"* ]] && present_default=1
    assert_eq "deleted ticket absent from default list" "0" "$present_default"

    # SHOULD appear in --include-archived list
    local list_archived
    list_archived=$(cd "$repo" && bash "$TICKET_SCRIPT" list --include-archived 2>/dev/null) || list_archived=""
    assert_contains "deleted ticket present in --include-archived list" "$ticket_id" "$list_archived"

    assert_pass_if_clean "test_delete_list_visibility"
}
test_delete_list_visibility

# ─────────────────────────────────────────────────────────────────────────────
# Test 6: Bridge outbound routes deleted status to delete_issue, not update_issue
#
# Verifies that bridge-outbound._outbound_handlers.handle_status_event intercepts
# compiled_status=="deleted" and calls delete_issue (not update_issue/transition).
# Uses Python unittest.mock to assert the routing without real ACLI calls.
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "Test E2E-6: bridge outbound routes deleted status to delete_issue (not update_issue)"
test_bridge_routes_deleted_to_delete_issue() {
    _snapshot_fail

    # Write the test script to a temp file (avoids heredoc-in-subshell issues)
    local py_script exit_code py_output
    py_script=$(mktemp /tmp/bridge-routing-test-XXXXXX.py)
    cat > "$py_script" << 'PYEOF'
import sys, os, json, tempfile, shutil
from unittest.mock import MagicMock
from pathlib import Path

repo_root = sys.argv[1]
sys.path.insert(0, os.path.join(repo_root, 'plugins', 'dso', 'scripts'))
sys.path.insert(0, os.path.join(repo_root, 'plugins', 'dso', 'scripts', 'bridge'))

tmpdir = tempfile.mkdtemp()
try:
    tracker_dir = Path(tmpdir) / '.tickets-tracker'
    ticket_id = 'test-del-0001'
    ticket_dir = tracker_dir / ticket_id
    ticket_dir.mkdir(parents=True)

    env_id = 'test-env'
    (tracker_dir / '.env-id').write_text(env_id)

    import time, uuid as _uuid
    base_ts = time.time_ns()

    # CREATE event first (reducer returns None without it)
    create_ts = base_ts - 2
    create_ev = str(_uuid.uuid4())
    (ticket_dir / f'{create_ts}-{create_ev}-CREATE.json').write_text(json.dumps({
        'event_type': 'CREATE', 'timestamp': create_ts, 'uuid': create_ev,
        'env_id': env_id, 'author': 'test',
        'data': {'ticket_type': 'task', 'title': 'test ticket', 'ticket_id': ticket_id}
    }))

    ts = base_ts
    ev = str(_uuid.uuid4())

    # Write STATUS event with status=deleted
    (ticket_dir / f'{ts}-{ev}-STATUS.json').write_text(json.dumps({
        'event_type': 'STATUS', 'timestamp': ts, 'uuid': ev,
        'env_id': env_id, 'author': 'test',
        'data': {'status': 'deleted', 'ticket_id': ticket_id}
    }))

    # Write SYNC file so bridge knows the Jira key (jira_key at top level per write_sync_event)
    sync_ts = ts - 1
    sync_ev = str(_uuid.uuid4())
    (ticket_dir / f'{sync_ts}-{sync_ev}-SYNC.json').write_text(json.dumps({
        'event_type': 'SYNC', 'timestamp': sync_ts, 'uuid': sync_ev,
        'env_id': env_id, 'local_id': ticket_id,
        'jira_key': 'TEST-42', 'jira_project': 'TEST'
    }))

    from _outbound_handlers import handle_status_event

    mock_client = MagicMock()
    mock_client.delete_issue.return_value = {'status': 'deleted', 'key': 'TEST-42'}

    status_updated = set()

    # event dict matches what bridge-outbound.py passes to handle_status_event
    event = {
        'event_type': 'STATUS',
        'ticket_id': ticket_id,
        'timestamp': ts,
        'uuid': ev,
        'env_id': env_id,
        'author': 'test',
        'data': {'status': 'deleted', 'ticket_id': ticket_id},
    }

    # reducer_path: must point to ticket-reducer.py (matches bridge-outbound.py convention)
    reducer_path = Path(repo_root) / 'plugins' / 'dso' / 'scripts' / 'ticket-reducer.py'

    handle_status_event(
        event=event,
        acli_client=mock_client,
        tickets_root=tracker_dir,
        bridge_env_id=env_id,
        run_id='test-run',
        reducer_path=reducer_path,
        status_updated=status_updated,
    )

    # delete_issue must have been called with 'TEST-42'
    assert mock_client.delete_issue.called, \
        f'delete_issue was NOT called; calls={mock_client.mock_calls}'
    delete_args = mock_client.delete_issue.call_args
    called_key = delete_args.args[0] if delete_args.args else delete_args.kwargs.get('jira_key', '')
    assert called_key == 'TEST-42', \
        f'delete_issue called with wrong key: {called_key!r}'

    # update_issue must NOT have been called
    assert not mock_client.update_issue.called, \
        f'update_issue was unexpectedly called: {mock_client.update_issue.call_args_list}'

    # ticket_id must be in status_updated
    assert ticket_id in status_updated, \
        f'ticket_id not in status_updated after delete: {status_updated}'

    print('BRIDGE_ROUTING_OK')
finally:
    shutil.rmtree(tmpdir, ignore_errors=True)
PYEOF

    exit_code=0
    py_output=$(python3 "$py_script" "$REPO_ROOT" 2>&1) || exit_code=$?
    rm -f "$py_script"

    assert_eq "bridge routing test exits 0" "0" "$exit_code"
    assert_contains "bridge routes deleted to delete_issue" "BRIDGE_ROUTING_OK" "$py_output"

    assert_pass_if_clean "test_bridge_routes_deleted_to_delete_issue"
}
test_bridge_routes_deleted_to_delete_issue

print_summary
