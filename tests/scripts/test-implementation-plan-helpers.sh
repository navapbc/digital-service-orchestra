#!/usr/bin/env bash
# tests/scripts/test-implementation-plan-helpers.sh
# Behavioral tests for the three implementation-plan helper scripts:
#   - approach-cycle-state.sh   (cycle counter persistence with TTL)
#   - check-tag-guards.sh       (pre-flight tag guard verdict)
#   - check-reinvocation.sh     (children classification → planning verdict)
#
# Per behavioral-testing-standard.md: each test invokes the real script and
# asserts on its observable output (stdout) and exit code.
#
# Usage: bash tests/scripts/test-implementation-plan-helpers.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SCRIPTS="$REPO_ROOT/plugins/dso/scripts/implementation-plan"

source "$REPO_ROOT/tests/lib/assert.sh"

# Skip the ticket-sync git fetch so tests that call check-tag-guards.sh /
# check-reinvocation.sh (which invoke `.claude/scripts/dso ticket show`) do
# not trigger a network fetch in CI where the sync marker is absent.
# See _ensure_initialized in plugins/dso/scripts/ticket.
export _TICKET_TEST_NO_SYNC=1

echo "=== test-implementation-plan-helpers.sh ==="
echo ""

# Cycle-state lives under /tmp; use a unique fixture id per test run so
# parallel/concurrent test runs do not collide (see CLAUDE.md rule 16).
_FIXTURE_ID="ipl-helpers-$$-$(date +%s)"
_STATE_FILE="/tmp/approach-resolution-${_FIXTURE_ID}.json"

_cleanup() {
    rm -f "$_STATE_FILE"
}
trap _cleanup EXIT

# ─── approach-cycle-state.sh ──────────────────────────────────────────────────

# Given: no state file
# When: read
# Then: prints 0 (fresh start sentinel)
test_cycle_state_read_returns_zero_when_absent() {
    rm -f "$_STATE_FILE"
    local _out
    _out=$(bash "$SCRIPTS/approach-cycle-state.sh" read "$_FIXTURE_ID")
    assert_eq "test_cycle_state_read_returns_zero_when_absent: read on absent file prints 0" \
              "0" "$_out"
}

# Given: cycle counter starts at 0
# When: increment is called twice
# Then: prints 1, then 2 (monotonic counter)
test_cycle_state_increment_advances_counter() {
    rm -f "$_STATE_FILE"
    local _first _second
    _first=$(bash "$SCRIPTS/approach-cycle-state.sh" increment "$_FIXTURE_ID")
    _second=$(bash "$SCRIPTS/approach-cycle-state.sh" increment "$_FIXTURE_ID")
    assert_eq "test_cycle_state_increment_advances_counter: first increment prints 1" \
              "1" "$_first"
    assert_eq "test_cycle_state_increment_advances_counter: second increment prints 2" \
              "2" "$_second"
}

# Given: counter has been incremented to a non-zero value
# When: clear is called
# Then: state file is removed and a subsequent read prints 0
test_cycle_state_clear_resets_counter() {
    bash "$SCRIPTS/approach-cycle-state.sh" increment "$_FIXTURE_ID" >/dev/null
    bash "$SCRIPTS/approach-cycle-state.sh" clear "$_FIXTURE_ID" >/dev/null
    local _out
    _out=$(bash "$SCRIPTS/approach-cycle-state.sh" read "$_FIXTURE_ID")
    assert_eq "test_cycle_state_clear_resets_counter: read after clear prints 0" \
              "0" "$_out"
}

# Given: a state file older than the 4-hour TTL
# When: read is called
# Then: stale file is removed, read returns 0 (TTL enforcement)
test_cycle_state_stale_file_treated_as_fresh() {
    bash "$SCRIPTS/approach-cycle-state.sh" increment "$_FIXTURE_ID" >/dev/null
    # backdate the state file by 5 hours (TTL is 4 hours)
    touch -t "$(date -v -5H +%Y%m%d%H%M 2>/dev/null || date -d '5 hours ago' +%Y%m%d%H%M)" "$_STATE_FILE"
    local _out
    _out=$(bash "$SCRIPTS/approach-cycle-state.sh" read "$_FIXTURE_ID")
    assert_eq "test_cycle_state_stale_file_treated_as_fresh: stale state read prints 0" \
              "0" "$_out"
}

# Given: invalid subcommand
# When: invoked
# Then: exit 1 with usage message
test_cycle_state_unknown_command_errors() {
    set +e
    bash "$SCRIPTS/approach-cycle-state.sh" frobnicate "$_FIXTURE_ID" >/dev/null 2>&1
    local _rc=$?
    set -e
    assert_eq "test_cycle_state_unknown_command_errors: unknown subcommand exits 1" \
              "1" "$_rc"
}

# ─── check-tag-guards.sh ──────────────────────────────────────────────────────

# Given: a nonexistent ticket id (lookup will fail)
# When: check-tag-guards is called
# Then: prints OK and exits 2 (fail-open contract)
test_tag_guards_lookup_failure_fails_open() {
    # Sandbox the dso shim so the real ticket CLI's _ensure_initialized
    # (which runs an unguarded `git fetch origin tickets`) is never invoked.
    # Bug 5b48-a4b1: unstubbed real-CLI calls caused 120s CI timeouts when
    # the fetch silently hung. Matches the pattern used by
    # test_reinvocation_all_lookups_fail_returns_fresh below.
    local _sandbox
    _sandbox=$(mktemp -d "${TMPDIR:-/tmp}/ipl-helpers-sandbox.XXXXXX")
    mkdir -p "$_sandbox/.claude/scripts"
    cat > "$_sandbox/.claude/scripts/dso" <<'STUB'
#!/usr/bin/env bash
# ticket show on nonexistent id → exit 1 (lookup failure)
if [[ "$1" == "ticket" && "$2" == "show" ]]; then
    exit 1
fi
exit 1
STUB
    chmod +x "$_sandbox/.claude/scripts/dso"

    set +e
    local _out
    _out=$(cd "$_sandbox" && bash "$SCRIPTS/check-tag-guards.sh" nonexistent-ticket-id-zzz9-yyyy 2>/dev/null)
    local _rc=$?
    set -e

    rm -rf "$_sandbox"

    assert_eq "test_tag_guards_lookup_failure_fails_open: nonexistent ticket prints OK" \
              "OK" "$_out"
    assert_eq "test_tag_guards_lookup_failure_fails_open: nonexistent ticket exits 2" \
              "2" "$_rc"
}

# Given: missing argument
# When: invoked
# Then: exit 2 (usage error, fail-open in caller)
test_tag_guards_missing_arg_errors() {
    set +e
    bash "$SCRIPTS/check-tag-guards.sh" >/dev/null 2>&1
    local _rc=$?
    set -e
    assert_eq "test_tag_guards_missing_arg_errors: missing ticket id exits 2" \
              "2" "$_rc"
}

# ─── check-reinvocation.sh ────────────────────────────────────────────────────

# Given: a ticket that does not exist
# When: check-reinvocation is called
# Then: emits verdict=fresh and exits 2 (fail-open contract — caller treats as fresh planning)
test_reinvocation_lookup_failure_returns_fresh() {
    # Sandbox the dso shim so the real ticket CLI's _ensure_initialized
    # (unguarded `git fetch origin tickets`) is never invoked.
    # Bug 5b48-a4b1: see comment on test_tag_guards_lookup_failure_fails_open.
    local _sandbox
    _sandbox=$(mktemp -d "${TMPDIR:-/tmp}/ipl-helpers-sandbox.XXXXXX")
    mkdir -p "$_sandbox/.claude/scripts"
    cat > "$_sandbox/.claude/scripts/dso" <<'STUB'
#!/usr/bin/env bash
# ticket deps on nonexistent id → exit 1 (lookup failure)
if [[ "$1" == "ticket" && "$2" == "deps" ]]; then
    exit 1
fi
exit 1
STUB
    chmod +x "$_sandbox/.claude/scripts/dso"

    set +e
    local _out
    _out=$(cd "$_sandbox" && bash "$SCRIPTS/check-reinvocation.sh" nonexistent-ticket-id-zzz9-yyyy 2>/dev/null)
    local _rc=$?
    set -e

    rm -rf "$_sandbox"

    local _has_fresh=0
    echo "$_out" | grep -q '^verdict=fresh' && _has_fresh=1
    assert_eq "test_reinvocation_lookup_failure_returns_fresh: emits verdict=fresh on lookup failure" \
              "1" "$_has_fresh"
    assert_eq "test_reinvocation_lookup_failure_returns_fresh: exits 2 on lookup failure" \
              "2" "$_rc"
}

# Given: missing argument
# When: invoked
# Then: exit 2 (usage error)
test_reinvocation_missing_arg_errors() {
    set +e
    bash "$SCRIPTS/check-reinvocation.sh" >/dev/null 2>&1
    local _rc=$?
    set -e
    assert_eq "test_reinvocation_missing_arg_errors: missing ticket id exits 2" \
              "2" "$_rc"
}

# Given: parent has children but every per-child ticket-show call fails
# When: invoked
# Then: emits verdict=fresh + exit 2 (fail-open guard against incoherent diff_plan)
#
# This test mocks the .claude/scripts/dso shim by running from a sandbox dir
# whose .claude/scripts/dso stub returns a non-empty children list for `ticket
# deps` and exits non-zero for `ticket show`, exercising the _total_classified
# guard at the end of check-reinvocation.sh.
test_reinvocation_all_lookups_fail_returns_fresh() {
    local _sandbox
    _sandbox=$(mktemp -d "${TMPDIR:-/tmp}/ipl-helpers-sandbox.XXXXXX")
    mkdir -p "$_sandbox/.claude/scripts"
    cat > "$_sandbox/.claude/scripts/dso" <<'STUB'
#!/usr/bin/env bash
if [[ "$1" == "ticket" && "$2" == "deps" ]]; then
    echo '{"ticket_id":"parent-x","children":["zzz9-yyy1","zzz9-yyy2"],"deps":[],"blockers":[],"ready_to_work":false}'
    exit 0
fi
if [[ "$1" == "ticket" && "$2" == "show" ]]; then
    exit 1
fi
exit 1
STUB
    chmod +x "$_sandbox/.claude/scripts/dso"

    set +e
    local _out
    _out=$(cd "$_sandbox" && bash "$SCRIPTS/check-reinvocation.sh" parent-x 2>/dev/null)
    local _rc=$?
    set -e

    rm -rf "$_sandbox"

    local _verdict
    _verdict=$(echo "$_out" | grep '^verdict=' | cut -d= -f2-)

    assert_eq "test_reinvocation_all_lookups_fail_returns_fresh: emits verdict=fresh when all child lookups fail" \
              "fresh" "$_verdict"
    assert_eq "test_reinvocation_all_lookups_fail_returns_fresh: exits 2 (fail-open) when all child lookups fail" \
              "2" "$_rc"
}

# Given: all child tasks of a story are closed AND the parent epic has an
#        unresolved REPLAN_TRIGGER:validation comment mentioning the story
# When: check-reinvocation is called on the story
# Then: verdict=replan_required (NOT all_closed) so the caller routes to
#       diff-plan mode and creates new TDD remediation tasks instead of
#       emitting STATUS:complete (which would cause the verifier ↔ impl-plan
#       loop documented in bug 95db-941d-04d8-41d1).
test_reinvocation_unresolved_replan_trigger_returns_replan_required() {
    local _sandbox _story_id _epic_id _child_id
    _sandbox=$(mktemp -d "${TMPDIR:-/tmp}/ipl-helpers-sandbox.XXXXXX")
    _story_id="story-aaaa-1111-2222-3333"
    _epic_id="epic-bbbb-4444-5555-6666"
    _child_id="task-cccc-7777-8888-9999"
    mkdir -p "$_sandbox/.claude/scripts"
    cat > "$_sandbox/.claude/scripts/dso" <<STUB
#!/usr/bin/env bash
# Stub: story has one closed child; story's parent epic has an unresolved
# REPLAN_TRIGGER:validation comment that mentions the story id.
if [[ "\$1" == "ticket" && "\$2" == "deps" ]]; then
    echo '{"ticket_id":"$_story_id","children":["$_child_id"],"deps":[],"blockers":[],"ready_to_work":false}'
    exit 0
fi
if [[ "\$1" == "ticket" && "\$2" == "show" ]]; then
    case "\$3" in
        $_child_id)
            echo '{"ticket_id":"$_child_id","status":"closed","parent_id":"$_story_id"}'
            exit 0 ;;
        $_story_id)
            echo '{"ticket_id":"$_story_id","status":"open","parent_id":"$_epic_id","comments":[]}'
            exit 0 ;;
        $_epic_id)
            # REPLAN_TRIGGER:validation present, no matching REPLAN_RESOLVED yet.
            cat <<JSON
{"ticket_id":"$_epic_id","status":"open","parent_id":null,"comments":[
{"body":"REPLAN_TRIGGER: validation — Story $_story_id validation failed with all tasks closed. Creating TDD remediation tasks."}
]}
JSON
            exit 0 ;;
    esac
fi
exit 1
STUB
    chmod +x "$_sandbox/.claude/scripts/dso"

    set +e
    local _out
    _out=$(cd "$_sandbox" && bash "$SCRIPTS/check-reinvocation.sh" "$_story_id" 2>/dev/null)
    local _rc=$?
    set -e
    rm -rf "$_sandbox"

    local _verdict
    _verdict=$(echo "$_out" | grep '^verdict=' | cut -d= -f2-)
    assert_eq "test_reinvocation_unresolved_replan_trigger_returns_replan_required: emits verdict=replan_required" \
              "replan_required" "$_verdict"
    assert_eq "test_reinvocation_unresolved_replan_trigger_returns_replan_required: exits 0" \
              "0" "$_rc"
}

# Given: all child tasks closed AND parent epic has a REPLAN_TRIGGER:validation
#        comment AND a subsequent REPLAN_RESOLVED:implementation-plan comment
#        for the same story
# When: check-reinvocation is called on the story
# Then: verdict=all_closed (the trigger has been resolved; no further
#       remediation needed)
test_reinvocation_resolved_replan_trigger_returns_all_closed() {
    local _sandbox _story_id _epic_id _child_id
    _sandbox=$(mktemp -d "${TMPDIR:-/tmp}/ipl-helpers-sandbox.XXXXXX")
    _story_id="story-dddd-1111-2222-3333"
    _epic_id="epic-eeee-4444-5555-6666"
    _child_id="task-ffff-7777-8888-9999"
    mkdir -p "$_sandbox/.claude/scripts"
    cat > "$_sandbox/.claude/scripts/dso" <<STUB
#!/usr/bin/env bash
if [[ "\$1" == "ticket" && "\$2" == "deps" ]]; then
    echo '{"ticket_id":"$_story_id","children":["$_child_id"],"deps":[],"blockers":[],"ready_to_work":false}'
    exit 0
fi
if [[ "\$1" == "ticket" && "\$2" == "show" ]]; then
    case "\$3" in
        $_child_id)
            echo '{"ticket_id":"$_child_id","status":"closed","parent_id":"$_story_id"}'
            exit 0 ;;
        $_story_id)
            echo '{"ticket_id":"$_story_id","status":"open","parent_id":"$_epic_id","comments":[]}'
            exit 0 ;;
        $_epic_id)
            # TRIGGER followed by RESOLVED for the same story.
            cat <<JSON
{"ticket_id":"$_epic_id","status":"open","parent_id":null,"comments":[
{"body":"REPLAN_TRIGGER: validation — Story $_story_id validation failed with all tasks closed."},
{"body":"REPLAN_RESOLVED: implementation-plan — Remediation tasks created for story $_story_id."}
]}
JSON
            exit 0 ;;
    esac
fi
exit 1
STUB
    chmod +x "$_sandbox/.claude/scripts/dso"

    set +e
    local _out
    _out=$(cd "$_sandbox" && bash "$SCRIPTS/check-reinvocation.sh" "$_story_id" 2>/dev/null)
    local _rc=$?
    set -e
    rm -rf "$_sandbox"

    local _verdict
    _verdict=$(echo "$_out" | grep '^verdict=' | cut -d= -f2-)
    assert_eq "test_reinvocation_resolved_replan_trigger_returns_all_closed: resolved trigger collapses to all_closed" \
              "all_closed" "$_verdict"
    assert_eq "test_reinvocation_resolved_replan_trigger_returns_all_closed: exits 0" \
              "0" "$_rc"
}

# ─── Run tests ────────────────────────────────────────────────────────────────

test_cycle_state_read_returns_zero_when_absent
test_cycle_state_increment_advances_counter
test_cycle_state_clear_resets_counter
test_cycle_state_stale_file_treated_as_fresh
test_cycle_state_unknown_command_errors

test_tag_guards_lookup_failure_fails_open
test_tag_guards_missing_arg_errors

test_reinvocation_lookup_failure_returns_fresh
test_reinvocation_missing_arg_errors
test_reinvocation_all_lookups_fail_returns_fresh
test_reinvocation_unresolved_replan_trigger_returns_replan_required
test_reinvocation_resolved_replan_trigger_returns_all_closed

print_summary
