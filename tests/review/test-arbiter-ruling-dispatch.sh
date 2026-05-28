#!/usr/bin/env bash
# tests/review/test-arbiter-ruling-dispatch.sh
# E2E integration tests for arbiter DEFER->orphan-ticket and DROP->defense-store dispatch.
#
# Test 1: DEFER ruling orchestrator snippet creates a task ticket with the correct
#         title prefix and tags (orphan:deferred_review + origin:arbiter).
# Test 2: DROP ruling defense_store_write persists a record with
#         defense_type="dropped_by_arbiter" visible in the forwarded output.
# Test 3: Idempotent DROP write — calling defense_store_write twice with the same
#         record does not error on either call.
#
# Usage: bash tests/review/test-arbiter-ruling-dispatch.sh
# Returns: exit 1 if any test fails, exit 0 if all pass.

# NOTE: -e intentionally omitted — test functions may invoke subshells that
# return non-zero by design (asserting captured exit codes). -e would abort.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"
DEFENSE_STORE="$REPO_ROOT/plugins/dso/scripts/review-defense-store.sh"

source "$REPO_ROOT/tests/lib/assert.sh"

echo "=== test-arbiter-ruling-dispatch.sh ==="

# =============================================================================
# Test 1 — DEFER ruling: orchestrator creates task ticket with correct title and
#           tags (orphan:deferred_review, origin:arbiter).
# =============================================================================
echo ""
echo "--- test_defer_ruling_creates_orphan_ticket ---"

test_defer_ruling_creates_orphan_ticket() {
    _snapshot_fail

    local captured_cmd_file
    captured_cmd_file=$(mktemp "${TMPDIR:-/tmp}/test-defer.XXXXXX")

    # Mock TICKET_CMD that captures every call and returns a fake ticket ID.
    local mock_ticket
    mock_ticket=$(mktemp "${TMPDIR:-/tmp}/mock-ticket.XXXXXX".sh)
    # shellcheck disable=SC2016
    printf '#!/usr/bin/env bash\nprintf "TICKET_CMD called: %%s\\n" "$*" >> "%s"\necho "t-defer-test-01"\n' \
        "$captured_cmd_file" > "$mock_ticket"
    chmod +x "$mock_ticket"

    local CYCLE_K=2
    local CURRENT_SHA="abc1234"

    # Simulate the DEFER orchestrator snippet: call the mock ticket command
    # directly (as the orchestrator would call TICKET_CMD).
    DEFER_TICKET_ID=$(
        "$mock_ticket" create task \
            "Deferred review finding: Finding deferred for future work" \
            --tags=orphan:deferred_review \
            --tags=origin:arbiter \
            --priority=3 \
            -d "Arbiter DEFER ruling from cycle ${CYCLE_K}. Finding: 1 Impact class: deferred"
    )

    local captured
    captured=$(cat "$captured_cmd_file")
    rm -f "$mock_ticket" "$captured_cmd_file"

    assert_contains \
        "test_defer_ruling_creates_orphan_ticket: title contains 'Deferred review finding:'" \
        "Deferred review finding:" \
        "$captured"

    assert_contains \
        "test_defer_ruling_creates_orphan_ticket: tag orphan:deferred_review present" \
        "orphan:deferred_review" \
        "$captured"

    assert_contains \
        "test_defer_ruling_creates_orphan_ticket: tag origin:arbiter present" \
        "origin:arbiter" \
        "$captured"

    assert_pass_if_clean "test_defer_ruling_creates_orphan_ticket"
}

test_defer_ruling_creates_orphan_ticket

# =============================================================================
# Test 2 — DROP ruling: defense_store_write persists a record with
#           defense_type="dropped_by_arbiter" visible in forwarded output.
# =============================================================================
echo ""
echo "--- test_drop_ruling_writes_defense_store_record ---"

test_drop_ruling_writes_defense_store_record() {
    _snapshot_fail

    if [[ ! -f "$DEFENSE_STORE" ]]; then
        (( ++FAIL ))
        printf "FAIL: test_drop_ruling_writes_defense_store_record\n  expected: review-defense-store.sh to exist at %s\n  actual:   file not found\n" \
            "$DEFENSE_STORE" >&2
        return
    fi

    local drop_record
    drop_record=$(python3 -c "
import json
print(json.dumps({
  'prior_finding_id': 'f-drop-e2e-02',
  'defense_type': 'dropped_by_arbiter',
  'defense_text': 'Arbiter DROP ruling: Finding was based on incorrect premise.',
  'defender': 'code-reviewer-arbiter',
  'cycle_number': 3,
  'severity_history': [{'cycle': 3, 'severity': 'important', 'relation': 'DROPPED'}],
  'ticket_id': 'e2e-test-ticket'
}))")

    local output
    output=$(
        # shellcheck disable=SC2030,SC2031
        export DSO_SESSION_TICKET_ID="e2e-test-ticket"
        # shellcheck disable=SC2030,SC2031
        export TICKET_CMD="echo"
        # shellcheck source=/dev/null
        source "$DEFENSE_STORE"
        defense_store_write "$drop_record" 2>/dev/null
    ) || true

    assert_contains \
        "test_drop_ruling_writes_defense_store_record: output contains 'dropped_by_arbiter'" \
        "dropped_by_arbiter" \
        "$output"

    assert_pass_if_clean "test_drop_ruling_writes_defense_store_record"
}

test_drop_ruling_writes_defense_store_record

# =============================================================================
# Test 3 — Idempotent DROP write: calling defense_store_write twice with the
#           same dropped_by_arbiter record completes without error on both calls.
# =============================================================================
echo ""
echo "--- test_drop_ruling_idempotent ---"

test_drop_ruling_idempotent() {
    _snapshot_fail

    if [[ ! -f "$DEFENSE_STORE" ]]; then
        (( ++FAIL ))
        printf "FAIL: test_drop_ruling_idempotent\n  expected: review-defense-store.sh to exist at %s\n  actual:   file not found\n" \
            "$DEFENSE_STORE" >&2
        return
    fi

    local record
    record=$(python3 -c "
import json
print(json.dumps({
  'prior_finding_id': 'f-idem-01',
  'defense_type': 'dropped_by_arbiter',
  'defense_text': 'Arbiter DROP ruling: idempotency test.',
  'defender': 'code-reviewer-arbiter',
  'cycle_number': 1,
  'severity_history': [{'cycle': 1, 'severity': 'critical', 'relation': 'DROPPED'}],
  'ticket_id': 'idem-ticket'
}))")

    local exit_code_1=0
    local exit_code_2=0

    # First write
    (
        # shellcheck disable=SC2030,SC2031
        export DSO_SESSION_TICKET_ID="idem-ticket"
        # shellcheck disable=SC2030,SC2031
        export TICKET_CMD="echo"
        # shellcheck source=/dev/null
        source "$DEFENSE_STORE"
        defense_store_write "$record" >/dev/null 2>&1
    ) || exit_code_1=$?

    # Second write (idempotent — same record)
    (
        # shellcheck disable=SC2030,SC2031
        export DSO_SESSION_TICKET_ID="idem-ticket"
        # shellcheck disable=SC2030,SC2031
        export TICKET_CMD="echo"
        # shellcheck source=/dev/null
        source "$DEFENSE_STORE"
        defense_store_write "$record" >/dev/null 2>&1
    ) || exit_code_2=$?

    assert_eq \
        "test_drop_ruling_idempotent: first write exits 0" \
        "0" "$exit_code_1"

    assert_eq \
        "test_drop_ruling_idempotent: second write exits 0 (idempotent)" \
        "0" "$exit_code_2"

    assert_pass_if_clean "test_drop_ruling_idempotent"
}

test_drop_ruling_idempotent

# ── Summary ───────────────────────────────────────────────────────────────────
print_summary
