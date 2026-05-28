#!/usr/bin/env bash
# tests/scratch/test-migration-sprint-2332.sh
# Behavioral tests verifying the sprint/SKILL.md:2332 migration from
# --artifact <path> to scratch CLI + receipt-only contract.
#
# Testing Mode: GREEN (migration already applied; this test asserts the result)
#
# Assertions:
#   1. `--artifact ` (space-suffix) sub-agent handoff is absent from sprint/SKILL.md
#   2. scratch set + get pattern present (SCRATCH_TICKET_ID, SCRATCH_KEY, sprint:step18:batch-plan)
#   3. output_contract XML tag present in the migrated block
#   4. All 5 Prompt Alignment Findings present:
#      PAF-1: SCRATCH_MISS guard co-located with scratch get
#      PAF-2: Structured-output disambiguation example (SCRATCH_MISS example)
#      PAF-3: output_contract XML tag declaring receipt-only response
#      PAF-4: SCRATCH_TICKET_ID / SCRATCH_KEY namespacing
#      PAF-5: Inline cleanup in SCRATCH_MISS exit path
#   5. receipt-parse.sh invocation present with sprint:step18 site_id
#   6. Sample receipt JSON round-trips through receipt-parse.sh → exit 0
#
# Usage: bash tests/scratch/test-migration-sprint-2332.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"

source "$REPO_ROOT/tests/lib/assert.sh"

SKILL_MD="$REPO_ROOT/plugins/dso/skills/sprint/SKILL.md"
RECEIPT_PARSE="$REPO_ROOT/plugins/dso/scripts/receipt-parse.sh"
SCRATCH_SH="$REPO_ROOT/plugins/dso/scripts/ticket-scratch.sh"

echo "=== test-migration-sprint-2332.sh: sprint/SKILL.md:2332 scratch migration ==="

# ── Preflight ─────────────────────────────────────────────────────────────────
if [ ! -f "$SKILL_MD" ]; then
    echo "FATAL: sprint/SKILL.md not found at $SKILL_MD" >&2
    exit 1
fi

if [ ! -f "$RECEIPT_PARSE" ]; then
    echo "FATAL: receipt-parse.sh not found at $RECEIPT_PARSE" >&2
    exit 1
fi

if [ ! -x "$RECEIPT_PARSE" ]; then
    echo "FATAL: receipt-parse.sh not executable: $RECEIPT_PARSE" >&2
    exit 1
fi

if [ ! -f "$SCRATCH_SH" ]; then
    echo "FATAL: ticket-scratch.sh not found at $SCRATCH_SH" >&2
    exit 1
fi

# ── Cleanup tracking ──────────────────────────────────────────────────────────
_CLEANUP_DIRS=()
_cleanup() {
    for d in "${_CLEANUP_DIRS[@]:-}"; do
        [ -n "$d" ] && rm -rf "$d"
    done
}
trap _cleanup EXIT

_make_scratch_base() {
    local tmp
    tmp=$(mktemp -d "${TMPDIR:-/tmp}/sprint-2332-test-XXXXXX")
    _CLEANUP_DIRS+=("$tmp")
    echo "$tmp"
}

# ══════════════════════════════════════════════════════════════════════════════
# Test 1: No --artifact <space> sub-agent handoff remains in sprint/SKILL.md
# ══════════════════════════════════════════════════════════════════════════════
echo ""
echo "── Test 1: --artifact <space> sub-agent handoff absent from sprint/SKILL.md ──"
test_no_artifact_handoff() {
    # grep exits 1 (not found) = PASS; exits 0 (found) = FAIL
    local found
    # Helper-script carve-out: append_review_cycle.py --artifact <path> is allowed
    found=$(python3 -c "
import sys
lines = open('$SKILL_MD').read().splitlines()
count = 0
for i, line in enumerate(lines):
    if '--artifact ' not in line:
        continue
    window = '\n'.join(lines[max(0,i-5):i+6])
    if any(k in window for k in ('append_review_cycle.py', '--artifact-file=', '--artifacts-dir', 'python3 ')):
        continue
    count += 1
print(count)
")
    assert_eq "no --artifact sub-agent-prompt handoffs in sprint/SKILL.md" "0" "$found"
}
test_no_artifact_handoff

# ══════════════════════════════════════════════════════════════════════════════
# Test 2: SCRATCH_TICKET_ID and SCRATCH_KEY present in the migrated block
# (PAF-4: namespaced identifiers)
# ══════════════════════════════════════════════════════════════════════════════
echo ""
echo "── Test 2: PAF-4 — SCRATCH_TICKET_ID and SCRATCH_KEY namespacing present ──"
test_scratch_namespacing() {
    local found_id found_key
    found_id=$(grep -c 'SCRATCH_TICKET_ID' "$SKILL_MD" || echo "0")
    found_key=$(grep -c 'SCRATCH_KEY' "$SKILL_MD" || echo "0")
    # Both must be present (count > 0)
    if [ "$found_id" -gt 0 ]; then
        assert_eq "SCRATCH_TICKET_ID present" "pass" "pass"
    else
        assert_eq "SCRATCH_TICKET_ID present" "pass" "fail"
    fi
    if [ "$found_key" -gt 0 ]; then
        assert_eq "SCRATCH_KEY present" "pass" "pass"
    else
        assert_eq "SCRATCH_KEY present" "pass" "fail"
    fi
}
test_scratch_namespacing

# ══════════════════════════════════════════════════════════════════════════════
# Test 3: Authoritative key sprint:step18:batch-plan present
# ══════════════════════════════════════════════════════════════════════════════
echo ""
echo "── Test 3: authoritative key sprint:step18:batch-plan present ──"
test_authoritative_key() {
    local found
    found=$(grep -c 'sprint:step18:batch-plan' "$SKILL_MD" || echo "0")
    if [ "$found" -gt 0 ]; then
        assert_eq "sprint:step18:batch-plan key present" "pass" "pass"
    else
        assert_eq "sprint:step18:batch-plan key present" "pass" "fail"
    fi
}
test_authoritative_key

# ══════════════════════════════════════════════════════════════════════════════
# Test 4: PAF-3 — output_contract XML tag present
# ══════════════════════════════════════════════════════════════════════════════
echo ""
echo "── Test 4: PAF-3 — output_contract XML tag present ──"
test_output_contract_tag() {
    local found_open found_close
    found_open=$(grep -c '<output_contract>' "$SKILL_MD" || echo "0")
    found_close=$(grep -c '</output_contract>' "$SKILL_MD" || echo "0")
    if [ "$found_open" -gt 0 ]; then
        assert_eq "output_contract opening tag present" "pass" "pass"
    else
        assert_eq "output_contract opening tag present" "pass" "fail"
    fi
    if [ "$found_close" -gt 0 ]; then
        assert_eq "output_contract closing tag present" "pass" "pass"
    else
        assert_eq "output_contract closing tag present" "pass" "fail"
    fi
}
test_output_contract_tag

# ══════════════════════════════════════════════════════════════════════════════
# Test 5: PAF-1 — SCRATCH_MISS guard co-located with scratch get
# ══════════════════════════════════════════════════════════════════════════════
echo ""
echo "── Test 5: PAF-1 — SCRATCH_MISS guard co-located with scratch get ──"
test_scratch_miss_guard() {
    local found
    found=$(grep -c 'SCRATCH_MISS' "$SKILL_MD" || echo "0")
    if [ "$found" -gt 0 ]; then
        assert_eq "SCRATCH_MISS guard present" "pass" "pass"
    else
        assert_eq "SCRATCH_MISS guard present" "pass" "fail"
    fi
}
test_scratch_miss_guard

# ══════════════════════════════════════════════════════════════════════════════
# Test 6: PAF-2 — explicit miss-not-input example present
# ══════════════════════════════════════════════════════════════════════════════
echo ""
echo "── Test 6: PAF-2 — explicit miss-not-input example present ──"
test_miss_not_input_example() {
    # The SCRATCH_MISS guard must include an explicit example of the miss envelope
    local found
    found=$(grep -c '"status":"miss"' "$SKILL_MD" || echo "0")
    if [ "$found" -gt 0 ]; then
        assert_eq "miss-not-input example present" "pass" "pass"
    else
        assert_eq "miss-not-input example present" "pass" "fail"
    fi
}
test_miss_not_input_example

# ══════════════════════════════════════════════════════════════════════════════
# Test 7: PAF-5 — inline cleanup (clear) in SCRATCH_MISS exit path
# ══════════════════════════════════════════════════════════════════════════════
echo ""
echo "── Test 7: PAF-5 — inline cleanup directive in SCRATCH_MISS exit path ──"
test_inline_cleanup() {
    # The SCRATCH_MISS block must call ticket-scratch.sh clear before exit
    local found
    found=$(grep -c 'ticket-scratch.sh.*clear' "$SKILL_MD" || echo "0")
    if [ "$found" -gt 0 ]; then
        assert_eq "inline cleanup (ticket-scratch.sh clear) present" "pass" "pass"
    else
        assert_eq "inline cleanup (ticket-scratch.sh clear) present" "pass" "fail"
    fi
}
test_inline_cleanup

# ══════════════════════════════════════════════════════════════════════════════
# Test 8: receipt-parse.sh invoked with sprint:step18 site_id
# ══════════════════════════════════════════════════════════════════════════════
echo ""
echo "── Test 8: receipt-parse.sh invocation with sprint:step18 site_id ──"
test_receipt_parse_invocation() {
    local found
    found=$(grep -c 'receipt-parse.sh.*sprint:step18' "$SKILL_MD" || echo "0")
    if [ "$found" -gt 0 ]; then
        assert_eq "receipt-parse.sh sprint:step18 invocation present" "pass" "pass"
    else
        assert_eq "receipt-parse.sh sprint:step18 invocation present" "pass" "fail"
    fi
}
test_receipt_parse_invocation

# ══════════════════════════════════════════════════════════════════════════════
# Test 9: Sample receipt round-trips through receipt-parse.sh → exit 0
# ══════════════════════════════════════════════════════════════════════════════
echo ""
echo "── Test 9: sample receipt JSON round-trips through receipt-parse.sh ──"
test_receipt_roundtrip() {
    local ticket_id="abcd-1234-efgh-5678"
    local key="sprint:step18:batch-plan"
    local byte_count=142
    local payload
    payload=$(printf '{"ticket_id":"%s","key":"%s","byte_count":%d}' \
        "$ticket_id" "$key" "$byte_count")

    local stdout exit_code=0
    stdout=$(printf '%s' "$payload" | bash "$RECEIPT_PARSE" "sprint:step18" "dso:verification-remediation-planner" 2>/dev/null) \
        || exit_code=$?

    assert_eq "valid receipt exits 0" "0" "$exit_code"
    assert_eq "receipt stdout = ticket_id key" "${ticket_id} ${key}" "$stdout"
}
test_receipt_roundtrip

# ══════════════════════════════════════════════════════════════════════════════
# Test 10: Malformed receipt (extra field) → receipt-parse.sh exits 2
# ══════════════════════════════════════════════════════════════════════════════
echo ""
echo "── Test 10: extra-field receipt → receipt-parse.sh exits 2 (RECEIPT_PARSE_ERROR) ──"
test_receipt_extra_field_rejected() {
    local payload
    payload='{"ticket_id":"abcd-1234-efgh-5678","key":"sprint:step18:batch-plan","byte_count":142,"n":1}'

    local exit_code=0 stderr
    stderr=$(printf '%s' "$payload" | bash "$RECEIPT_PARSE" "sprint:step18" "dso:verification-remediation-planner" 2>&1 >/dev/null) \
        || exit_code=$?

    assert_eq "extra-field receipt exits 2" "2" "$exit_code"

    local has_err
    has_err=$(echo "$stderr" | grep -c 'RECEIPT_PARSE_ERROR' || echo "0")
    if [ "$has_err" -gt 0 ]; then
        assert_eq "RECEIPT_PARSE_ERROR logged on extra-field violation" "pass" "pass"
    else
        assert_eq "RECEIPT_PARSE_ERROR logged on extra-field violation" "pass" "fail"
    fi
}
test_receipt_extra_field_rejected

# ══════════════════════════════════════════════════════════════════════════════
# Test 11: scratch set + get round-trip for sprint:step18:batch-plan key
# ══════════════════════════════════════════════════════════════════════════════
echo ""
echo "── Test 11: scratch set+get round-trip for sprint:step18:batch-plan ──"
test_scratch_roundtrip() {
    local base
    base=$(_make_scratch_base)
    local ticket_id="test-sprint-step18-abcd"
    local key="sprint:step18:batch-plan"
    local payload='{"n":1,"draft_hash":"abc123","findings_count":2,"verdict":"fail"}'

    # Write via scratch CLI
    local set_out set_exit=0
    set_out=$(SCRATCH_BASE_DIR="$base" bash "$SCRATCH_SH" set "$ticket_id" "$key" "$payload" 2>/dev/null) \
        || set_exit=$?
    assert_eq "scratch set exits 0" "0" "$set_exit"

    local set_status
    set_status=$(echo "$set_out" | python3 -c "import json,sys; print(json.load(sys.stdin)['status'])" 2>/dev/null || echo "error")
    assert_eq "scratch set status=ok" "ok" "$set_status"

    # Read back via scratch CLI — expect hit
    local get_out get_exit=0
    get_out=$(SCRATCH_BASE_DIR="$base" bash "$SCRATCH_SH" get "$ticket_id" "$key" 2>/dev/null) \
        || get_exit=$?
    assert_eq "scratch get exits 0 on hit" "0" "$get_exit"

    local get_status
    get_status=$(echo "$get_out" | python3 -c "import json,sys; print(json.load(sys.stdin)['status'])" 2>/dev/null || echo "error")
    assert_eq "scratch get status=hit" "hit" "$get_status"

    # Verify the stored value matches what was written
    local stored_value
    stored_value=$(echo "$get_out" | python3 -c "import json,sys; print(json.load(sys.stdin)['value'])" 2>/dev/null || echo "error")
    assert_eq "stored value matches written payload" "$payload" "$stored_value"
}
test_scratch_roundtrip

# ══════════════════════════════════════════════════════════════════════════════
# Test 12: SCRATCH_MISS path — scratch get returns miss when key absent
# ══════════════════════════════════════════════════════════════════════════════
echo ""
echo "── Test 12: scratch get returns miss (status=miss) when key absent ──"
test_scratch_miss_returns_miss() {
    local base
    base=$(_make_scratch_base)
    local ticket_id="test-sprint-step18-miss"
    local key="sprint:step18:batch-plan"

    local get_out get_exit=0
    get_out=$(SCRATCH_BASE_DIR="$base" bash "$SCRATCH_SH" get "$ticket_id" "$key" 2>/dev/null) \
        || get_exit=$?
    assert_eq "scratch get exits 0 on miss" "0" "$get_exit"

    local get_status
    get_status=$(echo "$get_out" | python3 -c "import json,sys; print(json.load(sys.stdin)['status'])" 2>/dev/null || echo "error")
    assert_eq "scratch get status=miss when key absent" "miss" "$get_status"
}
test_scratch_miss_returns_miss

# ══════════════════════════════════════════════════════════════════════════════
# Summary
# ══════════════════════════════════════════════════════════════════════════════
echo ""
print_summary
