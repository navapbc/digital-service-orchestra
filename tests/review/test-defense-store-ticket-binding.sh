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

# =============================================================================
# Test 6 — _defense_compute_fingerprint collapses whitespace before hashing;
#           two strings that differ only in whitespace produce the same digest
# =============================================================================
echo ""
echo "--- test_fingerprint_whitespace_equivalence ---"

test_fingerprint_whitespace_equivalence() {
    _snapshot_fail

    if [[ ! -f "$DEFENSE_STORE" ]]; then
        (( ++FAIL ))
        printf "FAIL: test_fingerprint_whitespace_equivalence\n  expected: review-defense-store.sh to exist at %s\n  actual:   file not found\n" \
            "$DEFENSE_STORE" >&2
        return
    fi

    local hash_a hash_b
    hash_a=$(
        # shellcheck source=/dev/null
        source "$DEFENSE_STORE"
        _defense_compute_fingerprint '  foo  bar  baz  ' 'src/foo.py' '42'
    ) || true
    hash_b=$(
        # shellcheck source=/dev/null
        source "$DEFENSE_STORE"
        _defense_compute_fingerprint 'foo bar baz' 'src/foo.py' '42'
    ) || true

    assert_eq "test_fingerprint_whitespace_equivalence: hashes match after whitespace collapse" \
        "$hash_a" "$hash_b"

    # Sanity: result must look like a 64-char SHA-256 hex string
    local is_sha256=0
    if [[ "$hash_a" =~ ^[0-9a-f]{64}$ ]]; then
        is_sha256=1
    fi
    assert_eq "test_fingerprint_whitespace_equivalence: hash_a is 64-char hex" "1" "$is_sha256"

    assert_pass_if_clean "test_fingerprint_whitespace_equivalence"
}

test_fingerprint_whitespace_equivalence

# =============================================================================
# Test 7 — _defense_compute_fingerprint returns different digests for
#           genuinely different content strings
# =============================================================================
echo ""
echo "--- test_fingerprint_different_content_produces_different_hash ---"

test_fingerprint_different_content_produces_different_hash() {
    _snapshot_fail

    if [[ ! -f "$DEFENSE_STORE" ]]; then
        (( ++FAIL ))
        printf "FAIL: test_fingerprint_different_content_produces_different_hash\n  expected: review-defense-store.sh to exist at %s\n  actual:   file not found\n" \
            "$DEFENSE_STORE" >&2
        return
    fi

    local hash_a hash_b
    hash_a=$(
        # shellcheck source=/dev/null
        source "$DEFENSE_STORE"
        _defense_compute_fingerprint 'line one content' 'src/foo.py' '42'
    ) || true
    hash_b=$(
        # shellcheck source=/dev/null
        source "$DEFENSE_STORE"
        _defense_compute_fingerprint 'line two content' 'src/foo.py' '42'
    ) || true

    local hashes_differ=0
    if [[ "$hash_a" != "$hash_b" ]]; then
        hashes_differ=1
    fi
    assert_eq "test_fingerprint_different_content_produces_different_hash: different content yields different hash" \
        "1" "$hashes_differ"

    assert_pass_if_clean "test_fingerprint_different_content_produces_different_hash"
}

test_fingerprint_different_content_produces_different_hash

# =============================================================================
# Test 8 — defense_store_write embeds a non-empty cited_lines_fingerprint field
#           in the record forwarded to the ticket comment command
# =============================================================================
echo ""
echo "--- test_defense_store_write_embeds_fingerprint_in_output ---"

test_defense_store_write_embeds_fingerprint_in_output() {
    _snapshot_fail

    if [[ ! -f "$DEFENSE_STORE" ]]; then
        (( ++FAIL ))
        printf "FAIL: test_defense_store_write_embeds_fingerprint_in_output\n  expected: review-defense-store.sh to exist at %s\n  actual:   file not found\n" \
            "$DEFENSE_STORE" >&2
        return
    fi

    local captured_output
    captured_output=$(
        # shellcheck disable=SC2030,SC2031
        export DSO_SESSION_TICKET_ID=TEST-123
        export TICKET_CMD="echo"
        # shellcheck source=/dev/null
        source "$DEFENSE_STORE"
        record=$(python3 -c "
import json
print(json.dumps({
    'ticket_id': 'TEST-123',
    'prior_finding_id': 'f-abc',
    'defense_text': 'some defense',
    'severity_history': [{'cycle': 1, 'severity': 'important', 'relation': None}],
    'cited_lines': ['src/foo.py:42:some content']
}))
")
        defense_store_write "$record" 2>/dev/null
    ) || true

    # The output (forwarded to TICKET_CMD=echo) must contain a non-empty
    # cited_lines_fingerprint field
    local has_fingerprint=0
    if python3 -c "
import json, sys
data = json.loads(sys.stdin.read())
fp = data.get('cited_lines_fingerprint', '')
sys.exit(0 if fp else 1)
" <<< "$captured_output" 2>/dev/null; then
        has_fingerprint=1
    fi
    assert_eq "test_defense_store_write_embeds_fingerprint_in_output: cited_lines_fingerprint is non-empty in forwarded record" \
        "1" "$has_fingerprint"

    assert_pass_if_clean "test_defense_store_write_embeds_fingerprint_in_output"
}

test_defense_store_write_embeds_fingerprint_in_output

# ── Summary ───────────────────────────────────────────────────────────────────
print_summary
