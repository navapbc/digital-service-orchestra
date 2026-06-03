#!/usr/bin/env bash
# tests/skills/test-debug-everything-two-phase-routing.sh
#
# Behavioral tests for the /dso:debug-everything two-phase parallel pipeline.
#
# This file tests three high-value behaviors that are NOT covered by the
# structural grep tests in test-debug-everything-two-phase-pipeline.sh:
#
#   1. ROUTING CLASSIFICATION — a classify_investigation_summary() shell
#      function that faithfully mirrors the token-precedence documented in
#      plugins/dso/skills/debug-everything/prompts/dispatch-fix-batch.md:
#
#        COMPLEX_ESCALATION > MANUAL_APPROVAL_NEEDED
#          > FIXABLE:true (include in Phase 2)
#          / FIXABLE:false (exclude from Phase 2)
#        missing INVESTIGATION_COMPLETE line → INVESTIGATION_FAILED
#
#      All branches are tested, including the edge case:
#      a summary without INVESTIGATION_COMPLETE must route to
#      INVESTIGATION_FAILED rather than falling through to a Phase-2 include.
#
#   2. SCRATCH CLI ROUNDTRIP — write a schema-v1 fix-bug:investigation payload
#      via ticket-scratch-set.sh (using SCRATCH_BASE_DIR override) and read it
#      back via ticket-scratch-get.sh, asserting field-for-field round-trip
#      fidelity.
#
#   3. OVERSIZE FALLBACK — confirm the scratch store rejects a payload
#      exceeding the 98304-byte ceiling with the documented error shape
#      ({status:error, code:oversize, limit:N, actual:M}), and exercise the
#      scratch_overflow=true pointer path.
#
# Rule 5 (behavioral-testing-standard.md): tests assert on observable behavior
# (outputs, exit codes, JSON fields) — NOT on source text of skill files.
# No change-detector grep against SKILL.md or prompt templates appears here.
#
# Usage:
#   bash tests/skills/test-debug-everything-two-phase-routing.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SCRATCH_SET="$REPO_ROOT/plugins/dso/scripts/ticket-scratch-set.sh"
SCRATCH_GET="$REPO_ROOT/plugins/dso/scripts/ticket-scratch-get.sh"
TICKET_LIB="$REPO_ROOT/plugins/dso/scripts/ticket-lib.sh"

source "$REPO_ROOT/tests/lib/assert.sh"

echo "=== test-debug-everything-two-phase-routing.sh ==="
echo ""

# ── Cleanup tracking ──────────────────────────────────────────────────────────
_CLEANUP_DIRS=()
_cleanup() {
    for d in "${_CLEANUP_DIRS[@]:-}"; do
        [ -n "$d" ] && rm -rf "$d"
    done
}
trap _cleanup EXIT

# ── Prerequisite checks ───────────────────────────────────────────────────────
_check_prereqs() {
    local missing=0
    for f in "$SCRATCH_SET" "$SCRATCH_GET" "$TICKET_LIB"; do
        if [ ! -f "$f" ]; then
            echo "FATAL: required file not found: $f" >&2
            missing=1
        elif [[ "$f" == *.sh ]] && [ ! -x "$f" ]; then
            echo "FATAL: required script not executable: $f" >&2
            missing=1
        fi
    done
    [ "$missing" -ne 0 ] && exit 1
}
_check_prereqs

# ── Helper: create an isolated scratch base dir ───────────────────────────────
_make_scratch_base() {
    local tmp
    tmp=$(mktemp -d "${TMPDIR:-/tmp}/dso-routing-test-XXXXXX")
    _CLEANUP_DIRS+=("$tmp")
    echo "$tmp"
}

# ─────────────────────────────────────────────────────────────────────────────
# SECTION 1: ROUTING CLASSIFICATION
#
# Validates the routing CONTRACT documented in dispatch-fix-batch.md.
#
# The function classify_investigation_summary() below mirrors the token-
# precedence rules documented there:
#
#   COMPLEX_ESCALATION: true  → COMPLEX_ESCALATION
#   MANUAL_APPROVAL_NEEDED: true → MANUAL_APPROVAL_QUEUED
#   FIXABLE: true             → PHASE2_INCLUDE
#   FIXABLE: false            → INVESTIGATION_FIXABLE_FALSE
#   no INVESTIGATION_COMPLETE → INVESTIGATION_FAILED
#
# Token precedence (most-restrictive wins when multiple tokens are present):
#   COMPLEX_ESCALATION > MANUAL_APPROVAL_NEEDED > FIXABLE
# ─────────────────────────────────────────────────────────────────────────────

# classify_investigation_summary <compact_summary_string>
#
# Parses the compact summary emitted by a fix-bug investigation sub-agent and
# returns the orchestrator routing decision.
#
# Outputs (to stdout) one of:
#   INVESTIGATION_FAILED
#   COMPLEX_ESCALATION
#   MANUAL_APPROVAL_QUEUED
#   PHASE2_INCLUDE
#   INVESTIGATION_FIXABLE_FALSE
classify_investigation_summary() {
    local summary="$1"

    # Guard: no INVESTIGATION_COMPLETE line → investigation failed
    if ! echo "$summary" | grep -q "^INVESTIGATION_COMPLETE:"; then
        echo "INVESTIGATION_FAILED"
        return
    fi

    # Token-precedence per dispatch-fix-batch.md §5:
    #   COMPLEX_ESCALATION: true  (most restrictive)
    if echo "$summary" | grep -q "^COMPLEX_ESCALATION: true"; then
        echo "COMPLEX_ESCALATION"
        return
    fi

    #   MANUAL_APPROVAL_NEEDED: true
    if echo "$summary" | grep -q "^MANUAL_APPROVAL_NEEDED: true"; then
        echo "MANUAL_APPROVAL_QUEUED"
        return
    fi

    #   FIXABLE: true  → include in Phase 2
    if echo "$summary" | grep -q "^FIXABLE: true"; then
        echo "PHASE2_INCLUDE"
        return
    fi

    #   FIXABLE: false → exclude
    if echo "$summary" | grep -q "^FIXABLE: false"; then
        echo "INVESTIGATION_FIXABLE_FALSE"
        return
    fi

    # No recognizable FIXABLE token → treat as failed
    echo "INVESTIGATION_FAILED"
}

# ── Test: missing INVESTIGATION_COMPLETE → INVESTIGATION_FAILED ───────────────
# This is the critical edge case from the bug report: a summary that contains
# FIXABLE: true but lacks INVESTIGATION_COMPLETE must NOT be included in Phase
# 2 — it must route to INVESTIGATION_FAILED.
test_missing_investigation_complete_routes_to_failed() {
    local summary
    summary=$(printf 'COMPLEXITY: MODERATE\nFIXABLE: true\nMANUAL_APPROVAL_NEEDED: false\nCOMPLEX_ESCALATION: false\nSCRATCH_KEY: fix-bug:investigation\n')
    local result
    result=$(classify_investigation_summary "$summary")
    assert_eq \
        "missing INVESTIGATION_COMPLETE must route to INVESTIGATION_FAILED (not PHASE2_INCLUDE)" \
        "INVESTIGATION_FAILED" "$result"
}

echo "--- test_missing_investigation_complete_routes_to_failed ---"
test_missing_investigation_complete_routes_to_failed
echo ""

# ── Test: fully empty summary → INVESTIGATION_FAILED ─────────────────────────
test_empty_summary_routes_to_failed() {
    local result
    result=$(classify_investigation_summary "")
    assert_eq \
        "empty summary must route to INVESTIGATION_FAILED" \
        "INVESTIGATION_FAILED" "$result"
}

echo "--- test_empty_summary_routes_to_failed ---"
test_empty_summary_routes_to_failed
echo ""

# ── Test: normal FIXABLE:true → PHASE2_INCLUDE ────────────────────────────────
test_fixable_true_routes_to_phase2_include() {
    local summary
    summary=$(printf 'INVESTIGATION_COMPLETE: bug-1234\nCOMPLEXITY: TRIVIAL\nFIXABLE: true\nMANUAL_APPROVAL_NEEDED: false\nCOMPLEX_ESCALATION: false\nSCRATCH_KEY: fix-bug:investigation\n')
    local result
    result=$(classify_investigation_summary "$summary")
    assert_eq \
        "FIXABLE: true (with INVESTIGATION_COMPLETE) must route to PHASE2_INCLUDE" \
        "PHASE2_INCLUDE" "$result"
}

echo "--- test_fixable_true_routes_to_phase2_include ---"
test_fixable_true_routes_to_phase2_include
echo ""

# ── Test: FIXABLE:false → INVESTIGATION_FIXABLE_FALSE ────────────────────────
test_fixable_false_routes_to_fixable_false() {
    local summary
    summary=$(printf 'INVESTIGATION_COMPLETE: bug-5678\nCOMPLEXITY: MODERATE\nFIXABLE: false\nMANUAL_APPROVAL_NEEDED: false\nCOMPLEX_ESCALATION: false\nSCRATCH_KEY: fix-bug:investigation\n')
    local result
    result=$(classify_investigation_summary "$summary")
    assert_eq \
        "FIXABLE: false must route to INVESTIGATION_FIXABLE_FALSE" \
        "INVESTIGATION_FIXABLE_FALSE" "$result"
}

echo "--- test_fixable_false_routes_to_fixable_false ---"
test_fixable_false_routes_to_fixable_false
echo ""

# ── Test: MANUAL_APPROVAL_NEEDED:true overrides FIXABLE:true ─────────────────
test_manual_approval_overrides_fixable_true() {
    local summary
    summary=$(printf 'INVESTIGATION_COMPLETE: bug-9abc\nCOMPLEXITY: MODERATE\nFIXABLE: true\nMANUAL_APPROVAL_NEEDED: true\nCOMPLEX_ESCALATION: false\nSCRATCH_KEY: fix-bug:investigation\n')
    local result
    result=$(classify_investigation_summary "$summary")
    assert_eq \
        "MANUAL_APPROVAL_NEEDED: true must override FIXABLE: true and route to MANUAL_APPROVAL_QUEUED" \
        "MANUAL_APPROVAL_QUEUED" "$result"
}

echo "--- test_manual_approval_overrides_fixable_true ---"
test_manual_approval_overrides_fixable_true
echo ""

# ── Test: COMPLEX_ESCALATION:true overrides MANUAL_APPROVAL_NEEDED:true ──────
test_complex_escalation_overrides_manual_approval() {
    local summary
    summary=$(printf 'INVESTIGATION_COMPLETE: bug-def0\nCOMPLEXITY: COMPLEX\nFIXABLE: true\nMANUAL_APPROVAL_NEEDED: true\nCOMPLEX_ESCALATION: true\nSCRATCH_KEY: fix-bug:investigation\n')
    local result
    result=$(classify_investigation_summary "$summary")
    assert_eq \
        "COMPLEX_ESCALATION: true must override MANUAL_APPROVAL_NEEDED: true (most-restrictive wins)" \
        "COMPLEX_ESCALATION" "$result"
}

echo "--- test_complex_escalation_overrides_manual_approval ---"
test_complex_escalation_overrides_manual_approval
echo ""

# ─────────────────────────────────────────────────────────────────────────────
# SECTION 2: SCRATCH CLI ROUNDTRIP
#
# Verifies that a schema-v1 fix-bug:investigation payload survives a full
# write → read roundtrip through the ticket scratch CLI without data loss.
#
# Uses SCRATCH_BASE_DIR override (not the live .claude/scratch/ directory) so
# the test is fully isolated and leaves no residue in the repo.
# ─────────────────────────────────────────────────────────────────────────────

test_scratch_cli_roundtrip_investigation_v1() {
    local base ticket_id key
    base=$(_make_scratch_base)
    ticket_id="test-c121-roundtrip-1234"
    key="fix-bug:investigation"

    # Construct a valid schema-v1 payload — all required fields present
    local payload
    payload=$(python3 -c "
import json
payload = {
    'schema': 'fix-bug:investigation/v1',
    'bug_id': 'test-c121-roundtrip-1234',
    'summary': 'Root cause: missing INVESTIGATION_COMPLETE guard in routing logic',
    'proposed_fix': 'Add a INVESTIGATION_COMPLETE presence check before routing',
    'affected_files': [
        'plugins/dso/skills/debug-everything/prompts/dispatch-fix-batch.md'
    ],
    'complexity': 'MODERATE',
    'fixable': True,
    'manual_approval_needed': False,
    'complex_escalation': False,
    'discovery_file': '/tmp/fix-bug-discovery-test-c121-roundtrip-1234.json'
}
print(json.dumps(payload))
")

    # Write via scratch-set.sh (mocked external surface via SCRATCH_BASE_DIR)
    local set_out set_exit
    set_out=$(SCRATCH_BASE_DIR="$base" bash "$SCRATCH_SET" "$ticket_id" "$key" "$payload" 2>/dev/null)
    set_exit=$?

    assert_eq \
        "scratch set must exit 0 for valid payload" \
        "0" "$set_exit"

    local set_status
    set_status=$(echo "$set_out" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('status',''))" 2>/dev/null)
    assert_eq \
        "scratch set must return status:ok" \
        "ok" "$set_status"

    # Read back via scratch-get.sh
    local get_out get_exit
    get_out=$(SCRATCH_BASE_DIR="$base" bash "$SCRATCH_GET" "$ticket_id" "$key" 2>/dev/null)
    get_exit=$?

    assert_eq \
        "scratch get must exit 0 on hit" \
        "0" "$get_exit"

    local get_status
    get_status=$(echo "$get_out" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('status',''))" 2>/dev/null)
    assert_eq \
        "scratch get must return status:hit" \
        "hit" "$get_status"

    # Roundtrip fidelity: extract stored value and compare all required fields
    python3 - "$get_out" "$payload" <<'PYEOF'
import json, sys

hit_json   = sys.argv[1]
orig_json  = sys.argv[2]

hit   = json.loads(hit_json)
orig  = json.loads(orig_json)

# The stored envelope wraps the value as a string; parse it
stored_value = hit.get("value", "")
if isinstance(stored_value, str):
    stored = json.loads(stored_value)
else:
    stored = stored_value

required_fields = [
    "schema", "bug_id", "summary", "proposed_fix",
    "affected_files", "complexity", "fixable",
    "manual_approval_needed", "complex_escalation", "discovery_file"
]

failed = []
for field in required_fields:
    if stored.get(field) != orig.get(field):
        failed.append(f"{field}: got {stored.get(field)!r}, want {orig.get(field)!r}")

if failed:
    for msg in failed:
        print(f"ROUNDTRIP MISMATCH: {msg}")
    sys.exit(1)

sys.exit(0)
PYEOF
    local fidelity_exit=$?

    assert_eq \
        "scratch CLI roundtrip must preserve all schema-v1 required fields" \
        "0" "$fidelity_exit"
}

echo "--- test_scratch_cli_roundtrip_investigation_v1 ---"
test_scratch_cli_roundtrip_investigation_v1
echo ""

# ─────────────────────────────────────────────────────────────────────────────
# SECTION 3: OVERSIZE FALLBACK
#
# Verifies:
#   a) The scratch store rejects a payload exceeding 98304 bytes with the
#      documented error shape: {status:error, code:oversize, limit:N, actual:M}
#      The actual ceiling is 98304 bytes (see ticket-lib.sh and bug 3e82).
#   b) The scratch_overflow=true pointer path is readable as the Phase-2
#      Path A fallback: write a minimal pointer payload with discovery_file
#      and verify it round-trips correctly via scratch-set → scratch-get.
# ─────────────────────────────────────────────────────────────────────────────

test_scratch_rejects_oversize_payload() {
    local base ticket_id key
    base=$(_make_scratch_base)
    ticket_id="test-c121-oversize-abcd"
    key="fix-bug:investigation"

    # Build a payload that is guaranteed to exceed 98304 bytes.
    # Use a 100KB string of repeated data (well over the ceiling).
    local oversize_payload
    oversize_payload=$(python3 -c "
import json
# 100 KB of padding (comfortably above 98304-byte ceiling)
big = 'x' * 102400
payload = {
    'schema': 'fix-bug:investigation/v1',
    'bug_id': 'test-c121-oversize-abcd',
    'summary': 'padded to trigger oversize',
    'padding': big
}
print(json.dumps(payload))
")

    local set_out set_exit
    set_out=$(SCRATCH_BASE_DIR="$base" bash "$SCRATCH_SET" "$ticket_id" "$key" "$oversize_payload" 2>/dev/null)
    set_exit=$?

    # Non-zero exit expected on oversize
    assert_eq \
        "scratch set must exit non-zero for oversize payload" \
        "1" "$([ "$set_exit" -ne 0 ] && echo 1 || echo 0)"

    # status:"error" in output
    local err_status
    err_status=$(echo "$set_out" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('status',''))" 2>/dev/null)
    assert_eq \
        "scratch set oversize must emit status:error" \
        "error" "$err_status"

    # code:"oversize"
    local err_code
    err_code=$(echo "$set_out" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('code',''))" 2>/dev/null)
    assert_eq \
        "scratch set oversize must emit code:oversize" \
        "oversize" "$err_code"

    # limit field must be present and equal to 98304 (the actual ceiling)
    local err_limit
    err_limit=$(echo "$set_out" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('limit',''))" 2>/dev/null)
    assert_eq \
        "scratch set oversize must report limit of 98304 bytes" \
        "98304" "$err_limit"

    # actual field must be present and be a positive integer > 98304
    local err_actual_valid
    err_actual_valid=$(echo "$set_out" | python3 -c "
import json, sys
d = json.load(sys.stdin)
actual = d.get('actual', 0)
print('1' if isinstance(actual, int) and actual > 98304 else '0')
" 2>/dev/null)
    assert_eq \
        "scratch set oversize must report actual byte count > 98304" \
        "1" "$err_actual_valid"
}

echo "--- test_scratch_rejects_oversize_payload ---"
test_scratch_rejects_oversize_payload
echo ""

# ── Test: scratch_overflow=true pointer path is readable as Path A fallback ───
#
# When the compact projection is itself too large, fix-bug Phase D Step 4 falls
# back to writing a minimal pointer envelope with scratch_overflow=true and the
# path to the full discovery file. The Phase-2 fix-application sub-agent reads
# this via Path A and follows the discovery_file path. This test confirms the
# pointer payload round-trips correctly.
test_scratch_overflow_pointer_path_is_readable() {
    local base ticket_id key
    base=$(_make_scratch_base)
    ticket_id="test-c121-pointer-dcba"
    key="fix-bug:investigation"

    # Write a discovery file (the side-car that holds the full RESULT envelope)
    local discovery_file
    discovery_file=$(mktemp "${TMPDIR:-/tmp}/fix-bug-discovery-test-c121.XXXXXX.json")
    _CLEANUP_DIRS+=("$discovery_file")
    python3 -c "
import json
full_result = {
    'root_cause_candidates': [{'cause': 'missing guard', 'confidence': 'high', 'evidence': 'observed in test'}],
    'alternative_fixes': [{'description': 'add guard before routing', 'risk': 'low'}],
    'hypothesis_tests': [{'hypothesis': 'missing guard causes wrong route', 'verdict': 'confirmed', 'observed': 'route=PHASE2_INCLUDE when should be INVESTIGATION_FAILED'}],
    'recommendation': 'add INVESTIGATION_COMPLETE presence check'
}
print(json.dumps(full_result))
" > "$discovery_file"

    # Construct the minimal pointer payload (scratch_overflow=true)
    local pointer_payload
    pointer_payload=$(python3 -c "
import json, sys
payload = {
    'schema': 'fix-bug:investigation/v1',
    'bug_id': 'test-c121-pointer-dcba',
    'scratch_overflow': True,
    'discovery_file': sys.argv[1],
    'complexity': 'MODERATE',
    'fixable': True,
    'manual_approval_needed': False,
    'complex_escalation': False
}
print(json.dumps(payload))
" "$discovery_file")

    # Write pointer to scratch
    local set_out set_exit
    set_out=$(SCRATCH_BASE_DIR="$base" bash "$SCRATCH_SET" "$ticket_id" "$key" "$pointer_payload" 2>/dev/null)
    set_exit=$?

    assert_eq \
        "scratch set must accept the pointer payload (under oversize ceiling)" \
        "0" "$set_exit"

    # Read it back
    local get_out
    get_out=$(SCRATCH_BASE_DIR="$base" bash "$SCRATCH_GET" "$ticket_id" "$key" 2>/dev/null)

    local get_status
    get_status=$(echo "$get_out" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('status',''))" 2>/dev/null)
    assert_eq \
        "pointer payload scratch get must return status:hit" \
        "hit" "$get_status"

    # Verify scratch_overflow=true and discovery_file survive the roundtrip
    python3 - "$get_out" "$discovery_file" <<'PYEOF'
import json, sys

hit_json       = sys.argv[1]
expected_df    = sys.argv[2]

hit    = json.loads(hit_json)
stored_value = hit.get("value", "")
if isinstance(stored_value, str):
    stored = json.loads(stored_value)
else:
    stored = stored_value

ok = True
if stored.get("scratch_overflow") is not True:
    print(f"FAIL: scratch_overflow should be True, got {stored.get('scratch_overflow')!r}")
    ok = False
if stored.get("discovery_file") != expected_df:
    print(f"FAIL: discovery_file mismatch: got {stored.get('discovery_file')!r}, want {expected_df!r}")
    ok = False

sys.exit(0 if ok else 1)
PYEOF
    local pointer_fidelity_exit=$?

    assert_eq \
        "scratch_overflow pointer payload must preserve scratch_overflow and discovery_file fields" \
        "0" "$pointer_fidelity_exit"

    # Verify the discovery file is readable and contains the full RESULT
    local df_readable
    df_readable=$(python3 -c "
import json, sys
with open(sys.argv[1]) as f:
    d = json.load(f)
print('1' if 'root_cause_candidates' in d and 'recommendation' in d else '0')
" "$discovery_file" 2>/dev/null)
    assert_eq \
        "discovery file must be readable and contain full RESULT envelope fields" \
        "1" "$df_readable"
}

echo "--- test_scratch_overflow_pointer_path_is_readable ---"
test_scratch_overflow_pointer_path_is_readable
echo ""

print_summary
