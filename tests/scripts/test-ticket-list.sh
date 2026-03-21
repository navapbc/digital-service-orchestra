#!/usr/bin/env bash
# tests/scripts/test-ticket-list.sh
# RED tests for plugins/dso/scripts/ticket-list.sh — `ticket list` subcommand.
#
# All test functions MUST FAIL until ticket-list.sh is implemented.
# Covers: JSON array output, required per-ticket fields, ghost ticket inclusion
# with error status, empty system, and corrupt CREATE event (fsck_needed status).
#
# Usage: bash tests/scripts/test-ticket-list.sh
# Returns: exit non-zero (RED) until ticket-list.sh is implemented.

# NOTE: -e is intentionally omitted — test functions return non-zero by design
# (they assert against unimplemented features). -e would abort the runner.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"
TICKET_SCRIPT="$REPO_ROOT/plugins/dso/scripts/ticket"
TICKET_LIST_SCRIPT="$REPO_ROOT/plugins/dso/scripts/ticket-list.sh"

source "$REPO_ROOT/tests/lib/assert.sh"
source "$REPO_ROOT/tests/lib/git-fixtures.sh"

echo "=== test-ticket-list.sh ==="

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

# ── Helper: count COMMENT event files in a ticket directory ───────────────────
_count_comment_events() {
    local tracker_dir="$1"
    local ticket_id="$2"
    find "$tracker_dir/$ticket_id" -maxdepth 1 -name '*-COMMENT.json' ! -name '.*' 2>/dev/null | wc -l | tr -d ' '
}

# ── Test 1: ticket list with two tickets → outputs valid JSON array with both ──
echo "Test 1: ticket list with two tickets returns JSON array containing both tickets"
test_ticket_list_returns_all_tickets() {
    _snapshot_fail

    # RED: ticket-list.sh must not exist yet
    if [ ! -f "$TICKET_LIST_SCRIPT" ]; then
        assert_eq "ticket-list.sh exists" "exists" "missing"
        assert_pass_if_clean "test_ticket_list_returns_all_tickets"
        return
    fi

    local repo
    repo=$(_make_test_repo)

    local id1 id2
    id1=$(_create_ticket "$repo" task "First ticket")
    id2=$(_create_ticket "$repo" task "Second ticket")

    if [ -z "$id1" ] || [ -z "$id2" ]; then
        assert_eq "both tickets created" "non-empty" "empty"
        assert_pass_if_clean "test_ticket_list_returns_all_tickets"
        return
    fi

    local list_output
    local exit_code=0
    list_output=$(cd "$repo" && bash "$TICKET_SCRIPT" list 2>/dev/null) || exit_code=$?

    # Assert: exits 0
    assert_eq "ticket list exits 0" "0" "$exit_code"

    # Assert: output is a JSON array containing both ticket IDs
    local check_result
    check_result=$(python3 - "$list_output" "$id1" "$id2" <<'PYEOF'
import json, sys

try:
    tickets = json.loads(sys.argv[1])
except Exception as e:
    print(f"PARSE_ERROR:{e}")
    sys.exit(1)

id1 = sys.argv[2]
id2 = sys.argv[3]

errors = []

if not isinstance(tickets, list):
    print(f"NOT_ARRAY: got {type(tickets).__name__}")
    sys.exit(2)

ticket_ids = [t.get("ticket_id") for t in tickets if isinstance(t, dict)]

if id1 not in ticket_ids:
    errors.append(f"ticket_id {id1!r} not found in list")
if id2 not in ticket_ids:
    errors.append(f"ticket_id {id2!r} not found in list")

if errors:
    print("ERRORS:" + "; ".join(errors))
    sys.exit(3)
else:
    print("OK")
PYEOF
) || true

    if [ "$check_result" = "OK" ]; then
        assert_eq "list contains both ticket IDs" "OK" "OK"
    else
        assert_eq "list contains both ticket IDs" "OK" "$check_result"
    fi

    assert_pass_if_clean "test_ticket_list_returns_all_tickets"
}
test_ticket_list_returns_all_tickets

# ── Test 2: ticket list with empty tracker → outputs empty JSON array '[]' ─────
echo "Test 2: ticket list with empty tracker returns empty JSON array"
test_ticket_list_empty_system() {
    _snapshot_fail

    # RED: ticket-list.sh must not exist yet
    if [ ! -f "$TICKET_LIST_SCRIPT" ]; then
        assert_eq "ticket-list.sh exists" "exists" "missing"
        assert_pass_if_clean "test_ticket_list_empty_system"
        return
    fi

    local repo
    repo=$(_make_test_repo)

    local list_output
    local exit_code=0
    list_output=$(cd "$repo" && bash "$TICKET_SCRIPT" list 2>/dev/null) || exit_code=$?

    # Assert: exits 0
    assert_eq "empty list exits 0" "0" "$exit_code"

    # Assert: output is the empty JSON array
    local normalized
    normalized=$(python3 -c "import json,sys; print(json.loads(sys.argv[1]))" "$list_output" 2>/dev/null) || true
    assert_eq "empty system returns []" "[]" "$normalized"

    assert_pass_if_clean "test_ticket_list_empty_system"
}
test_ticket_list_empty_system

# ── Test 3: each ticket has required fields: ticket_id, ticket_type, title, status
echo "Test 3: each ticket in list has ticket_id, ticket_type, title, status fields"
test_ticket_list_has_required_fields() {
    _snapshot_fail

    # RED: ticket-list.sh must not exist yet
    if [ ! -f "$TICKET_LIST_SCRIPT" ]; then
        assert_eq "ticket-list.sh exists" "exists" "missing"
        assert_pass_if_clean "test_ticket_list_has_required_fields"
        return
    fi

    local repo
    repo=$(_make_test_repo)

    local ticket_id
    ticket_id=$(_create_ticket "$repo" task "Fields test ticket")

    if [ -z "$ticket_id" ]; then
        assert_eq "ticket created for field check" "non-empty" "empty"
        assert_pass_if_clean "test_ticket_list_has_required_fields"
        return
    fi

    local list_output
    local exit_code=0
    list_output=$(cd "$repo" && bash "$TICKET_SCRIPT" list 2>/dev/null) || exit_code=$?

    assert_eq "ticket list exits 0 for field check" "0" "$exit_code"

    local field_check
    field_check=$(python3 - "$list_output" "$ticket_id" <<'PYEOF'
import json, sys

try:
    tickets = json.loads(sys.argv[1])
except Exception as e:
    print(f"PARSE_ERROR:{e}")
    sys.exit(1)

target_id = sys.argv[2]

if not isinstance(tickets, list):
    print(f"NOT_ARRAY: {type(tickets).__name__}")
    sys.exit(2)

# Find our ticket
ticket = next((t for t in tickets if isinstance(t, dict) and t.get("ticket_id") == target_id), None)
if ticket is None:
    print(f"TICKET_NOT_FOUND:{target_id}")
    sys.exit(3)

errors = []
required_fields = ["ticket_id", "ticket_type", "title", "status"]
for field in required_fields:
    if field not in ticket:
        errors.append(f"missing field: {field!r}")
    elif ticket[field] is None:
        errors.append(f"field is None: {field!r}")

if errors:
    print("ERRORS:" + "; ".join(errors))
    sys.exit(4)
else:
    print("OK")
PYEOF
) || true

    if [ "$field_check" = "OK" ]; then
        assert_eq "ticket has all required fields" "OK" "OK"
    else
        assert_eq "ticket has all required fields" "OK" "$field_check"
    fi

    assert_pass_if_clean "test_ticket_list_has_required_fields"
}
test_ticket_list_has_required_fields

# ── Test 4: ghost ticket (dir exists, no CREATE event) appears in list with error status
echo "Test 4: ghost ticket dir (no CREATE event) appears in list with error status"
test_ticket_list_ghost_ticket_in_output() {
    _snapshot_fail

    # RED: ticket-list.sh must not exist yet
    if [ ! -f "$TICKET_LIST_SCRIPT" ]; then
        assert_eq "ticket-list.sh exists" "exists" "missing"
        assert_pass_if_clean "test_ticket_list_ghost_ticket_in_output"
        return
    fi

    local repo
    repo=$(_make_test_repo)
    local tracker_dir="$repo/.tickets-tracker"

    # Manually create a ghost ticket dir with a non-parseable event file
    local ghost_id="ghost-test1"
    mkdir -p "$tracker_dir/$ghost_id"
    # Write a corrupt JSON file so reduce_ticket returns status='error'
    printf 'not-valid-json' > "$tracker_dir/$ghost_id/0000000001-aaaa-COMMENT.json"
    git -C "$tracker_dir" add "$ghost_id/0000000001-aaaa-COMMENT.json" 2>/dev/null
    git -C "$tracker_dir" commit -q -m "test: add ghost ticket dir" 2>/dev/null || true

    local list_output
    local exit_code=0
    list_output=$(cd "$repo" && bash "$TICKET_SCRIPT" list 2>/dev/null) || exit_code=$?

    # Assert: exits 0 (ghost tickets should not crash the list command)
    assert_eq "list exits 0 even with ghost ticket" "0" "$exit_code"

    # Assert: output contains the ghost ticket with error status
    local ghost_check
    ghost_check=$(python3 - "$list_output" "$ghost_id" <<'PYEOF'
import json, sys

try:
    tickets = json.loads(sys.argv[1])
except Exception as e:
    print(f"PARSE_ERROR:{e}")
    sys.exit(1)

ghost_id = sys.argv[2]

if not isinstance(tickets, list):
    print(f"NOT_ARRAY: {type(tickets).__name__}")
    sys.exit(2)

ghost = next((t for t in tickets if isinstance(t, dict) and t.get("ticket_id") == ghost_id), None)
if ghost is None:
    print(f"GHOST_NOT_IN_LIST:{ghost_id}")
    sys.exit(3)

status = ghost.get("status", "")
if status not in ("error", "fsck_needed"):
    print(f"GHOST_STATUS_WRONG:expected error/fsck_needed, got {status!r}")
    sys.exit(4)

print("OK")
PYEOF
) || true

    if [ "$ghost_check" = "OK" ]; then
        assert_eq "ghost ticket in list with error status" "OK" "OK"
    else
        assert_eq "ghost ticket in list with error status" "OK" "$ghost_check"
    fi

    assert_pass_if_clean "test_ticket_list_ghost_ticket_in_output"
}
test_ticket_list_ghost_ticket_in_output

# ── Test 5: corrupt CREATE event → ticket appears with status='fsck_needed' ────
echo "Test 5: ticket with corrupt CREATE event appears in list with status=fsck_needed"
test_ticket_list_corrupt_create_event() {
    _snapshot_fail

    # RED: ticket-list.sh must not exist yet
    if [ ! -f "$TICKET_LIST_SCRIPT" ]; then
        assert_eq "ticket-list.sh exists" "exists" "missing"
        assert_pass_if_clean "test_ticket_list_corrupt_create_event"
        return
    fi

    local repo
    repo=$(_make_test_repo)
    local tracker_dir="$repo/.tickets-tracker"

    # Manually create a ticket dir with a parseable but corrupt CREATE event
    # (missing required fields ticket_type and title)
    local corrupt_id="corrupt-tkt1"
    mkdir -p "$tracker_dir/$corrupt_id"
    python3 -c "
import json, time
event = {
    'timestamp': int(time.time()),
    'uuid': 'aaaa-bbbb-cccc',
    'event_type': 'CREATE',
    'env_id': 'test-env',
    'author': 'test-author',
    'data': {}
}
with open('$tracker_dir/$corrupt_id/0000000001-aaaa-CREATE.json', 'w') as f:
    json.dump(event, f)
" 2>/dev/null
    git -C "$tracker_dir" add "$corrupt_id/" 2>/dev/null
    git -C "$tracker_dir" commit -q -m "test: add corrupt CREATE ticket" 2>/dev/null || true

    local list_output
    local exit_code=0
    list_output=$(cd "$repo" && bash "$TICKET_SCRIPT" list 2>/dev/null) || exit_code=$?

    # Assert: exits 0 (corrupt tickets must not crash list)
    assert_eq "list exits 0 with corrupt CREATE ticket" "0" "$exit_code"

    # Assert: corrupt ticket appears with status='fsck_needed'
    local corrupt_check
    corrupt_check=$(python3 - "$list_output" "$corrupt_id" <<'PYEOF'
import json, sys

try:
    tickets = json.loads(sys.argv[1])
except Exception as e:
    print(f"PARSE_ERROR:{e}")
    sys.exit(1)

corrupt_id = sys.argv[2]

if not isinstance(tickets, list):
    print(f"NOT_ARRAY: {type(tickets).__name__}")
    sys.exit(2)

ticket = next((t for t in tickets if isinstance(t, dict) and t.get("ticket_id") == corrupt_id), None)
if ticket is None:
    print(f"CORRUPT_TICKET_NOT_IN_LIST:{corrupt_id}")
    sys.exit(3)

status = ticket.get("status", "")
if status != "fsck_needed":
    print(f"WRONG_STATUS:expected fsck_needed, got {status!r}")
    sys.exit(4)

print("OK")
PYEOF
) || true

    if [ "$corrupt_check" = "OK" ]; then
        assert_eq "corrupt ticket appears with fsck_needed status" "OK" "OK"
    else
        assert_eq "corrupt ticket appears with fsck_needed status" "OK" "$corrupt_check"
    fi

    assert_pass_if_clean "test_ticket_list_corrupt_create_event"
}
test_ticket_list_corrupt_create_event

print_summary
