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

print_summary
