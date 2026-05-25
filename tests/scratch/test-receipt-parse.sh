#!/usr/bin/env bash
# tests/scratch/test-receipt-parse.sh
# Behavioral tests for plugins/dso/scripts/receipt-parse.sh
#
# Testing Mode: RED → GREEN
# Asserts that receipt-parse.sh:
#   - Accepts a valid 3-field receipt JSON and exits 0
#   - Rejects missing ticket_id, key, or byte_count (RECEIPT_PARSE_ERROR, non-zero exit)
#   - Rejects extra fields beyond the 3-field schema (RECEIPT_PARSE_ERROR, non-zero exit)
#   - Rejects non-JSON input (RECEIPT_PARSE_ERROR, non-zero exit)
#
# Contract: receipt JSON must be EXACTLY {"ticket_id":"<id>","key":"<k>","byte_count":<N>}
#
# Usage: bash tests/scratch/test-receipt-parse.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"
RECEIPT_PARSE="$REPO_ROOT/plugins/dso/scripts/receipt-parse.sh"

source "$REPO_ROOT/tests/lib/assert.sh"

echo "=== test-receipt-parse.sh: receipt-parse.sh behavioral tests ==="

# ── Preflight ────────────────────────────────────────────────────────────────
if [ ! -f "$RECEIPT_PARSE" ]; then
    echo "FATAL: receipt-parse.sh not found at $RECEIPT_PARSE" >&2
    echo "  Run step 3 to implement the script, then re-run this test." >&2
    exit 1
fi

if [ ! -x "$RECEIPT_PARSE" ]; then
    echo "FATAL: receipt-parse.sh is not executable: $RECEIPT_PARSE" >&2
    echo "  Run: chmod +x $RECEIPT_PARSE" >&2
    exit 1
fi

# ── Constants ─────────────────────────────────────────────────────────────────
SITE_ID="test-site-001"
SUBAGENT="test-subagent"
VALID_TICKET_ID="abcd-1234-efgh-5678"
VALID_KEY="impl-plan-output"
VALID_BYTE_COUNT=4096

# ══════════════════════════════════════════════════════════════════════════════
# Test 1: Valid 3-field receipt → exit 0, no error logged, stdout has id and key
# ══════════════════════════════════════════════════════════════════════════════
echo ""
echo "── Test 1: valid 3-field receipt → exit 0, stdout = ticket_id + key ──"
test_valid_receipt() {
    local payload
    payload=$(printf '{"ticket_id":"%s","key":"%s","byte_count":%d}' \
        "$VALID_TICKET_ID" "$VALID_KEY" "$VALID_BYTE_COUNT")

    local stdout stderr exit_code=0
    stdout=$(printf '%s' "$payload" | bash "$RECEIPT_PARSE" "$SITE_ID" "$SUBAGENT" 2>/tmp/receipt-test-stderr1.txt) \
        || exit_code=$?
    stderr=$(cat /tmp/receipt-test-stderr1.txt)

    _snapshot_fail
    assert_eq "valid receipt: exit 0" "0" "$exit_code"
    assert_contains "valid receipt: stdout contains ticket_id" "$VALID_TICKET_ID" "$stdout"
    assert_contains "valid receipt: stdout contains key" "$VALID_KEY" "$stdout"
    assert_eq "valid receipt: no RECEIPT_PARSE_ERROR in stderr" "" "$stderr"
    assert_pass_if_clean "Test 1: valid 3-field receipt"
}
test_valid_receipt
rm -f /tmp/receipt-test-stderr1.txt

# ══════════════════════════════════════════════════════════════════════════════
# Test 2: Missing ticket_id → RECEIPT_PARSE_ERROR, non-zero exit
# ══════════════════════════════════════════════════════════════════════════════
echo ""
echo "── Test 2: missing ticket_id → RECEIPT_PARSE_ERROR, non-zero exit ──"
test_missing_ticket_id() {
    local payload
    payload=$(printf '{"key":"%s","byte_count":%d}' "$VALID_KEY" "$VALID_BYTE_COUNT")

    local stderr exit_code=0
    printf '%s' "$payload" | bash "$RECEIPT_PARSE" "$SITE_ID" "$SUBAGENT" >/dev/null 2>/tmp/receipt-test-stderr2.txt \
        || exit_code=$?
    stderr=$(cat /tmp/receipt-test-stderr2.txt)

    _snapshot_fail
    assert_ne "missing ticket_id: non-zero exit" "0" "$exit_code"
    assert_contains "missing ticket_id: RECEIPT_PARSE_ERROR in stderr" "RECEIPT_PARSE_ERROR" "$stderr"
    assert_contains "missing ticket_id: site id in stderr" "$SITE_ID" "$stderr"
    assert_contains "missing ticket_id: reason in stderr" "reason=" "$stderr"
    assert_contains "missing ticket_id: byte_count in stderr" "byte_count=" "$stderr"
    assert_pass_if_clean "Test 2: missing ticket_id"
}
test_missing_ticket_id
rm -f /tmp/receipt-test-stderr2.txt

# ══════════════════════════════════════════════════════════════════════════════
# Test 3: Missing key → RECEIPT_PARSE_ERROR, non-zero exit
# ══════════════════════════════════════════════════════════════════════════════
echo ""
echo "── Test 3: missing key → RECEIPT_PARSE_ERROR, non-zero exit ──"
test_missing_key() {
    local payload
    payload=$(printf '{"ticket_id":"%s","byte_count":%d}' "$VALID_TICKET_ID" "$VALID_BYTE_COUNT")

    local stderr exit_code=0
    printf '%s' "$payload" | bash "$RECEIPT_PARSE" "$SITE_ID" "$SUBAGENT" >/dev/null 2>/tmp/receipt-test-stderr3.txt \
        || exit_code=$?
    stderr=$(cat /tmp/receipt-test-stderr3.txt)

    _snapshot_fail
    assert_ne "missing key: non-zero exit" "0" "$exit_code"
    assert_contains "missing key: RECEIPT_PARSE_ERROR in stderr" "RECEIPT_PARSE_ERROR" "$stderr"
    assert_contains "missing key: site id in stderr" "$SITE_ID" "$stderr"
    assert_contains "missing key: reason in stderr" "reason=" "$stderr"
    assert_contains "missing key: byte_count in stderr" "byte_count=" "$stderr"
    assert_pass_if_clean "Test 3: missing key"
}
test_missing_key
rm -f /tmp/receipt-test-stderr3.txt

# ══════════════════════════════════════════════════════════════════════════════
# Test 4: Missing byte_count → RECEIPT_PARSE_ERROR, non-zero exit
# ══════════════════════════════════════════════════════════════════════════════
echo ""
echo "── Test 4: missing byte_count → RECEIPT_PARSE_ERROR, non-zero exit ──"
test_missing_byte_count() {
    local payload
    payload=$(printf '{"ticket_id":"%s","key":"%s"}' "$VALID_TICKET_ID" "$VALID_KEY")

    local stderr exit_code=0
    printf '%s' "$payload" | bash "$RECEIPT_PARSE" "$SITE_ID" "$SUBAGENT" >/dev/null 2>/tmp/receipt-test-stderr4.txt \
        || exit_code=$?
    stderr=$(cat /tmp/receipt-test-stderr4.txt)

    _snapshot_fail
    assert_ne "missing byte_count: non-zero exit" "0" "$exit_code"
    assert_contains "missing byte_count: RECEIPT_PARSE_ERROR in stderr" "RECEIPT_PARSE_ERROR" "$stderr"
    assert_contains "missing byte_count: site id in stderr" "$SITE_ID" "$stderr"
    assert_contains "missing byte_count: reason in stderr" "reason=" "$stderr"
    assert_contains "missing byte_count: byte_count in stderr" "byte_count=" "$stderr"
    assert_pass_if_clean "Test 4: missing byte_count"
}
test_missing_byte_count
rm -f /tmp/receipt-test-stderr4.txt

# ══════════════════════════════════════════════════════════════════════════════
# Test 5: Extra field (draft_body) → RECEIPT_PARSE_ERROR — sub-agent leaked draft
# ══════════════════════════════════════════════════════════════════════════════
echo ""
echo "── Test 5: extra field draft_body → RECEIPT_PARSE_ERROR (sub-agent leaked draft) ──"
test_extra_field_draft_body() {
    local payload
    payload=$(printf '{"ticket_id":"%s","key":"%s","byte_count":%d,"draft_body":"this is a leaked payload"}' \
        "$VALID_TICKET_ID" "$VALID_KEY" "$VALID_BYTE_COUNT")

    local stderr exit_code=0
    printf '%s' "$payload" | bash "$RECEIPT_PARSE" "$SITE_ID" "$SUBAGENT" >/dev/null 2>/tmp/receipt-test-stderr5.txt \
        || exit_code=$?
    stderr=$(cat /tmp/receipt-test-stderr5.txt)

    _snapshot_fail
    assert_ne "extra field: non-zero exit" "0" "$exit_code"
    assert_contains "extra field: RECEIPT_PARSE_ERROR in stderr" "RECEIPT_PARSE_ERROR" "$stderr"
    assert_contains "extra field: site id in stderr" "$SITE_ID" "$stderr"
    assert_contains "extra field: reason in stderr" "reason=" "$stderr"
    assert_contains "extra field: byte_count in stderr" "byte_count=" "$stderr"
    assert_pass_if_clean "Test 5: extra field draft_body rejected"
}
test_extra_field_draft_body
rm -f /tmp/receipt-test-stderr5.txt

# ══════════════════════════════════════════════════════════════════════════════
# Test 6: Non-JSON input → RECEIPT_PARSE_ERROR, non-zero exit
# ══════════════════════════════════════════════════════════════════════════════
echo ""
echo "── Test 6: non-JSON input → RECEIPT_PARSE_ERROR, non-zero exit ──"
test_non_json_input() {
    local payload="this is not json at all"

    local stderr exit_code=0
    printf '%s' "$payload" | bash "$RECEIPT_PARSE" "$SITE_ID" "$SUBAGENT" >/dev/null 2>/tmp/receipt-test-stderr6.txt \
        || exit_code=$?
    stderr=$(cat /tmp/receipt-test-stderr6.txt)

    _snapshot_fail
    assert_ne "non-JSON: non-zero exit" "0" "$exit_code"
    assert_contains "non-JSON: RECEIPT_PARSE_ERROR in stderr" "RECEIPT_PARSE_ERROR" "$stderr"
    assert_contains "non-JSON: site id in stderr" "$SITE_ID" "$stderr"
    assert_contains "non-JSON: reason in stderr" "reason=" "$stderr"
    assert_contains "non-JSON: byte_count in stderr" "byte_count=" "$stderr"
    assert_pass_if_clean "Test 6: non-JSON input rejected"
}
test_non_json_input
rm -f /tmp/receipt-test-stderr6.txt

# ══════════════════════════════════════════════════════════════════════════════
# Print summary
# ══════════════════════════════════════════════════════════════════════════════
print_summary
