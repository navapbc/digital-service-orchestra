#!/usr/bin/env bash
# tests/scripts/test-ticket-create.sh
# RED tests for plugins/dso/scripts/ticket-create.sh — `ticket create` subcommand.
#
# All 6 test functions MUST FAIL until ticket-create.sh is implemented.
# Covers: ticket ID output, CREATE event file naming, event JSON schema,
# Python-written JSON, atomic git commit, invalid ticket type rejection.
#
# Usage: bash tests/scripts/test-ticket-create.sh
# Returns: exit non-zero (RED) until ticket-create.sh is implemented.

# NOTE: -e is intentionally omitted — test functions return non-zero by design
# (they assert against unimplemented features). -e would abort the runner.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"
TICKET_SCRIPT="$REPO_ROOT/plugins/dso/scripts/ticket"
TICKET_CREATE_SCRIPT="$REPO_ROOT/plugins/dso/scripts/ticket-create.sh"

source "$REPO_ROOT/tests/lib/assert.sh"
source "$REPO_ROOT/tests/lib/git-fixtures.sh"

echo "=== test-ticket-create.sh ==="

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

# ── Helper: get the single CREATE event file path under a ticket dir ──────────
_find_create_event() {
    local tracker_dir="$1"
    local ticket_id="$2"
    find "$tracker_dir/$ticket_id" -maxdepth 1 -name '*-CREATE.json' ! -name '.*' 2>/dev/null | head -1
}

# ── Test 1: ticket create outputs a non-empty ticket ID to stdout ─────────────
echo "Test 1: ticket create outputs a ticket ID matching [a-z0-9]+-[a-z0-9]+"
test_ticket_create_outputs_ticket_id() {
    local repo
    repo=$(_make_test_repo)

    # ticket-create.sh must exist — RED: it does not exist yet
    if [ ! -f "$TICKET_CREATE_SCRIPT" ]; then
        assert_eq "ticket-create.sh exists" "exists" "missing"
        return
    fi

    local stdout_out
    stdout_out=$(cd "$repo" && bash "$TICKET_SCRIPT" create task "My ticket" 2>/dev/null) || true

    # Assert: stdout is non-empty
    if [ -n "$stdout_out" ]; then
        assert_eq "ticket ID is non-empty" "non-empty" "non-empty"
    else
        assert_eq "ticket ID is non-empty" "non-empty" "empty"
        return
    fi

    # Assert: stdout matches the collision-resistant short ID pattern [a-z0-9]+-[a-z0-9]+
    # (e.g., "w21-gyn8" or "abc1-def2")
    if echo "$stdout_out" | grep -qE '^[a-z0-9]+-[a-z0-9]+$'; then
        assert_eq "ticket ID matches [a-z0-9]+-[a-z0-9]+" "match" "match"
    else
        assert_eq "ticket ID matches [a-z0-9]+-[a-z0-9]+" "match" "no-match: $stdout_out"
    fi
}
test_ticket_create_outputs_ticket_id

# ── Test 2: ticket create writes exactly one CREATE event file ────────────────
echo "Test 2: ticket create writes exactly one *-CREATE.json event file"
test_ticket_create_writes_create_event_json() {
    local repo
    repo=$(_make_test_repo)

    # ticket-create.sh must exist — RED: it does not exist yet
    if [ ! -f "$TICKET_CREATE_SCRIPT" ]; then
        assert_eq "ticket-create.sh exists" "exists" "missing"
        return
    fi

    local ticket_id
    ticket_id=$(cd "$repo" && bash "$TICKET_SCRIPT" create task "My ticket" 2>/dev/null) || true

    if [ -z "$ticket_id" ]; then
        assert_eq "ticket ID returned for event file check" "non-empty" "empty"
        return
    fi

    local tracker_dir="$repo/.tickets-tracker"

    # Assert: ticket directory exists under .tickets-tracker/
    if [ -d "$tracker_dir/$ticket_id" ]; then
        assert_eq "ticket dir exists: .tickets-tracker/<ticket_id>/" "exists" "exists"
    else
        assert_eq "ticket dir exists: .tickets-tracker/<ticket_id>/" "exists" "missing"
        return
    fi

    # Assert: exactly one *-CREATE.json file in the ticket directory
    local event_count
    event_count=$(find "$tracker_dir/$ticket_id" -maxdepth 1 -name '*-CREATE.json' ! -name '.*' 2>/dev/null | wc -l | tr -d ' ')
    assert_eq "exactly one CREATE event file" "1" "$event_count"

    # Assert: the event file parses as valid JSON
    local event_file
    event_file=$(_find_create_event "$tracker_dir" "$ticket_id")
    if [ -n "$event_file" ]; then
        local parse_exit=0
        python3 -c "import json,sys; json.load(sys.stdin)" < "$event_file" 2>/dev/null || parse_exit=$?
        assert_eq "event JSON is valid" "0" "$parse_exit"
    else
        assert_eq "CREATE event file found for JSON validation" "found" "not-found"
    fi
}
test_ticket_create_writes_create_event_json

# ── Test 3: CREATE event JSON contains all required fields ────────────────────
echo "Test 3: CREATE event JSON has all required base and CREATE-specific fields"
test_ticket_create_event_has_required_fields() {
    local repo
    repo=$(_make_test_repo)

    # ticket-create.sh must exist — RED: it does not exist yet
    if [ ! -f "$TICKET_CREATE_SCRIPT" ]; then
        assert_eq "ticket-create.sh exists" "exists" "missing"
        return
    fi

    local ticket_id
    ticket_id=$(cd "$repo" && bash "$TICKET_SCRIPT" create task "My ticket" 2>/dev/null) || true

    if [ -z "$ticket_id" ]; then
        assert_eq "ticket ID returned for field check" "non-empty" "empty"
        return
    fi

    local tracker_dir="$repo/.tickets-tracker"
    local event_file
    event_file=$(_find_create_event "$tracker_dir" "$ticket_id")

    if [ -z "$event_file" ]; then
        assert_eq "CREATE event file found" "found" "not-found"
        return
    fi

    # Extract and validate all required fields via Python
    # Base schema fields: timestamp (integer), uuid (string), event_type, env_id, author, data (object)
    # CREATE-specific data fields: ticket_type, title, parent_id
    local field_check
    field_check=$(python3 - "$event_file" <<'PYEOF'
import json, sys

try:
    with open(sys.argv[1], encoding='utf-8') as f:
        ev = json.load(f)
except Exception as e:
    print(f"PARSE_ERROR:{e}")
    sys.exit(1)

errors = []

# Base schema: timestamp must be an integer
if not isinstance(ev.get('timestamp'), int):
    errors.append(f"timestamp not int: {type(ev.get('timestamp'))}")

# Base schema: uuid must be a non-empty string
if not isinstance(ev.get('uuid'), str) or not ev.get('uuid'):
    errors.append(f"uuid missing or not str: {ev.get('uuid')!r}")

# Base schema: event_type must equal "CREATE"
if ev.get('event_type') != 'CREATE':
    errors.append(f"event_type not CREATE: {ev.get('event_type')!r}")

# Base schema: env_id must be a non-empty string
if not isinstance(ev.get('env_id'), str) or not ev.get('env_id'):
    errors.append(f"env_id missing or not str: {ev.get('env_id')!r}")

# Base schema: author must be a non-empty string
if not isinstance(ev.get('author'), str) or not ev.get('author'):
    errors.append(f"author missing or not str: {ev.get('author')!r}")

# Base schema: data must be an object
data = ev.get('data')
if not isinstance(data, dict):
    errors.append(f"data not dict: {type(data)}")
else:
    # CREATE-specific: data.ticket_type must be a string
    if not isinstance(data.get('ticket_type'), str):
        errors.append(f"data.ticket_type not str: {data.get('ticket_type')!r}")
    # CREATE-specific: data.title must be a string
    if not isinstance(data.get('title'), str):
        errors.append(f"data.title not str: {data.get('title')!r}")
    # CREATE-specific: data.parent_id must be a string (empty string is allowed for root tickets)
    if 'parent_id' not in data:
        errors.append("data.parent_id missing")
    elif not isinstance(data.get('parent_id'), str):
        errors.append(f"data.parent_id not str: {data.get('parent_id')!r}")

if errors:
    print("ERRORS:" + "; ".join(errors))
    sys.exit(2)
else:
    print("OK")
PYEOF
) || true

    if [ "$field_check" = "OK" ]; then
        assert_eq "all required fields present and correct types" "OK" "OK"
    else
        assert_eq "all required fields present and correct types" "OK" "$field_check"
    fi
}
test_ticket_create_event_has_required_fields

# ── Test 4: event JSON was written via Python (no bash heredoc artifacts) ─────
echo "Test 4: CREATE event JSON is Python-written (no bash heredoc artifacts)"
test_ticket_create_event_uses_python_json() {
    local repo
    repo=$(_make_test_repo)

    # ticket-create.sh must exist — RED: it does not exist yet
    if [ ! -f "$TICKET_CREATE_SCRIPT" ]; then
        assert_eq "ticket-create.sh exists" "exists" "missing"
        return
    fi

    # Use a title with special characters that a bash heredoc might mangle
    local special_title='it'"'"'s a "quoted" title'
    local ticket_id
    ticket_id=$(cd "$repo" && bash "$TICKET_SCRIPT" create task "$special_title" 2>/dev/null) || true

    if [ -z "$ticket_id" ]; then
        assert_eq "ticket ID returned for python-json check" "non-empty" "empty"
        return
    fi

    local tracker_dir="$repo/.tickets-tracker"
    local event_file
    event_file=$(_find_create_event "$tracker_dir" "$ticket_id")

    if [ -z "$event_file" ]; then
        assert_eq "CREATE event file found for python-json check" "found" "not-found"
        return
    fi

    # Assert: no literal \n sequences (bash heredoc artifact)
    local raw_content
    raw_content=$(cat "$event_file")
    if echo "$raw_content" | grep -qF '\n'; then
        assert_eq "no literal \\n in JSON (bash heredoc artifact)" "no-literal-newline" "has-literal-newline"
    else
        assert_eq "no literal \\n in JSON (bash heredoc artifact)" "no-literal-newline" "no-literal-newline"
    fi

    # Assert: the special title round-trips correctly through JSON
    local title_check
    title_check=$(python3 - "$event_file" "$special_title" <<'PYEOF'
import json, sys
with open(sys.argv[1], encoding='utf-8') as f:
    ev = json.load(f)
stored_title = ev.get('data', {}).get('title', '')
expected = sys.argv[2]
if stored_title == expected:
    print("OK")
else:
    print(f"MISMATCH: expected={expected!r} got={stored_title!r}")
PYEOF
) || true

    if [ "$title_check" = "OK" ]; then
        assert_eq "special-char title round-trips via Python JSON" "OK" "OK"
    else
        assert_eq "special-char title round-trips via Python JSON" "OK" "$title_check"
    fi
}
test_ticket_create_event_uses_python_json

# ── Test 5: ticket create auto-commits to the tickets branch ──────────────────
echo "Test 5: ticket create auto-commits event to tickets branch via write_commit_event"
test_ticket_create_auto_commits_to_tickets_branch() {
    local repo
    repo=$(_make_test_repo)

    # ticket-create.sh must exist — RED: it does not exist yet
    if [ ! -f "$TICKET_CREATE_SCRIPT" ]; then
        assert_eq "ticket-create.sh exists" "exists" "missing"
        return
    fi

    # Record commit count before create
    local commits_before
    commits_before=$(git -C "$repo/.tickets-tracker" log --oneline 2>/dev/null | wc -l | tr -d ' ')

    local ticket_id
    ticket_id=$(cd "$repo" && bash "$TICKET_SCRIPT" create task "My ticket" 2>/dev/null) || true

    if [ -z "$ticket_id" ]; then
        assert_eq "ticket ID returned for commit check" "non-empty" "empty"
        return
    fi

    # Assert: the commit count increased by exactly 1
    local commits_after
    commits_after=$(git -C "$repo/.tickets-tracker" log --oneline 2>/dev/null | wc -l | tr -d ' ')
    local new_commits
    new_commits=$(( commits_after - commits_before ))
    assert_eq "exactly one new commit on tickets branch" "1" "$new_commits"

    # Assert: the latest commit message references the ticket ID
    local latest_commit_msg
    latest_commit_msg=$(git -C "$repo/.tickets-tracker" log --oneline -1 2>/dev/null)
    if echo "$latest_commit_msg" | grep -qF "$ticket_id"; then
        assert_eq "latest commit references ticket ID" "referenced" "referenced"
    else
        assert_eq "latest commit references ticket ID" "referenced" "not-referenced: $latest_commit_msg"
    fi
}
test_ticket_create_auto_commits_to_tickets_branch

# ── Test 6: ticket create rejects invalid ticket type ─────────────────────────
echo "Test 6: ticket create rejects invalid ticket type with non-zero exit and error message"
test_ticket_create_rejects_invalid_ticket_type() {
    local repo
    repo=$(_make_test_repo)

    # ticket-create.sh must exist — RED: it does not exist yet
    if [ ! -f "$TICKET_CREATE_SCRIPT" ]; then
        assert_eq "ticket-create.sh exists" "exists" "missing"
        return
    fi

    local exit_code=0
    local stderr_out
    stderr_out=$(cd "$repo" && bash "$TICKET_SCRIPT" create invalid_type "title" 2>&1) || exit_code=$?

    # Assert: exits non-zero
    assert_eq "invalid type exits non-zero" "1" "$([ "$exit_code" -ne 0 ] && echo 1 || echo 0)"

    # Assert: error message is printed (not silent)
    if [ -n "$stderr_out" ]; then
        assert_eq "error message printed for invalid type" "has-message" "has-message"
    else
        assert_eq "error message printed for invalid type" "has-message" "silent"
    fi

    # Assert: no CREATE event file was written (command should fail before writing)
    local tracker_dir="$repo/.tickets-tracker"
    local spurious_events
    spurious_events=$(find "$tracker_dir" -maxdepth 2 -name '*-CREATE.json' ! -name '.*' 2>/dev/null | wc -l | tr -d ' ')
    assert_eq "no event file written on invalid type" "0" "$spurious_events"
}
test_ticket_create_rejects_invalid_ticket_type

# ── Test 7 (RED): ticket create with a closed parent is blocked ────────────────
echo "Test 7 (RED): ticket create with a closed parent exits non-zero"
test_create_with_closed_parent_blocked() {
    local repo
    repo=$(_make_test_repo)

    # Create and close a parent ticket
    local parent_id
    parent_id=$(cd "$repo" && bash "$TICKET_SCRIPT" create epic "Parent epic to close" 2>/dev/null) || true
    parent_id=$(echo "$parent_id" | tail -1)

    if [ -z "$parent_id" ]; then
        assert_eq "parent ticket created for closed-parent test" "non-empty" "empty"
        return
    fi

    # Close the parent (transition open → closed)
    (cd "$repo" && bash "$TICKET_SCRIPT" transition "$parent_id" open closed 2>/dev/null) || true

    # Verify the parent is actually closed before proceeding
    local parent_status
    parent_status=$(python3 "$REPO_ROOT/plugins/dso/scripts/ticket-reducer.py" \
        "$repo/.tickets-tracker/$parent_id" 2>/dev/null \
        | python3 -c "import json,sys; d=json.loads(sys.stdin.read()); print(d.get('status',''))" 2>/dev/null) || true

    if [ "$parent_status" != "closed" ]; then
        # Can't run the guard test if parent isn't closed — fail RED to signal setup issue
        assert_eq "create-closed-parent: parent is closed before test" "closed" "$parent_status"
        return
    fi

    # Attempt to create a child under the closed parent — must exit non-zero
    # RED: current ticket-create.sh does not enforce this guard → exits 0
    local exit_code=0
    local stderr_out
    stderr_out=$(cd "$repo" && bash "$TICKET_SCRIPT" create task "Orphan child under closed parent" --parent "$parent_id" 2>&1) || exit_code=$?

    # Assert: exits non-zero (guard not yet implemented → currently exits 0, so FAILS RED)
    assert_eq "create-closed-parent: exits non-zero" "1" "$([ "$exit_code" -ne 0 ] && echo 1 || echo 0)"

    # Assert: error message mentions parent, closed, or not allowed
    if echo "$stderr_out" | grep -qiE 'parent|closed|not allowed|cannot'; then
        assert_eq "create-closed-parent: error mentions closed parent" "has-closed-hint" "has-closed-hint"
    else
        assert_eq "create-closed-parent: error mentions closed parent" "has-closed-hint" "no-hint: $stderr_out"
    fi

    # Assert: no CREATE event file was written for any new child
    local tracker_dir="$repo/.tickets-tracker"
    # Count CREATE events excluding the parent's own CREATE event
    local new_events
    new_events=$(find "$tracker_dir" -maxdepth 2 -name '*-CREATE.json' ! -name '.*' 2>/dev/null \
        | grep -v "/$parent_id/" | wc -l | tr -d ' ')
    assert_eq "create-closed-parent: no CREATE event written for blocked child" "0" "$new_events"
}
test_create_with_closed_parent_blocked

print_summary
