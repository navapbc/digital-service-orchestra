#!/usr/bin/env bash
# tests/scripts/test-ticket-lib-api.sh
# Tests for plugins/dso/scripts/ticket-lib-api.sh — sourceable library dispatch
# for the `ticket show` subcommand.
#
# Goal: replace the per-call `exec bash ticket-show.sh` subprocess with an
# in-process library function invoked from the dispatcher.
#
# RED markers (tests that MUST fail before ticket-lib-api.sh is implemented):
#   - test_ticket_dispatcher_no_exec_to_show_script
#   - test_ticketlib_api_sourceability_strict_mode
#
# Test 1 (test_ticket_show_via_library_returns_correct_json) is a GREEN
# behavior invariant — `ticket show` must keep returning well-formed JSON
# regardless of dispatch mechanism.
#
# Usage: bash tests/scripts/test-ticket-lib-api.sh

# NOTE: -e intentionally omitted — test functions return non-zero by design.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"

TICKET_SCRIPT="$REPO_ROOT/plugins/dso/scripts/ticket"
TICKET_LIB_API="$REPO_ROOT/plugins/dso/scripts/ticket-lib-api.sh"
DSO_SHIM="$REPO_ROOT/.claude/scripts/dso"

# shellcheck source=/dev/null
source "$REPO_ROOT/tests/lib/assert.sh"
# shellcheck source=/dev/null
source "$REPO_ROOT/tests/lib/git-fixtures.sh"

echo "=== test-ticket-lib-api.sh ==="

# ── Helper: create a fresh temp git repo with ticket system initialized ───────
_make_test_repo() {
    local tmp
    tmp=$(mktemp -d)
    _CLEANUP_DIRS+=("$tmp")
    clone_ticket_repo "$tmp/repo"
    echo "$tmp/repo"
}

# ── Test 1: ticket show via library returns correct JSON ──────────────────────
# GREEN invariant — behavior must hold both before and after library dispatch.
echo "Test 1: ticket show returns valid JSON with required fields"
test_ticket_show_via_library_returns_correct_json() {
    local repo
    repo=$(_make_test_repo)

    local ticket_id
    ticket_id=$(cd "$repo" && _TICKET_TEST_NO_SYNC=1 bash "$TICKET_SCRIPT" create task "Library dispatch ticket" 2>/dev/null) || true

    if [ -z "$ticket_id" ]; then
        assert_eq "ticket ID returned" "non-empty" "empty"
        return
    fi

    local show_output
    show_output=$(cd "$repo" && _TICKET_TEST_NO_SYNC=1 bash "$TICKET_SCRIPT" show "$ticket_id" 2>/dev/null) || true

    local field_check
    field_check=$(python3 - "$show_output" "$ticket_id" <<'PYEOF'
import json, sys
try:
    state = json.loads(sys.argv[1])
except Exception as e:
    print(f"PARSE_ERROR:{e}")
    sys.exit(0)

errors = []
for field in ("ticket_id", "title", "status", "ticket_type"):
    if field not in state:
        errors.append(f"missing:{field}")

if state.get("ticket_type") != "task":
    errors.append(f"ticket_type={state.get('ticket_type')!r}")
if state.get("status") != "open":
    errors.append(f"status={state.get('status')!r}")
if state.get("title") != "Library dispatch ticket":
    errors.append(f"title={state.get('title')!r}")

print("OK" if not errors else "ERRORS:" + ";".join(errors))
PYEOF
) || true

    assert_eq "show output has required JSON fields" "OK" "$field_check"
}
test_ticket_show_via_library_returns_correct_json

# ── Test 2: dispatcher does NOT exec a subprocess for `show` ──────────────────
# RED: currently the `show` case in plugins/dso/scripts/ticket uses:
#     exec bash "$SCRIPT_DIR/ticket-show.sh" "$@"
# After library conversion, the dispatcher must source ticket-lib-api.sh and
# invoke a shell function in-process — no `exec bash .../ticket-show.sh`.
#
# We detect the current behavior structurally: grep the dispatcher source for
# the exec-to-show-script pattern. Structural because:
#   (a) the dispatcher uses an absolute path ($SCRIPT_DIR/ticket-show.sh) so a
#       PATH-sentinel fake cannot intercept it;
#   (b) sub-second process accounting (strace/dtrace) is not portable across
#       macOS/Linux test envs.
echo "Test 2: dispatcher does not exec ticket-show.sh as a subprocess"
test_ticket_dispatcher_no_exec_to_show_script() {
    if [ ! -f "$TICKET_SCRIPT" ]; then
        assert_eq "ticket dispatcher exists" "exists" "missing"
        return
    fi

    # Find lines in the `show)` case arm that `exec bash …/ticket-show.sh`.
    # Current source has exactly one such line; post-refactor must have zero.
    local exec_count
    exec_count=$(awk '
        /^[[:space:]]*show\)/ { in_show=1; next }
        in_show && /^[[:space:]]*;;/ { in_show=0 }
        in_show && /exec[[:space:]]+bash[[:space:]].*ticket-show\.sh/ { count++ }
        END { print count+0 }
    ' "$TICKET_SCRIPT")

    assert_eq "dispatcher show-case exec-to-subprocess count is 0" "0" "$exec_count"
}
test_ticket_dispatcher_no_exec_to_show_script

# ── Test 3: ticket-lib-api.sh is sourceable under strict mode ─────────────────
# RED: ticket-lib-api.sh does not exist yet, so `source` will fail and trip
# `set -e`, which would fire the EXIT trap. We detect that failure mode.
echo "Test 3: ticket-lib-api.sh is sourceable under set -euo pipefail"
test_ticketlib_api_sourceability_strict_mode() {
    local out
    out=$(bash -c '
        set -euo pipefail
        trap "echo TRAP_FIRED" EXIT
        # shellcheck source=/dev/null
        source "'"$TICKET_LIB_API"'"
        echo CLEAN_EXIT
        trap - EXIT
    ' 2>&1) || true

    # Must see CLEAN_EXIT and must NOT see TRAP_FIRED (which fires on abort).
    if echo "$out" | grep -q "CLEAN_EXIT" && ! echo "$out" | grep -q "TRAP_FIRED"; then
        assert_eq "ticket-lib-api.sh sources cleanly under strict mode" "ok" "ok"
    else
        assert_eq "ticket-lib-api.sh sources cleanly under strict mode" "ok" "failed: $out"
    fi
}
test_ticketlib_api_sourceability_strict_mode

# ── Helper: invoke a library function via `source` + dispatch in a subshell ───
# Prints the function's stdout. Exits non-zero if the function is undefined or
# fails. RED tests for unimplemented functions hit the "command not found" path.
_invoke_lib_op() {
    local op="$1"
    shift
    TICKET_LIB_API="$TICKET_LIB_API" bash -c '
        # shellcheck source=/dev/null
        source "$TICKET_LIB_API" || exit 97
        op="$1"
        shift
        if ! declare -f "$op" >/dev/null 2>&1; then
            exit 98
        fi
        "$op" "$@"
    ' _invoke_lib_op "$op" "$@"
}

# ── Test 4: ticket_tag via library ────────────────────────────────────────────
echo "Test 4: ticket_tag via library adds tag to ticket"
test_ticket_tag_via_library() {
    local repo
    repo=$(_make_test_repo)

    local ticket_id
    ticket_id=$(cd "$repo" && _TICKET_TEST_NO_SYNC=1 bash "$TICKET_SCRIPT" create task "tag test" 2>/dev/null) || true

    if [ -z "$ticket_id" ]; then
        assert_eq "created ticket" "non-empty" "empty"
        return
    fi

    (
        cd "$repo" || exit 1
        # shellcheck disable=SC2030,SC2031
        export _TICKET_TEST_NO_SYNC=1
        # shellcheck disable=SC2030,SC2031
        export TICKETS_TRACKER_DIR="$repo/.tickets-tracker"
        _invoke_lib_op ticket_tag "$ticket_id" testlabel >/dev/null 2>&1
    ) || true

    local show_output
    show_output=$(cd "$repo" && _TICKET_TEST_NO_SYNC=1 bash "$TICKET_SCRIPT" show "$ticket_id" 2>/dev/null) || true

    if echo "$show_output" | python3 -c "import json,sys; d=json.load(sys.stdin); sys.exit(0 if 'testlabel' in d.get('tags',[]) else 1)" 2>/dev/null; then
        assert_eq "tags contains testlabel" "yes" "yes"
    else
        assert_eq "tags contains testlabel" "yes" "no"
    fi
}
test_ticket_tag_via_library

# ── Test 5: ticket_untag via library ──────────────────────────────────────────
echo "Test 5: ticket_untag via library removes tag from ticket"
test_ticket_untag_via_library() {
    local repo
    repo=$(_make_test_repo)

    local ticket_id
    ticket_id=$(cd "$repo" && _TICKET_TEST_NO_SYNC=1 bash "$TICKET_SCRIPT" create task "untag test" --tags testlabel 2>/dev/null) || true

    if [ -z "$ticket_id" ]; then
        assert_eq "created ticket" "non-empty" "empty"
        return
    fi

    (
        cd "$repo" || exit 1
        # shellcheck disable=SC2030,SC2031
        export _TICKET_TEST_NO_SYNC=1
        # shellcheck disable=SC2030,SC2031
        export TICKETS_TRACKER_DIR="$repo/.tickets-tracker"
        _invoke_lib_op ticket_untag "$ticket_id" testlabel >/dev/null 2>&1
    ) || true

    local show_output
    show_output=$(cd "$repo" && _TICKET_TEST_NO_SYNC=1 bash "$TICKET_SCRIPT" show "$ticket_id" 2>/dev/null) || true

    if echo "$show_output" | python3 -c "import json,sys; d=json.load(sys.stdin); sys.exit(0 if 'testlabel' not in d.get('tags',[]) else 1)" 2>/dev/null; then
        assert_eq "tags does not contain testlabel" "removed" "removed"
    else
        assert_eq "tags does not contain testlabel" "removed" "still present"
    fi
}
test_ticket_untag_via_library

# ── Test 6: ticket_comment via library ────────────────────────────────────────
echo "Test 6: ticket_comment via library appends comment"
test_ticket_comment_via_library() {
    local repo
    repo=$(_make_test_repo)

    local ticket_id
    ticket_id=$(cd "$repo" && _TICKET_TEST_NO_SYNC=1 bash "$TICKET_SCRIPT" create task "comment test" 2>/dev/null) || true

    if [ -z "$ticket_id" ]; then
        assert_eq "created ticket" "non-empty" "empty"
        return
    fi

    (
        cd "$repo" || exit 1
        # shellcheck disable=SC2030,SC2031
        export _TICKET_TEST_NO_SYNC=1
        # shellcheck disable=SC2030,SC2031
        export TICKETS_TRACKER_DIR="$repo/.tickets-tracker"
        _invoke_lib_op ticket_comment "$ticket_id" "hello world" >/dev/null 2>&1
    ) || true

    local show_output
    show_output=$(cd "$repo" && _TICKET_TEST_NO_SYNC=1 bash "$TICKET_SCRIPT" show "$ticket_id" 2>/dev/null) || true

    if echo "$show_output" | python3 -c "
import json,sys
d=json.load(sys.stdin)
comments = d.get('comments', [])
found = any('hello world' in (c.get('body','') if isinstance(c, dict) else str(c)) for c in comments)
sys.exit(0 if found else 1)
" 2>/dev/null; then
        assert_eq "comment body present" "yes" "yes"
    else
        assert_eq "comment body present" "yes" "no"
    fi
}
test_ticket_comment_via_library

# ── Test 7: ticket_edit via library ───────────────────────────────────────────
echo "Test 7: ticket_edit via library updates title"
test_ticket_edit_via_library() {
    local repo
    repo=$(_make_test_repo)

    local ticket_id
    ticket_id=$(cd "$repo" && _TICKET_TEST_NO_SYNC=1 bash "$TICKET_SCRIPT" create task "original title" 2>/dev/null) || true

    if [ -z "$ticket_id" ]; then
        assert_eq "created ticket" "non-empty" "empty"
        return
    fi

    (
        cd "$repo" || exit 1
        # shellcheck disable=SC2030,SC2031
        export _TICKET_TEST_NO_SYNC=1
        # shellcheck disable=SC2030,SC2031
        export TICKETS_TRACKER_DIR="$repo/.tickets-tracker"
        _invoke_lib_op ticket_edit "$ticket_id" --title "new title" >/dev/null 2>&1
    ) || true

    local show_output
    show_output=$(cd "$repo" && _TICKET_TEST_NO_SYNC=1 bash "$TICKET_SCRIPT" show "$ticket_id" 2>/dev/null) || true

    local title
    title=$(echo "$show_output" | python3 -c "import json,sys; print(json.load(sys.stdin).get('title',''))" 2>/dev/null || echo "")

    assert_eq "title updated" "new title" "$title"
}
test_ticket_edit_via_library

# ── Test 8: ticket_create via library ─────────────────────────────────────────
echo "Test 8: ticket_create via library returns valid ticket id"
test_ticket_create_via_library() {
    local repo
    repo=$(_make_test_repo)

    local created_id
    created_id=$(
        cd "$repo" || exit 1
        # shellcheck disable=SC2030,SC2031
        export _TICKET_TEST_NO_SYNC=1
        # shellcheck disable=SC2030,SC2031
        export TICKETS_TRACKER_DIR="$repo/.tickets-tracker"
        _invoke_lib_op ticket_create task "test creation" 2>/dev/null
    ) || true

    if [ -z "$created_id" ]; then
        assert_eq "ticket_create returned id" "non-empty" "empty"
        return
    fi

    local show_output
    show_output=$(cd "$repo" && _TICKET_TEST_NO_SYNC=1 bash "$TICKET_SCRIPT" show "$created_id" 2>/dev/null) || true

    local check
    check=$(echo "$show_output" | python3 -c "
import json,sys
try:
    d=json.load(sys.stdin)
except Exception:
    print('parse_error'); sys.exit(0)
ok = d.get('ticket_type')=='task' and d.get('title')=='test creation'
print('OK' if ok else f\"type={d.get('ticket_type')!r} title={d.get('title')!r}\")
" 2>/dev/null || echo "parse_error")

    assert_eq "created ticket has correct type/title" "OK" "$check"
}
test_ticket_create_via_library

# ── Test 9: ticket_link via library ───────────────────────────────────────────
echo "Test 9: ticket_link via library establishes dependency"
test_ticket_link_via_library() {
    local repo
    repo=$(_make_test_repo)

    local t1 t2
    t1=$(cd "$repo" && _TICKET_TEST_NO_SYNC=1 bash "$TICKET_SCRIPT" create task "T1" 2>/dev/null) || true
    t2=$(cd "$repo" && _TICKET_TEST_NO_SYNC=1 bash "$TICKET_SCRIPT" create task "T2" 2>/dev/null) || true

    if [ -z "$t1" ] || [ -z "$t2" ]; then
        assert_eq "created both tickets" "non-empty" "empty"
        return
    fi

    (
        cd "$repo" || exit 1
        # shellcheck disable=SC2030,SC2031
        export _TICKET_TEST_NO_SYNC=1
        # shellcheck disable=SC2030,SC2031
        export TICKETS_TRACKER_DIR="$repo/.tickets-tracker"
        _invoke_lib_op ticket_link "$t1" "$t2" depends_on >/dev/null 2>&1
    ) || true

    local deps_output
    deps_output=$(cd "$repo" && _TICKET_TEST_NO_SYNC=1 bash "$TICKET_SCRIPT" deps "$t1" 2>/dev/null) || true

    if echo "$deps_output" | grep -q "$t2"; then
        assert_eq "T1 depends on T2" "yes" "yes"
    else
        assert_eq "T1 depends on T2" "yes" "no"
    fi
}
test_ticket_link_via_library

# ── Test 10: ticket_list via library ──────────────────────────────────────────
echo "Test 10: ticket_list via library returns valid JSON array"
test_ticket_list_via_library() {
    local repo
    repo=$(_make_test_repo)

    cd "$repo" && _TICKET_TEST_NO_SYNC=1 bash "$TICKET_SCRIPT" create task "list seed" >/dev/null 2>&1 || true

    local list_output
    list_output=$(
        cd "$repo" || exit 1
        # shellcheck disable=SC2030,SC2031
        export _TICKET_TEST_NO_SYNC=1
        # shellcheck disable=SC2030,SC2031
        export TICKETS_TRACKER_DIR="$repo/.tickets-tracker"
        _invoke_lib_op ticket_list 2>/dev/null
    ) || true

    local check
    check=$(echo "$list_output" | python3 -c "
import json,sys
try:
    d=json.load(sys.stdin)
except Exception:
    print('parse_error'); sys.exit(0)
if not isinstance(d, list):
    print(f'not_array:{type(d).__name__}'); sys.exit(0)
if len(d) < 1:
    print('empty'); sys.exit(0)
if not any('ticket_id' in t for t in d if isinstance(t, dict)):
    print('no_ticket_id_field'); sys.exit(0)
print('OK')
" 2>/dev/null || echo "parse_error")

    assert_eq "ticket_list returns valid JSON array" "OK" "$check"
}
test_ticket_list_via_library

# ── Test 11: ticket_transition via library ────────────────────────────────────
echo "Test 11: ticket_transition via library changes status"
test_ticket_transition_via_library() {
    local repo
    repo=$(_make_test_repo)

    local ticket_id
    ticket_id=$(cd "$repo" && _TICKET_TEST_NO_SYNC=1 bash "$TICKET_SCRIPT" create task "transition test" 2>/dev/null) || true

    if [ -z "$ticket_id" ]; then
        assert_eq "created ticket" "non-empty" "empty"
        return
    fi

    (
        cd "$repo" || exit 1
        # shellcheck disable=SC2030,SC2031
        export _TICKET_TEST_NO_SYNC=1
        # shellcheck disable=SC2030,SC2031
        export TICKETS_TRACKER_DIR="$repo/.tickets-tracker"
        _invoke_lib_op ticket_transition "$ticket_id" open in_progress >/dev/null 2>&1
    ) || true

    local show_output
    show_output=$(cd "$repo" && _TICKET_TEST_NO_SYNC=1 bash "$TICKET_SCRIPT" show "$ticket_id" 2>/dev/null) || true

    local status
    status=$(echo "$show_output" | python3 -c "import json,sys; print(json.load(sys.stdin).get('status',''))" 2>/dev/null || echo "")

    assert_eq "ticket transitioned to in_progress" "in_progress" "$status"
}
test_ticket_transition_via_library

print_summary
