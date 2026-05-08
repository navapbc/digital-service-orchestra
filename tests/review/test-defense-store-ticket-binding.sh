#!/usr/bin/env bash
# tests/review/test-defense-store-ticket-binding.sh
# RED tests for plugins/dso/scripts/review-defense-store.sh — ticket-binding enforcement.
#
# All 5 tests MUST FAIL (RED) until review-defense-store.sh is implemented.
# The file under test does not exist yet; sourcing it will fail, which is the
# expected RED signal for tests that require the file.
#
# Usage: bash tests/review/test-defense-store-ticket-binding.sh
# Returns: exit 1 (RED) until implementation is present.

# NOTE: -e intentionally omitted — test functions return non-zero by design
# (they assert against unimplemented features). -e would abort the runner on
# the first expected failure.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"
DEFENSE_STORE="$REPO_ROOT/plugins/dso/scripts/review-defense-store.sh"

source "$REPO_ROOT/tests/lib/assert.sh"

echo "=== test-defense-store-ticket-binding.sh ==="

# =============================================================================
# Test 1 — defense_store_write exits 1 with ticket-binding error when
#           DSO_SESSION_TICKET_ID is unset
# =============================================================================
echo ""
echo "--- test_ticket_binding_missing_env_exits_1 ---"

test_ticket_binding_missing_env_exits_1() {
    _snapshot_fail

    if [[ ! -f "$DEFENSE_STORE" ]]; then
        (( ++FAIL ))
        printf "FAIL: test_ticket_binding_missing_env_exits_1\n  expected: review-defense-store.sh to exist at %s\n  actual:   file not found\n" \
            "$DEFENSE_STORE" >&2
        return
    fi

    local exit_code=0
    local stderr_out
    stderr_out=$(
        # shellcheck source=/dev/null
        unset DSO_SESSION_TICKET_ID
        source "$DEFENSE_STORE"
        defense_store_write '{}' 2>&1
    ) || exit_code=$?

    assert_eq "test_ticket_binding_missing_env_exits_1: exits 1" "1" "$exit_code"
    assert_contains "test_ticket_binding_missing_env_exits_1: stderr contains ticket-binding required" \
        "ticket-binding required" "$stderr_out"

    assert_pass_if_clean "test_ticket_binding_missing_env_exits_1"
}

test_ticket_binding_missing_env_exits_1

# =============================================================================
# Test 2 — defense_store_write does NOT fail with ticket-binding error when
#           DSO_SESSION_TICKET_ID is set (may fail for other reasons — OK for RED)
# =============================================================================
echo ""
echo "--- test_ticket_binding_present_allows_write_attempt ---"

test_ticket_binding_present_allows_write_attempt() {
    _snapshot_fail

    if [[ ! -f "$DEFENSE_STORE" ]]; then
        (( ++FAIL ))
        printf "FAIL: test_ticket_binding_present_allows_write_attempt\n  expected: review-defense-store.sh to exist at %s\n  actual:   file not found\n" \
            "$DEFENSE_STORE" >&2
        return
    fi

    local stderr_out
    stderr_out=$(
        # shellcheck disable=SC2030,SC2031
        export DSO_SESSION_TICKET_ID=TEST-123
        # shellcheck source=/dev/null
        source "$DEFENSE_STORE"
        defense_store_write '{"ticket_id":"TEST-123","prior_finding_id":"f-abc"}' 2>&1
    ) || true   # may fail for reasons other than ticket-binding; capture stderr only

    # The critical assertion: no ticket-binding error when env var IS set
    local has_binding_error=0
    if [[ "$stderr_out" == *"ticket-binding required"* ]]; then
        has_binding_error=1
    fi
    assert_eq "test_ticket_binding_present_allows_write_attempt: no ticket-binding error when DSO_SESSION_TICKET_ID is set" \
        "0" "$has_binding_error"

    assert_pass_if_clean "test_ticket_binding_present_allows_write_attempt"
}

test_ticket_binding_present_allows_write_attempt

# =============================================================================
# Test 3 — defense_store_write rejects defense_text exceeding 4096 characters
# =============================================================================
echo ""
echo "--- test_defense_text_over_4096_chars_rejected ---"

test_defense_text_over_4096_chars_rejected() {
    _snapshot_fail

    if [[ ! -f "$DEFENSE_STORE" ]]; then
        (( ++FAIL ))
        printf "FAIL: test_defense_text_over_4096_chars_rejected\n  expected: review-defense-store.sh to exist at %s\n  actual:   file not found\n" \
            "$DEFENSE_STORE" >&2
        return
    fi

    local exit_code=0
    local stderr_out
    stderr_out=$(
        # shellcheck disable=SC2030,SC2031
        export DSO_SESSION_TICKET_ID=TEST-123
        # shellcheck source=/dev/null
        source "$DEFENSE_STORE"
        record=$(python3 -c "
import json, sys
print(json.dumps({'ticket_id': 'TEST-123', 'prior_finding_id': 'f-abc', 'defense_text': 'x' * 4097}))
")
        defense_store_write "$record" 2>&1
    ) || exit_code=$?

    assert_eq "test_defense_text_over_4096_chars_rejected: exits 1" "1" "$exit_code"
    assert_contains "test_defense_text_over_4096_chars_rejected: stderr contains defense_text exceeds" \
        "defense_text exceeds" "$stderr_out"

    assert_pass_if_clean "test_defense_text_over_4096_chars_rejected"
}

test_defense_text_over_4096_chars_rejected

# =============================================================================
# Test 4 — defense_store_load returns null or empty for a non-existent record
# =============================================================================
echo ""
echo "--- test_load_returns_null_when_no_record_exists ---"

test_load_returns_null_when_no_record_exists() {
    _snapshot_fail

    if [[ ! -f "$DEFENSE_STORE" ]]; then
        (( ++FAIL ))
        printf "FAIL: test_load_returns_null_when_no_record_exists\n  expected: review-defense-store.sh to exist at %s\n  actual:   file not found\n" \
            "$DEFENSE_STORE" >&2
        return
    fi

    local exit_code=0
    local output
    output=$(
        # shellcheck disable=SC2030,SC2031
        export DSO_SESSION_TICKET_ID=TEST-123
        # shellcheck source=/dev/null
        source "$DEFENSE_STORE"
        defense_store_load "f-nonexistent" 2>/dev/null
    ) || exit_code=$?

    assert_eq "test_load_returns_null_when_no_record_exists: exits 0" "0" "$exit_code"

    # Output must be "null" or empty — not a populated record
    local is_null_or_empty=0
    if [[ -z "$output" || "$output" == "null" ]]; then
        is_null_or_empty=1
    fi
    assert_eq "test_load_returns_null_when_no_record_exists: output is null or empty" \
        "1" "$is_null_or_empty"

    assert_pass_if_clean "test_load_returns_null_when_no_record_exists"
}

test_load_returns_null_when_no_record_exists

# =============================================================================
# Test 5 — defense_store_write rejects a record missing severity_history
# =============================================================================
echo ""
echo "--- test_write_requires_severity_history ---"

test_write_requires_severity_history() {
    _snapshot_fail

    if [[ ! -f "$DEFENSE_STORE" ]]; then
        (( ++FAIL ))
        printf "FAIL: test_write_requires_severity_history\n  expected: review-defense-store.sh to exist at %s\n  actual:   file not found\n" \
            "$DEFENSE_STORE" >&2
        return
    fi

    local exit_code=0
    local stderr_out
    stderr_out=$(
        # shellcheck disable=SC2030,SC2031
        export DSO_SESSION_TICKET_ID=TEST-123
        # shellcheck source=/dev/null
        source "$DEFENSE_STORE"
        # Record has required fields but deliberately omits severity_history
        defense_store_write '{"ticket_id":"TEST-123","prior_finding_id":"f-abc","defense_text":"some defense"}' 2>&1
    ) || exit_code=$?

    assert_eq "test_write_requires_severity_history: exits 1 when severity_history absent" "1" "$exit_code"
    assert_contains "test_write_requires_severity_history: stderr mentions severity_history" \
        "severity_history" "$stderr_out"

    assert_pass_if_clean "test_write_requires_severity_history"
}

test_write_requires_severity_history

# ── Summary ───────────────────────────────────────────────────────────────────
print_summary
