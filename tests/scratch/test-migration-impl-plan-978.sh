#!/usr/bin/env bash
# tests/scratch/test-migration-impl-plan-978.sh
# Behavioral tests verifying that implementation-plan/SKILL.md:978 (Step 4
# Remediation Re-dispatch block) has been migrated to the scratch CLI +
# receipt-only contract.
#
# Testing Mode: RED → GREEN
#
# Asserts:
#   1. No --artifact sub-agent-prompt handoffs remain in the Remediation Re-dispatch block
#   2. scratch set command is present in the sub-agent output_contract block
#   3. output_contract XML tag is present (Prompt Alignment Finding 3)
#   4. SCRATCH_MISS guard is co-located with the scratch get call (Finding 1)
#   5. SCRATCH_TICKET_ID and SCRATCH_KEY namespacing are present (Finding 4)
#   6. Inline cleanup directive in SCRATCH_MISS exit branch is present (Finding 5)
#   7. Structured-output disambiguation (negative INLINE example) is present (Finding 2)
#   8. receipt-parse.sh invocation with site id implementation-plan:step4 is present
#   9. RECEIPT_PARSE_ERROR escalation halt is present
#  10. Authoritative key implementation-plan:step4:plan-review-draft is referenced
#  11. A sample valid receipt round-trips through receipt-parse.sh correctly
#  12. Malformed receipt (extra field) is rejected with RECEIPT_PARSE_ERROR
#
# Usage: bash tests/scratch/test-migration-impl-plan-978.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"
SKILL_MD="$REPO_ROOT/plugins/dso/skills/implementation-plan/SKILL.md"
RECEIPT_PARSE="$REPO_ROOT/plugins/dso/scripts/receipt-parse.sh"

source "$REPO_ROOT/tests/lib/assert.sh"

echo "=== test-migration-impl-plan-978.sh: impl-plan Step 4 Remediation Re-dispatch scratch migration ==="

# ── Preflight ────────────────────────────────────────────────────────────────
if [ ! -f "$SKILL_MD" ]; then
    echo "FATAL: implementation-plan/SKILL.md not found at $SKILL_MD" >&2
    exit 1
fi

if [ ! -f "$RECEIPT_PARSE" ]; then
    echo "FATAL: receipt-parse.sh not found at $RECEIPT_PARSE" >&2
    exit 1
fi

if [ ! -x "$RECEIPT_PARSE" ]; then
    echo "FATAL: receipt-parse.sh is not executable: $RECEIPT_PARSE" >&2
    exit 1
fi

# Helper: extract the Step 4 Remediation Re-dispatch section from SKILL.md
# (from "### Remediation Re-dispatch" under "## Step 4" through the next
# "**Remediation loop protocol" heading or "---" separator)
_get_remediation_redispatch_section() {
    python3 - "$SKILL_MD" <<'PYEOF'
import sys, re
with open(sys.argv[1]) as f:
    text = f.read()
# Find the Step 4 block first, then the Remediation Re-dispatch subsection within it
step4_match = re.search(r'^## Step 4:.*?(?=^## Step \d|^---\s*\Z)', text, re.MULTILINE | re.DOTALL)
if not step4_match:
    print("")
    sys.exit(0)
step4_text = step4_match.group(0)
# Within Step 4, find the Remediation Re-dispatch subsection
redispatch_match = re.search(
    r'^### Remediation Re-dispatch.*?(?=^\*\*Remediation loop protocol|^### |\Z)',
    step4_text, re.MULTILINE | re.DOTALL
)
if redispatch_match:
    print(redispatch_match.group(0))
else:
    print("")
PYEOF
}

SECTION=$(_get_remediation_redispatch_section)

if [ -z "$SECTION" ]; then
    echo "FATAL: Could not extract '### Remediation Re-dispatch' section from Step 4 in $SKILL_MD" >&2
    exit 1
fi

# ══════════════════════════════════════════════════════════════════════════════
# Test 1: No --artifact sub-agent-prompt handoffs in Remediation Re-dispatch section
# ══════════════════════════════════════════════════════════════════════════════
echo ""
echo "── Test 1: no --artifact sub-agent-prompt handoffs in Remediation Re-dispatch block ──"
_snapshot_fail
artifact_hits=$(echo "$SECTION" | grep -c -- '--artifact ' || echo "0")
# The append_review_cycle.py helper lives in the *cycle recorder* block (which comes
# after "### Remediation Re-dispatch"), not in the Remediation Re-dispatch section itself.
assert_eq "no --artifact in Remediation Re-dispatch block" "0" "$artifact_hits"
assert_pass_if_clean "Test 1: no --artifact sub-agent-prompt handoffs"

# ══════════════════════════════════════════════════════════════════════════════
# Test 2: scratch set command present in sub-agent output_contract
# ══════════════════════════════════════════════════════════════════════════════
echo ""
echo "── Test 2: ticket-scratch.sh set present in sub-agent output_contract ──"
_snapshot_fail
set_present=$(echo "$SECTION" | grep -c 'ticket-scratch.sh.*set\|scratch.*set' || echo "0")
assert_ne "scratch set present in Remediation Re-dispatch block" "0" "$set_present"
assert_pass_if_clean "Test 2: scratch set present"

# ══════════════════════════════════════════════════════════════════════════════
# Test 3: output_contract XML tag present (Prompt Alignment Finding 3)
# ══════════════════════════════════════════════════════════════════════════════
echo ""
echo "── Test 3: <output_contract> XML tag present (Prompt Alignment Finding 3) ──"
_snapshot_fail
oc_open=$(echo "$SECTION" | grep -c '<output_contract>' || echo "0")
oc_close=$(echo "$SECTION" | grep -c '</output_contract>' || echo "0")
assert_ne "output_contract opening tag present" "0" "$oc_open"
assert_ne "output_contract closing tag present" "0" "$oc_close"
assert_pass_if_clean "Test 3: output_contract XML tag"

# ══════════════════════════════════════════════════════════════════════════════
# Test 4: SCRATCH_MISS guard co-located with scratch get (Prompt Alignment Finding 1)
# ══════════════════════════════════════════════════════════════════════════════
echo ""
echo "── Test 4: SCRATCH_MISS guard co-located with scratch get (Finding 1) ──"
_snapshot_fail
scratch_miss=$(echo "$SECTION" | grep -c 'SCRATCH_MISS' || echo "0")
assert_ne "SCRATCH_MISS guard present" "0" "$scratch_miss"
# Also verify the get call is present
scratch_get=$(echo "$SECTION" | grep -c 'ticket-scratch.sh.*get\|scratch.*get' || echo "0")
assert_ne "scratch get call present" "0" "$scratch_get"
assert_pass_if_clean "Test 4: SCRATCH_MISS guard co-located with get"

# ══════════════════════════════════════════════════════════════════════════════
# Test 5: SCRATCH_TICKET_ID and SCRATCH_KEY namespacing present (Finding 4)
# ══════════════════════════════════════════════════════════════════════════════
echo ""
echo "── Test 5: SCRATCH_TICKET_ID and SCRATCH_KEY namespacing (Prompt Alignment Finding 4) ──"
_snapshot_fail
ticket_id_ns=$(echo "$SECTION" | grep -c 'SCRATCH_TICKET_ID' || echo "0")
key_ns=$(echo "$SECTION" | grep -c 'SCRATCH_KEY' || echo "0")
assert_ne "SCRATCH_TICKET_ID namespacing present" "0" "$ticket_id_ns"
assert_ne "SCRATCH_KEY namespacing present" "0" "$key_ns"
assert_pass_if_clean "Test 5: SCRATCH_TICKET_ID/SCRATCH_KEY namespacing"

# ══════════════════════════════════════════════════════════════════════════════
# Test 6: Inline cleanup directive in SCRATCH_MISS exit branch (Finding 5)
# ══════════════════════════════════════════════════════════════════════════════
echo ""
echo "── Test 6: inline cleanup directive in SCRATCH_MISS exit branch (Finding 5) ──"
_snapshot_fail
# The cleanup directive clears the scratch key in the MISS/error branch
clear_in_miss=$(echo "$SECTION" | grep -c 'ticket-scratch.sh.*clear\|scratch.*clear' || echo "0")
assert_ne "scratch clear (inline cleanup) present in Remediation Re-dispatch block" "0" "$clear_in_miss"
assert_pass_if_clean "Test 6: inline cleanup directive"

# ══════════════════════════════════════════════════════════════════════════════
# Test 7: Structured-output disambiguation (NEGATIVE inline example) (Finding 2)
# ══════════════════════════════════════════════════════════════════════════════
echo ""
echo "── Test 7: structured-output disambiguation negative example (Finding 2) ──"
_snapshot_fail
# The output_contract block must contain a NEGATIVE EXAMPLE marking the inline-return
# pattern as a contract violation
neg_example=$(echo "$SECTION" | grep -c 'NEGATIVE EXAMPLE\|contract violation' || echo "0")
assert_ne "negative inline-return example present" "0" "$neg_example"
# The disambiguation note must also clarify that SCRATCH_MISS != inline fallback signal
scratch_miss_not_inline=$(echo "$SECTION" | grep -c 'SCRATCH_MISS.*not.*inline\|SCRATCH_MISS.*not a.*signal\|SCRATCH_MISS is not.*signal' || echo "0")
assert_ne "SCRATCH_MISS not-inline disambiguation present" "0" "$scratch_miss_not_inline"
assert_pass_if_clean "Test 7: structured-output disambiguation"

# ══════════════════════════════════════════════════════════════════════════════
# Test 8: receipt-parse.sh invocation with site id implementation-plan:step4
# ══════════════════════════════════════════════════════════════════════════════
echo ""
echo "── Test 8: receipt-parse.sh invocation with site implementation-plan:step4 ──"
_snapshot_fail
receipt_parse_call=$(echo "$SECTION" | grep -c 'receipt-parse.sh' || echo "0")
assert_ne "receipt-parse.sh call present" "0" "$receipt_parse_call"
site_id_in_call=$(echo "$SECTION" | grep -c 'implementation-plan:step4' || echo "0")
assert_ne "site id implementation-plan:step4 present" "0" "$site_id_in_call"
assert_pass_if_clean "Test 8: receipt-parse.sh with implementation-plan:step4 site id"

# ══════════════════════════════════════════════════════════════════════════════
# Test 9: RECEIPT_PARSE_ERROR escalation halt present
# ══════════════════════════════════════════════════════════════════════════════
echo ""
echo "── Test 9: RECEIPT_PARSE_ERROR escalation halt present ──"
_snapshot_fail
rpe_halt=$(echo "$SECTION" | grep -c 'RECEIPT_PARSE_ERROR' || echo "0")
assert_ne "RECEIPT_PARSE_ERROR halt present" "0" "$rpe_halt"
assert_pass_if_clean "Test 9: RECEIPT_PARSE_ERROR escalation halt"

# ══════════════════════════════════════════════════════════════════════════════
# Test 10: Authoritative key implementation-plan:step4:plan-review-draft is referenced
# ══════════════════════════════════════════════════════════════════════════════
echo ""
echo "── Test 10: authoritative key implementation-plan:step4:plan-review-draft referenced ──"
_snapshot_fail
auth_key=$(echo "$SECTION" | grep -c 'implementation-plan:step4:plan-review-draft' || echo "0")
assert_ne "authoritative scratch key implementation-plan:step4:plan-review-draft present" "0" "$auth_key"
assert_pass_if_clean "Test 10: authoritative key implementation-plan:step4:plan-review-draft"

# ══════════════════════════════════════════════════════════════════════════════
# Test 11: Sample valid receipt round-trips through receipt-parse.sh (exit 0)
# ══════════════════════════════════════════════════════════════════════════════
echo ""
echo "── Test 11: sample valid receipt round-trips through receipt-parse.sh ──"
test_receipt_roundtrip() {
    local payload
    payload='{"ticket_id":"abcd-1234-efgh-5678","key":"implementation-plan:step4:plan-review-draft","byte_count":3072}'

    local stdout stderr exit_code=0
    _tmpfile=$(mktemp "${TMPDIR:-/tmp}/receipt-parse-test-XXXXXX".txt)
    stdout=$(printf '%s' "$payload" | bash "$RECEIPT_PARSE" "implementation-plan:step4" "dso:task-decomposer" 2>"$_tmpfile") \
        || exit_code=$?
    stderr=$(cat "$_tmpfile")
    rm -f "$_tmpfile"

    _snapshot_fail
    assert_eq "valid impl-plan:step4 receipt: exit 0" "0" "$exit_code"
    assert_contains "valid impl-plan:step4 receipt: stdout contains ticket_id" "abcd-1234-efgh-5678" "$stdout"
    assert_contains "valid impl-plan:step4 receipt: stdout contains key" "implementation-plan:step4:plan-review-draft" "$stdout"
    assert_eq "valid impl-plan:step4 receipt: no RECEIPT_PARSE_ERROR in stderr" "" "$stderr"
    assert_pass_if_clean "Test 11: valid receipt round-trip"
}
test_receipt_roundtrip

# ══════════════════════════════════════════════════════════════════════════════
# Test 12: Malformed receipt (extra field) rejected with RECEIPT_PARSE_ERROR
# ══════════════════════════════════════════════════════════════════════════════
echo ""
echo "── Test 12: extra-field receipt (payload leak) rejected with RECEIPT_PARSE_ERROR ──"
test_extra_field_rejected() {
    local payload
    payload='{"ticket_id":"abcd-1234-efgh-5678","key":"implementation-plan:step4:plan-review-draft","byte_count":3072,"task_drafts":[]}'

    local stderr exit_code=0
    _tmpfile=$(mktemp "${TMPDIR:-/tmp}/receipt-parse-test-XXXXXX".txt)
    printf '%s' "$payload" | bash "$RECEIPT_PARSE" "implementation-plan:step4" "dso:task-decomposer" >/dev/null 2>"$_tmpfile" \
        || exit_code=$?
    stderr=$(cat "$_tmpfile")
    rm -f "$_tmpfile"

    _snapshot_fail
    assert_ne "extra-field receipt: non-zero exit" "0" "$exit_code"
    assert_contains "extra-field receipt: RECEIPT_PARSE_ERROR in stderr" "RECEIPT_PARSE_ERROR" "$stderr"
    assert_contains "extra-field receipt: site id in stderr" "implementation-plan:step4" "$stderr"
    assert_pass_if_clean "Test 12: extra-field receipt rejected"
}
test_extra_field_rejected

print_summary
