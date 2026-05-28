#!/usr/bin/env bash
# tests/review/test-defense-store-dropped-by-arbiter.sh
# RED tests for forward-compatibility of defense_type in review-defense-store.sh.
#
# Test 1: defense_store_load handles an unknown/future defense_type gracefully
#         (does not crash when encountering unrecognized enum values).
# Test 2: defense_store_write persists a record with defense_type="dropped_by_arbiter"
#         and that value appears in the output.
#
# Both tests MUST FAIL (RED) until implementation supports dropped_by_arbiter
# defense_type and the forward-compat reader behaviour is confirmed.
#
# Usage: bash tests/review/test-defense-store-dropped-by-arbiter.sh
# Returns: exit 1 (RED) until implementation is present and correct.

# NOTE: -e intentionally omitted — test functions return non-zero by design
# (they assert against unimplemented features). -e would abort the runner on
# the first expected failure.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"
DEFENSE_STORE="$REPO_ROOT/plugins/dso/scripts/review-defense-store.sh"

source "$REPO_ROOT/tests/lib/assert.sh"

echo "=== test-defense-store-dropped-by-arbiter.sh ==="

# =============================================================================
# Test 1 — defense_store_load does NOT crash when a DEFENSE_RECORD comment
#           contains an unknown/future defense_type value ("unknown_future_value").
#           Reader must be forward-compatible: exit 0, non-null output.
# =============================================================================
echo ""
echo "--- test_defense_store_drops_unknown_defense_type_gracefully ---"

test_defense_store_drops_unknown_defense_type_gracefully() {
    _snapshot_fail

    if [[ ! -f "$DEFENSE_STORE" ]]; then
        (( ++FAIL ))
        printf "FAIL: test_defense_store_drops_unknown_defense_type_gracefully\n  expected: review-defense-store.sh to exist at %s\n  actual:   file not found\n" \
            "$DEFENSE_STORE" >&2
        return
    fi

    # Build a ticket JSON whose sole comment contains a DEFENSE_RECORD with an
    # unrecognized defense_type — simulating a record written by a future version.
    local ticket_json
    ticket_json=$(python3 -c "
import json
record = {
    'prior_finding_id': 'f-future-type',
    'defense_text': 'This defense was written by a future agent version.',
    'defense_type': 'unknown_future_value',
    'severity_history': [{'cycle': 1, 'severity': 'important', 'relation': None}],
    'ticket_id': 'TEST-FUTURE'
}
ticket = {
    'id': 'TEST-FUTURE',
    'comments': ['DEFENSE_RECORD: ' + json.dumps(record)]
}
print(json.dumps(ticket))
")

    # Write a stub ticket-cmd script that returns the pre-built ticket JSON on 'show'.
    # Use a temp file so the function is visible to the subshell without function export.
    local stub_cmd json_file
    stub_cmd=$(mktemp "${TMPDIR:-/tmp}/dso-ticket-stub.XXXXXX")
    json_file=$(mktemp "${TMPDIR:-/tmp}/dso-ticket-json.XXXXXX")
    printf '%s\n' "$ticket_json" > "$json_file"
    # shellcheck disable=SC2016
    printf '#!/usr/bin/env bash\nif [[ "${1:-}" == "show" ]]; then cat "%s"; fi\n' "$json_file" > "$stub_cmd"
    chmod +x "$stub_cmd"

    local exit_code=0
    local output
    output=$(
        # shellcheck disable=SC2030
        export DSO_SESSION_TICKET_ID="TEST-FUTURE"
        # shellcheck disable=SC2030
        export TICKET_CMD="$stub_cmd"
        # shellcheck source=/dev/null
        source "$DEFENSE_STORE"
        defense_store_load "f-future-type" 2>/dev/null
    ) || exit_code=$?

    rm -f "$stub_cmd" "$json_file"

    # Must not crash (exit 0)
    assert_eq "test_defense_store_drops_unknown_defense_type_gracefully: exits 0 on unknown defense_type" \
        "0" "$exit_code"

    # Output must be non-null — the record should be returned, not swallowed
    local is_non_null=0
    if [[ -n "$output" && "$output" != "null" ]]; then
        is_non_null=1
    fi
    assert_eq "test_defense_store_drops_unknown_defense_type_gracefully: output is non-null (record returned gracefully)" \
        "1" "$is_non_null"

    assert_pass_if_clean "test_defense_store_drops_unknown_defense_type_gracefully"
}

test_defense_store_drops_unknown_defense_type_gracefully

# =============================================================================
# Test 2 — defense_store_write persists a record with defense_type="dropped_by_arbiter"
#           and the value appears verbatim in the enriched JSON forwarded to TICKET_CMD.
# =============================================================================
echo ""
echo "--- test_defense_store_write_persists_dropped_by_arbiter ---"

test_defense_store_write_persists_dropped_by_arbiter() {
    _snapshot_fail

    if [[ ! -f "$DEFENSE_STORE" ]]; then
        (( ++FAIL ))
        printf "FAIL: test_defense_store_write_persists_dropped_by_arbiter\n  expected: review-defense-store.sh to exist at %s\n  actual:   file not found\n" \
            "$DEFENSE_STORE" >&2
        return
    fi

    local captured_output
    captured_output=$(
        # shellcheck disable=SC2031
        export DSO_SESSION_TICKET_ID="TEST-ARBITER"
        # TICKET_CMD=echo: the 'comment' subcommand will be called as:
        #   echo comment TEST-ARBITER "DEFENSE_RECORD: {...}"
        # stdout will contain all args joined by space — sufficient to assert
        # that "dropped_by_arbiter" appears.
        # shellcheck disable=SC2031
        export TICKET_CMD="echo"
        # shellcheck source=/dev/null
        source "$DEFENSE_STORE"
        record=$(python3 -c "
import json
print(json.dumps({
    'ticket_id': 'TEST-ARBITER',
    'prior_finding_id': 'f-arbiter-001',
    'defense_text': 'Finding is being dropped by the arbiter due to policy override.',
    'defense_type': 'dropped_by_arbiter',
    'severity_history': [{'cycle': 2, 'severity': 'important', 'relation': None}]
}))
")
        defense_store_write "\$record" 2>/dev/null
    ) || true

    # The output forwarded to TICKET_CMD must contain "dropped_by_arbiter"
    assert_contains "test_defense_store_write_persists_dropped_by_arbiter: output contains dropped_by_arbiter" \
        "dropped_by_arbiter" "$captured_output"

    assert_pass_if_clean "test_defense_store_write_persists_dropped_by_arbiter"
}

test_defense_store_write_persists_dropped_by_arbiter

# ── Summary ───────────────────────────────────────────────────────────────────
print_summary
