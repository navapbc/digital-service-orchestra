#!/usr/bin/env bash
# tests/scripts/test-ticket-edit.sh
# RED tests for ticket edit command — `ticket edit` subcommand.
#
# All tests MUST FAIL until ticket-edit.sh is implemented and the `ticket`
# dispatcher routes `edit` to it.
# Covers: script existence, title update, priority update, multi-field update,
# nonexistent ticket error, EDIT event file written.
#
# Usage: bash tests/scripts/test-ticket-edit.sh
# Returns: exit non-zero (RED) until ticket-edit.sh is implemented.

# NOTE: -e is intentionally omitted — test functions return non-zero by design
# (they assert against unimplemented features). -e would abort the runner.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"
TICKET_SCRIPT="$REPO_ROOT/plugins/dso/scripts/ticket"
TICKET_EDIT_SCRIPT="$REPO_ROOT/plugins/dso/scripts/ticket-edit.sh"

source "$REPO_ROOT/tests/lib/assert.sh"
source "$REPO_ROOT/tests/lib/git-fixtures.sh"

echo "=== test-ticket-edit.sh ==="

# ── Helper: create a fresh temp git repo with ticket system initialized ───────
_make_test_repo() {
    local tmp
    tmp=$(mktemp -d)
    _CLEANUP_DIRS+=("$tmp")
    clone_test_repo "$tmp/repo"
    # Initialize the ticket system so .tickets-tracker/ is available
    (cd "$tmp/repo" && bash "$TICKET_SCRIPT" init >/dev/null 2>/dev/null) || true
    echo "$tmp/repo"
}

# ── Helper: create a ticket and return its ID ─────────────────────────────────
_create_ticket() {
    local repo="$1"
    local title="${2:-Test ticket}"
    local ticket_id
    ticket_id=$(cd "$repo" && bash "$TICKET_SCRIPT" create task "$title" 2>/dev/null) || true
    echo "$ticket_id" | tail -1
}

# ── Helper: extract a field from ticket JSON via ticket show ──────────────────
_get_ticket_field() {
    local repo="$1"
    local ticket_id="$2"
    local field="$3"
    (cd "$repo" && bash "$TICKET_SCRIPT" show "$ticket_id" 2>/dev/null) \
        | python3 -c "import json,sys; d=json.loads(sys.stdin.read()); print(d.get('$field', 'MISSING'))" 2>/dev/null || echo "MISSING"
}

# ── Test 1: ticket-edit.sh script exists ─────────────────────────────────────
echo "Test 1: ticket-edit.sh script file exists"
test_ticket_edit_script_exists() {
    if [ -f "$TICKET_EDIT_SCRIPT" ]; then
        assert_eq "ticket-edit.sh exists" "exists" "exists"
    else
        assert_eq "ticket-edit.sh exists" "exists" "missing"
    fi
}
test_ticket_edit_script_exists

# ── Test 2: ticket edit updates title ────────────────────────────────────────
echo "Test 2: ticket edit --title updates the ticket title"
test_ticket_edit_updates_title() {
    local repo
    repo=$(_make_test_repo)

    # RED: ticket-edit.sh must exist first
    if [ ! -f "$TICKET_EDIT_SCRIPT" ]; then
        assert_eq "ticket-edit.sh exists for title test" "exists" "missing"
        return
    fi

    local ticket_id
    ticket_id=$(_create_ticket "$repo" "Original title")

    if [ -z "$ticket_id" ]; then
        assert_eq "ticket created for title update test" "non-empty" "empty"
        return
    fi

    # Run the edit command
    local exit_code=0
    (cd "$repo" && bash "$TICKET_SCRIPT" edit "$ticket_id" --title="Updated title" 2>/dev/null) || exit_code=$?

    # Assert: command exits 0
    assert_eq "ticket edit exits 0" "0" "$exit_code"

    # Assert: title is updated
    local actual_title
    actual_title=$(_get_ticket_field "$repo" "$ticket_id" "title")
    assert_eq "ticket title updated" "Updated title" "$actual_title"
}
test_ticket_edit_updates_title

# ── Test 3: ticket edit updates priority ─────────────────────────────────────
echo "Test 3: ticket edit --priority updates the ticket priority"
test_ticket_edit_updates_priority() {
    local repo
    repo=$(_make_test_repo)

    # RED: ticket-edit.sh must exist first
    if [ ! -f "$TICKET_EDIT_SCRIPT" ]; then
        assert_eq "ticket-edit.sh exists for priority test" "exists" "missing"
        return
    fi

    local ticket_id
    ticket_id=$(_create_ticket "$repo" "Priority test ticket")

    if [ -z "$ticket_id" ]; then
        assert_eq "ticket created for priority update test" "non-empty" "empty"
        return
    fi

    # Run the edit command
    local exit_code=0
    (cd "$repo" && bash "$TICKET_SCRIPT" edit "$ticket_id" --priority=0 2>/dev/null) || exit_code=$?

    # Assert: command exits 0
    assert_eq "ticket edit exits 0" "0" "$exit_code"

    # Assert: priority is updated
    local actual_priority
    actual_priority=$(_get_ticket_field "$repo" "$ticket_id" "priority")
    assert_eq "ticket priority updated to 0" "0" "$actual_priority"
}
test_ticket_edit_updates_priority

# ── Test 4: ticket edit updates multiple fields at once ───────────────────────
echo "Test 4: ticket edit --priority --assignee updates both fields"
test_ticket_edit_updates_multiple_fields() {
    local repo
    repo=$(_make_test_repo)

    # RED: ticket-edit.sh must exist first
    if [ ! -f "$TICKET_EDIT_SCRIPT" ]; then
        assert_eq "ticket-edit.sh exists for multi-field test" "exists" "missing"
        return
    fi

    local ticket_id
    ticket_id=$(_create_ticket "$repo" "Multi-field edit test")

    if [ -z "$ticket_id" ]; then
        assert_eq "ticket created for multi-field test" "non-empty" "empty"
        return
    fi

    # Run the edit command with multiple fields
    local exit_code=0
    (cd "$repo" && bash "$TICKET_SCRIPT" edit "$ticket_id" --priority=1 --assignee="Jane" 2>/dev/null) || exit_code=$?

    # Assert: command exits 0
    assert_eq "ticket edit multi-field exits 0" "0" "$exit_code"

    # Assert: priority updated
    local actual_priority
    actual_priority=$(_get_ticket_field "$repo" "$ticket_id" "priority")
    assert_eq "ticket priority updated to 1" "1" "$actual_priority"

    # Assert: assignee updated
    local actual_assignee
    actual_assignee=$(_get_ticket_field "$repo" "$ticket_id" "assignee")
    assert_eq "ticket assignee updated to Jane" "Jane" "$actual_assignee"
}
test_ticket_edit_updates_multiple_fields

# ── Test 5: ticket edit fails for nonexistent ticket ─────────────────────────
echo "Test 5: ticket edit fails with non-zero exit for nonexistent ticket ID"
test_ticket_edit_fails_for_nonexistent_ticket() {
    local repo
    repo=$(_make_test_repo)

    # RED: ticket-edit.sh must exist first
    if [ ! -f "$TICKET_EDIT_SCRIPT" ]; then
        assert_eq "ticket-edit.sh exists for nonexistent-id test" "exists" "missing"
        return
    fi

    local exit_code=0
    (cd "$repo" && bash "$TICKET_SCRIPT" edit "nonexistent-id" --title="Foo" 2>/dev/null) || exit_code=$?

    # Assert: exits non-zero
    assert_eq "edit nonexistent ticket exits non-zero" "1" "$([ "$exit_code" -ne 0 ] && echo 1 || echo 0)"
}
test_ticket_edit_fails_for_nonexistent_ticket

# ── Test 6: ticket edit writes an EDIT event file ────────────────────────────
echo "Test 6: ticket edit writes a *-EDIT.json event file in the ticket directory"
test_ticket_edit_writes_edit_event_file() {
    local repo
    repo=$(_make_test_repo)

    # RED: ticket-edit.sh must exist first
    if [ ! -f "$TICKET_EDIT_SCRIPT" ]; then
        assert_eq "ticket-edit.sh exists for event-file test" "exists" "missing"
        return
    fi

    local ticket_id
    ticket_id=$(_create_ticket "$repo" "Event file test ticket")

    if [ -z "$ticket_id" ]; then
        assert_eq "ticket created for event-file test" "non-empty" "empty"
        return
    fi

    # Run the edit command
    (cd "$repo" && bash "$TICKET_SCRIPT" edit "$ticket_id" --title="Edited title" 2>/dev/null) || true

    # Assert: an *-EDIT.json file exists in the ticket directory
    local tracker_dir="$repo/.tickets-tracker"
    local edit_event_count
    edit_event_count=$(find "$tracker_dir/$ticket_id" -maxdepth 1 -name '*-EDIT.json' ! -name '.*' 2>/dev/null | wc -l | tr -d ' ')

    assert_eq "exactly one EDIT event file written" "1" "$edit_event_count"

    # Assert: the EDIT event file parses as valid JSON
    local edit_event_file
    edit_event_file=$(find "$tracker_dir/$ticket_id" -maxdepth 1 -name '*-EDIT.json' ! -name '.*' 2>/dev/null | head -1)
    if [ -n "$edit_event_file" ]; then
        local parse_exit=0
        python3 -c "import json,sys; json.load(sys.stdin)" < "$edit_event_file" 2>/dev/null || parse_exit=$?
        assert_eq "EDIT event JSON is valid" "0" "$parse_exit"
    else
        assert_eq "EDIT event file found for JSON validation" "found" "not-found"
    fi
}
test_ticket_edit_writes_edit_event_file

# ── Test 7: ticket edit --description updates description field ──────────────
echo ""
echo "Test 7: ticket edit --description updates description field"
test_ticket_edit_description() {
    _snapshot_fail
    local repo ticket_id

    repo=$(_make_test_repo)

    if [ ! -f "$TICKET_EDIT_SCRIPT" ]; then
        assert_eq "ticket-edit.sh exists for description test" "exists" "missing"
        return
    fi

    ticket_id=$(_create_ticket "$repo" "Desc Test Ticket")

    if [ -z "$ticket_id" ]; then
        assert_eq "ticket created for description test" "non-empty" "empty"
        return
    fi

    # Edit description
    local edit_exit=0
    (cd "$repo" && bash "$TICKET_EDIT_SCRIPT" "$ticket_id" --description="Updated description text") 2>/dev/null || edit_exit=$?
    assert_eq "ticket edit --description exits 0" "0" "$edit_exit"

    # Verify via ticket show
    local desc
    desc=$(_get_ticket_field "$repo" "$ticket_id" "description")
    assert_eq "description field updated" "Updated description text" "$desc"

    assert_pass_if_clean "ticket edit --description updates description"
}
test_ticket_edit_description

# ── Test 8: ticket edit --tags sets tags field ────────────────────────────────
echo ""
echo "Test 8: ticket edit --tags sets tags field on the ticket"
test_ticket_edit_tags_field() {
    _snapshot_fail
    local repo ticket_id

    repo=$(_make_test_repo)

    if [ ! -f "$TICKET_EDIT_SCRIPT" ]; then
        assert_eq "ticket-edit.sh exists for tags test" "exists" "missing"
        return
    fi

    ticket_id=$(_create_ticket "$repo" "Tags Test Ticket")

    if [ -z "$ticket_id" ]; then
        assert_eq "ticket created for tags test" "non-empty" "empty"
        return
    fi

    # Edit tags field
    local edit_exit=0
    (cd "$repo" && bash "$TICKET_EDIT_SCRIPT" "$ticket_id" --tags="alpha,beta,gamma") 2>/dev/null || edit_exit=$?
    assert_eq "ticket edit --tags exits 0" "0" "$edit_exit"

    # Verify via ticket show — tags should be present in the JSON output
    local show_output
    show_output=$(cd "$repo" && bash "$TICKET_SCRIPT" show "$ticket_id" 2>/dev/null) || true

    # Assert tags key exists in output
    local tags_check
    tags_check=$(python3 - "$show_output" <<'PYEOF'
import json, sys
try:
    state = json.loads(sys.argv[1])
except Exception as e:
    print(f"PARSE_ERROR:{e}")
    sys.exit(1)
if "tags" not in state:
    print("MISSING_TAGS_KEY")
    sys.exit(1)
print("OK")
PYEOF
) || true
    assert_eq "tags key present in ticket show output" "OK" "$tags_check"

    assert_pass_if_clean "ticket edit --tags sets tags field"
}
test_ticket_edit_tags_field

# ── Test 9: ticket reducer includes tags in initial state ─────────────────────
echo ""
echo "Test 9: ticket reducer includes empty tags array in initial state"
test_ticket_reducer_tags_initial_state() {
    _snapshot_fail
    local repo ticket_id

    repo=$(_make_test_repo)

    ticket_id=$(_create_ticket "$repo" "Tags Initial State Test")

    if [ -z "$ticket_id" ]; then
        assert_eq "ticket created for tags initial state test" "non-empty" "empty"
        return
    fi

    # Show fresh ticket — tags should be an empty array by default
    local show_output
    show_output=$(cd "$repo" && bash "$TICKET_SCRIPT" show "$ticket_id" 2>/dev/null) || true

    local tags_check
    tags_check=$(python3 - "$show_output" <<'PYEOF'
import json, sys
try:
    state = json.loads(sys.argv[1])
except Exception as e:
    print(f"PARSE_ERROR:{e}")
    sys.exit(1)
if "tags" not in state:
    print("MISSING_TAGS_KEY")
    sys.exit(1)
if not isinstance(state["tags"], list):
    print(f"NOT_A_LIST:{type(state['tags']).__name__}")
    sys.exit(1)
if len(state["tags"]) != 0:
    print(f"EXPECTED_EMPTY_LIST:got {state['tags']!r}")
    sys.exit(1)
print("OK")
PYEOF
) || true
    assert_eq "fresh ticket has empty tags array" "OK" "$tags_check"

    assert_pass_if_clean "ticket reducer includes empty tags array in initial state"
}
test_ticket_reducer_tags_initial_state

# ── Test 10: tags are stored as an array after edit ───────────────────────────
echo ""
echo "Test 10: tags are stored as an array of strings after ticket edit"
test_ticket_edit_tags_stored_as_array() {
    _snapshot_fail
    local repo ticket_id

    repo=$(_make_test_repo)

    if [ ! -f "$TICKET_EDIT_SCRIPT" ]; then
        assert_eq "ticket-edit.sh exists for tags array test" "exists" "missing"
        return
    fi

    ticket_id=$(_create_ticket "$repo" "Tags Array Test Ticket")

    if [ -z "$ticket_id" ]; then
        assert_eq "ticket created for tags array test" "non-empty" "empty"
        return
    fi

    # Set tags as comma-separated string
    (cd "$repo" && bash "$TICKET_EDIT_SCRIPT" "$ticket_id" --tags="foo,bar,baz") 2>/dev/null || true

    local show_output
    show_output=$(cd "$repo" && bash "$TICKET_SCRIPT" show "$ticket_id" 2>/dev/null) || true

    local tags_check
    tags_check=$(python3 - "$show_output" <<'PYEOF'
import json, sys
try:
    state = json.loads(sys.argv[1])
except Exception as e:
    print(f"PARSE_ERROR:{e}")
    sys.exit(1)
if "tags" not in state:
    print("MISSING_TAGS_KEY")
    sys.exit(1)
tags = state["tags"]
if not isinstance(tags, list):
    print(f"NOT_A_LIST:{type(tags).__name__}")
    sys.exit(1)
if len(tags) != 3:
    print(f"EXPECTED_3_TAGS:got {tags!r}")
    sys.exit(1)
expected = ["foo", "bar", "baz"]
if tags != expected:
    print(f"WRONG_TAGS:expected {expected!r}, got {tags!r}")
    sys.exit(1)
print("OK")
PYEOF
) || true
    assert_eq "tags stored as array of 3 strings after comma-separated edit" "OK" "$tags_check"

    assert_pass_if_clean "tags are stored as array of strings after ticket edit"
}
test_ticket_edit_tags_stored_as_array

# ── Test 11: ticket edit 'tags' appears in allowed fields usage ───────────────
echo ""
echo "Test 11: ticket-edit.sh usage/help mentions tags field"
test_ticket_edit_usage_mentions_tags() {
    if [ ! -f "$TICKET_EDIT_SCRIPT" ]; then
        assert_eq "ticket-edit.sh exists for usage test" "exists" "missing"
        return
    fi

    # Run with too-few args to trigger usage
    local usage_output
    usage_output=$(bash "$TICKET_EDIT_SCRIPT" 2>&1) || true

    if echo "$usage_output" | grep -qi "tags"; then
        assert_eq "usage mentions 'tags'" "found" "found"
    else
        assert_eq "usage mentions 'tags'" "found" "not-found: $usage_output"
    fi
}
test_ticket_edit_usage_mentions_tags

print_summary
