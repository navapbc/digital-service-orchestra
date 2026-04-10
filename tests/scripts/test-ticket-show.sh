#!/usr/bin/env bash
# tests/scripts/test-ticket-show.sh
# Tests for plugins/dso/scripts/ticket-show.sh — `ticket show` subcommand.
#
# Covers:
#   1. ticket show displays compiled state with correct fields
#   2. ticket show fails for unknown/nonexistent ID
#   3. ticket show output is valid JSON
#
# Usage: bash tests/scripts/test-ticket-show.sh

# NOTE: -e is intentionally omitted — test functions return non-zero by design
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"
TICKET_SCRIPT="$REPO_ROOT/plugins/dso/scripts/ticket"
TICKET_SHOW_SCRIPT="$REPO_ROOT/plugins/dso/scripts/ticket-show.sh"

source "$REPO_ROOT/tests/lib/assert.sh"
source "$REPO_ROOT/tests/lib/git-fixtures.sh"

echo "=== test-ticket-show.sh ==="

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

# ── Test 1: ticket show displays compiled state with correct fields ───────────
echo "Test 1: ticket show displays compiled state for a created ticket"
test_ticket_show_displays_compiled_state() {
    # ticket-show.sh must exist
    if [ ! -f "$TICKET_SHOW_SCRIPT" ]; then
        assert_eq "ticket-show.sh exists" "exists" "missing"
        return
    fi

    local repo
    repo=$(_make_test_repo)

    # Create a ticket first
    local ticket_id
    ticket_id=$(cd "$repo" && bash "$TICKET_SCRIPT" create task "Test ticket" 2>/dev/null) || true

    if [ -z "$ticket_id" ]; then
        assert_eq "ticket ID returned for show test" "non-empty" "empty"
        return
    fi

    # Run ticket show
    local show_output
    local exit_code=0
    show_output=$(cd "$repo" && bash "$TICKET_SCRIPT" show "$ticket_id" 2>/dev/null) || exit_code=$?

    # Assert: exits 0
    assert_eq "ticket show exits 0" "0" "$exit_code"

    # Assert: output contains correct ticket_type and title
    local field_check
    field_check=$(python3 - "$show_output" <<'PYEOF'
import json, sys

try:
    state = json.loads(sys.argv[1])
except Exception as e:
    print(f"PARSE_ERROR:{e}")
    sys.exit(1)

errors = []

if state.get("ticket_type") != "task":
    errors.append(f"ticket_type: expected 'task', got {state.get('ticket_type')!r}")

if state.get("title") != "Test ticket":
    errors.append(f"title: expected 'Test ticket', got {state.get('title')!r}")

if state.get("status") != "open":
    errors.append(f"status: expected 'open', got {state.get('status')!r}")

if errors:
    print("ERRORS:" + "; ".join(errors))
else:
    print("OK")
PYEOF
) || true

    if [ "$field_check" = "OK" ]; then
        assert_eq "show output has correct ticket_type, title, status" "OK" "OK"
    else
        assert_eq "show output has correct ticket_type, title, status" "OK" "$field_check"
    fi
}
test_ticket_show_displays_compiled_state

# ── Test 2: ticket show fails for unknown ID ─────────────────────────────────
echo "Test 2: ticket show fails for unknown/nonexistent ID"
test_ticket_show_fails_for_unknown_id() {
    # ticket-show.sh must exist
    if [ ! -f "$TICKET_SHOW_SCRIPT" ]; then
        assert_eq "ticket-show.sh exists" "exists" "missing"
        return
    fi

    local repo
    repo=$(_make_test_repo)

    local exit_code=0
    local stderr_out
    stderr_out=$(cd "$repo" && bash "$TICKET_SCRIPT" show "nonexistent-id" 2>&1 >/dev/null) || exit_code=$?

    # Assert: exits non-zero
    assert_eq "show nonexistent ID exits non-zero" "1" "$([ "$exit_code" -ne 0 ] && echo 1 || echo 0)"

    # Assert: error message contains "not found"
    if echo "$stderr_out" | grep -iq "not found"; then
        assert_eq "error message contains 'not found'" "found" "found"
    else
        assert_eq "error message contains 'not found'" "found" "missing: $stderr_out"
    fi
}
test_ticket_show_fails_for_unknown_id

# ── Test 3: ticket show output is valid JSON ─────────────────────────────────
echo "Test 3: ticket show output is parseable by python3 json.tool"
test_ticket_show_output_is_valid_json() {
    # ticket-show.sh must exist
    if [ ! -f "$TICKET_SHOW_SCRIPT" ]; then
        assert_eq "ticket-show.sh exists" "exists" "missing"
        return
    fi

    local repo
    repo=$(_make_test_repo)

    # Create a ticket
    local ticket_id
    ticket_id=$(cd "$repo" && bash "$TICKET_SCRIPT" create task "JSON validation ticket" 2>/dev/null) || true

    if [ -z "$ticket_id" ]; then
        assert_eq "ticket ID returned for JSON validation test" "non-empty" "empty"
        return
    fi

    # Run ticket show and pipe through json.tool
    local parse_exit=0
    (cd "$repo" && bash "$TICKET_SCRIPT" show "$ticket_id" 2>/dev/null) | python3 -m json.tool >/dev/null 2>/dev/null || parse_exit=$?

    assert_eq "ticket show output is valid JSON" "0" "$parse_exit"
}
test_ticket_show_output_is_valid_json

# ── Test 3b: ticket show output is valid JSON when comments contain embedded JSON ─
echo "Test 3b: ticket show output is valid JSON when comments contain embedded JSON (a41d-9b23)"
test_ticket_show_valid_json_with_embedded_json_comments() {
    if [ ! -f "$TICKET_SHOW_SCRIPT" ]; then
        assert_eq "ticket-show.sh exists" "exists" "missing"
        return
    fi

    local repo
    repo=$(_make_test_repo)

    # Create a ticket
    local ticket_id
    ticket_id=$(cd "$repo" && bash "$TICKET_SCRIPT" create task "Embedded JSON comment test" 2>/dev/null) || true

    if [ -z "$ticket_id" ]; then
        assert_eq "ticket ID returned for embedded JSON test" "non-empty" "empty"
        return
    fi

    # Add a comment containing embedded JSON (simulates PREPLANNING_CONTEXT payloads)
    local embedded_json='{"type":"PREPLANNING_CONTEXT","data":{"epic_id":"test-1234","stories":[{"id":"s1","title":"Story with \"quotes\" and\nnewlines","criteria":["done when x > 0"]}]}}'
    (cd "$repo" && bash "$TICKET_SCRIPT" comment "$ticket_id" "$embedded_json" >/dev/null 2>/dev/null) || true

    # Run ticket show and verify valid JSON
    local parse_exit=0
    (cd "$repo" && bash "$TICKET_SCRIPT" show "$ticket_id" 2>/dev/null) | python3 -m json.tool >/dev/null 2>/dev/null || parse_exit=$?

    assert_eq "ticket show output is valid JSON with embedded JSON comment" "0" "$parse_exit"

    # Also verify the comment body is preserved in output
    local body_check=0
    (cd "$repo" && bash "$TICKET_SCRIPT" show "$ticket_id" 2>/dev/null) | python3 -c "
import json, sys
state = json.load(sys.stdin)
comments = state.get('comments', [])
found = any('PREPLANNING_CONTEXT' in c.get('body', '') for c in comments)
sys.exit(0 if found else 1)
" 2>/dev/null || body_check=$?

    assert_eq "embedded JSON comment body is preserved in ticket show output" "0" "$body_check"
}
test_ticket_show_valid_json_with_embedded_json_comments

# ── Test 4: ticket show --format=llm outputs minified single-line JSON ────────
echo "Test 4: ticket show --format=llm outputs minified single-line JSON"
test_ticket_show_llm_format_minified() {
    if [ ! -f "$TICKET_SHOW_SCRIPT" ]; then
        assert_eq "ticket-show.sh exists" "exists" "missing"
        return
    fi

    local repo
    repo=$(_make_test_repo)

    local ticket_id
    ticket_id=$(cd "$repo" && bash "$TICKET_SCRIPT" create task "LLM format test ticket" 2>/dev/null) || true

    if [ -z "$ticket_id" ]; then
        assert_eq "ticket ID returned for llm format test" "non-empty" "empty"
        return
    fi

    # Run ticket show --format=llm
    local llm_output
    local exit_code=0
    llm_output=$(cd "$repo" && bash "$TICKET_SCRIPT" show --format=llm "$ticket_id" 2>/dev/null) || exit_code=$?

    # Assert: exits 0
    assert_eq "ticket show --format=llm exits 0" "0" "$exit_code"

    # Assert: output is a single line (minified JSON — no newlines)
    local line_count
    line_count=$(echo "$llm_output" | wc -l | tr -d ' ')
    assert_eq "llm output is single line" "1" "$line_count"

    # Assert: output is valid JSON and has shortened keys (id not ticket_id)
    local check_result
    check_result=$(python3 - "$llm_output" <<'PYEOF'
import json, sys

raw = sys.argv[1].strip()
try:
    d = json.loads(raw)
except Exception as e:
    print(f"PARSE_ERROR:{e}")
    sys.exit(1)

errors = []

# Must use shortened key 'id' not 'ticket_id'
if "id" not in d:
    errors.append("missing shortened key 'id'")
if "ticket_id" in d:
    errors.append("full key 'ticket_id' should not be present in llm format")

# Must have 'st' (status) not 'status'
if "st" not in d:
    errors.append("missing shortened key 'st' for status")
if "status" in d:
    errors.append("full key 'status' should not be present in llm format")

# Must have 't' (type) not 'ticket_type'
if "t" not in d:
    errors.append("missing shortened key 't' for ticket_type")
if "ticket_type" in d:
    errors.append("full key 'ticket_type' should not be present in llm format")

# Must have 'ttl' (title) not 'title'
if "ttl" not in d:
    errors.append("missing shortened key 'ttl' for title")
if "title" in d:
    errors.append("full key 'title' should not be present in llm format")

# Null values must be stripped
for k, v in d.items():
    if v is None:
        errors.append(f"null value not stripped for key {k!r}")

# Must be compact (no unnecessary whitespace — check no indent)
if "\n" in raw or "  " in raw:
    errors.append("output has whitespace/indentation — should be minified")

if errors:
    print("ERRORS:" + "; ".join(errors))
    sys.exit(2)

print("OK")
PYEOF
) || true

    if [ "$check_result" = "OK" ]; then
        assert_eq "llm format has shortened keys and no nulls" "OK" "OK"
    else
        assert_eq "llm format has shortened keys and no nulls" "OK" "$check_result"
    fi
}
test_ticket_show_llm_format_minified

# ── Test 5: ticket show --format=llm token reduction >= 50% vs standard ──────
echo "Test 5: ticket show --format=llm is at least 50% smaller than standard output"
test_ticket_show_llm_token_reduction() {
    if [ ! -f "$TICKET_SHOW_SCRIPT" ]; then
        assert_eq "ticket-show.sh exists" "exists" "missing"
        return
    fi

    local repo
    repo=$(_make_test_repo)

    # Create a ticket with a comment to give it some bulk
    local ticket_id
    ticket_id=$(cd "$repo" && bash "$TICKET_SCRIPT" create task "Token reduction test ticket" 2>/dev/null) || true

    if [ -z "$ticket_id" ]; then
        assert_eq "ticket ID returned for token reduction test" "non-empty" "empty"
        return
    fi

    # Add a comment to inflate the standard output
    (cd "$repo" && bash "$TICKET_SCRIPT" comment "$ticket_id" "This is a test comment body." 2>/dev/null) || true

    local standard_output llm_output
    standard_output=$(cd "$repo" && bash "$TICKET_SCRIPT" show "$ticket_id" 2>/dev/null) || true
    llm_output=$(cd "$repo" && bash "$TICKET_SCRIPT" show --format=llm "$ticket_id" 2>/dev/null) || true

    if [ -z "$standard_output" ] || [ -z "$llm_output" ]; then
        assert_eq "both outputs non-empty for token reduction check" "non-empty" "empty"
        return
    fi

    # Assert: llm output is at least 50% smaller in byte count
    local check_result
    check_result=$(python3 - "$standard_output" "$llm_output" <<'PYEOF'
import sys

std_bytes = len(sys.argv[1].encode("utf-8"))
llm_bytes = len(sys.argv[2].encode("utf-8"))

if std_bytes == 0:
    print("ERROR:standard output is empty")
    sys.exit(1)

reduction = (std_bytes - llm_bytes) / std_bytes
if reduction >= 0.5:
    print(f"OK:{reduction:.0%} reduction ({std_bytes}→{llm_bytes} bytes)")
else:
    print(f"INSUFFICIENT_REDUCTION:{reduction:.0%} reduction ({std_bytes}→{llm_bytes} bytes) — need 50%+")
    sys.exit(2)
PYEOF
) || true

    if [[ "$check_result" == OK:* ]]; then
        assert_eq "llm format achieves 50%+ token reduction" "OK" "OK"
    else
        assert_eq "llm format achieves 50%+ token reduction" "OK" "$check_result"
    fi
}
test_ticket_show_llm_token_reduction

print_summary
