#!/usr/bin/env bash
# tests/skills/test-preplanning-preconditions-integration.sh
# Integration tests: brainstorm → preplanning preconditions chain validation.
#
# These tests exercise the full round-trip contract:
#   1. A brainstorm event fixture validates as a valid preplanning entry-gate event
#   2. A preplanning exit-emit fixture (with upstream_event_id) validates successfully
#   3. When no --event-file is provided and no live event exists: validator exits 2
#
# Uses preconditions-validator.sh directly against tmp fixture files.
# All tests are GREEN (no RED marker needed).
#
# Usage: bash tests/skills/test-preplanning-preconditions-integration.sh

# NOTE: -e is intentionally omitted — test functions may call bash and check exit codes.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"
VALIDATOR_SCRIPT="$REPO_ROOT/plugins/dso/scripts/preconditions-validator.sh"

source "$REPO_ROOT/tests/lib/assert.sh"

echo "=== test-preplanning-preconditions-integration.sh ==="

# ── Cleanup tracker ───────────────────────────────────────────────────────────
declare -a _CLEANUP_DIRS=()
_cleanup() {
    local d
    for d in "${_CLEANUP_DIRS[@]:-}"; do
        [ -n "$d" ] && rm -rf "$d"
    done
}
trap _cleanup EXIT

# ── Test 1: brainstorm-to-preplanning preconditions chain ─────────────────────
# Simulate a brainstorm PRECONDITIONS event (as brainstorm would write it).
# The validator reads only minimal-tier required fields — extra fields like
# event_id are accepted (depth-agnostic forward-compat).
echo "Test 1: brainstorm_complete event passes preplanning entry-gate validation"
test_brainstorm_to_preplanning_preconditions_chain() {
    if [ ! -f "$VALIDATOR_SCRIPT" ]; then
        assert_eq "preconditions-validator.sh exists" "exists" "missing"
        return
    fi

    local tmp
    tmp=$(mktemp -d)
    _CLEANUP_DIRS+=("$tmp")

    local fixture="$tmp/brainstorm-event.json"
    python3 -c "
import json, sys
payload = {
    'event_type': 'PRECONDITIONS',
    'gate_name': 'brainstorm_complete',
    'session_id': 'sess-brainstorm-abc',
    'worktree_id': 'worktree-branch-1',
    'tier': 'minimal',
    'timestamp': 1714000000100,
    'data': {'epic_id': 'epic-test-001'},
    # extra field: future stories might add this
    'event_id': 'evt-uuid-1234',
}
with open(sys.argv[1], 'w', encoding='utf-8') as f:
    json.dump(payload, f)
" "$fixture"

    local exit_code=0
    bash "$VALIDATOR_SCRIPT" "epic-test-001" "brainstorm_complete" \
        "--event-file=$fixture" >/dev/null 2>&1 || exit_code=$?

    assert_eq "brainstorm event validates as preplanning entry-gate input (exit 0)" "0" "$exit_code"
}
test_brainstorm_to_preplanning_preconditions_chain

# ── Test 2: preplanning exit-emit event validates (round-trip) ────────────────
# Simulate the preplanning PRECONDITIONS event that preplanning emits on exit.
# Includes upstream_event_id linking back to the brainstorm event.
echo "Test 2: preplanning_complete event with upstream_event_id validates successfully"
test_preplanning_exit_emit_and_roundtrip() {
    if [ ! -f "$VALIDATOR_SCRIPT" ]; then
        assert_eq "preconditions-validator.sh exists for roundtrip test" "exists" "missing"
        return
    fi

    local tmp
    tmp=$(mktemp -d)
    _CLEANUP_DIRS+=("$tmp")

    local fixture="$tmp/preplanning-event.json"
    python3 -c "
import json, sys
payload = {
    'event_type': 'PRECONDITIONS',
    'gate_name': 'preplanning_complete',
    'session_id': 'sess-preplanning-xyz',
    'worktree_id': 'worktree-branch-1',
    'tier': 'minimal',
    'timestamp': 1714000001000,
    'data': {'stories_created': 3},
    # upstream link to brainstorm event (extra field: forward-compat)
    'upstream_event_id': 'evt-uuid-1234',
}
with open(sys.argv[1], 'w', encoding='utf-8') as f:
    json.dump(payload, f)
" "$fixture"

    local exit_code=0
    bash "$VALIDATOR_SCRIPT" "epic-test-001" "preplanning_complete" \
        "--event-file=$fixture" >/dev/null 2>&1 || exit_code=$?

    assert_eq "preplanning exit-emit event validates (exit 0)" "0" "$exit_code"
}
test_preplanning_exit_emit_and_roundtrip

# ── Test 3: validator exits 2 when no --event-file and no live event ──────────
# This confirms the "not found" path: without --event-file, the validator cannot
# locate an event and must exit 2.
echo "Test 3: validator exits 2 when no --event-file is provided (event not found)"
test_preplanning_blocked_when_no_brainstorm_event() {
    if [ ! -f "$VALIDATOR_SCRIPT" ]; then
        assert_eq "preconditions-validator.sh exists for not-found test" "exists" "missing"
        return
    fi

    local exit_code=0
    # Run with a nonexistent ticket and stage, NO --event-file flag
    bash "$VALIDATOR_SCRIPT" "ticket-nonexistent-9999" "brainstorm_complete" \
        >/dev/null 2>&1 || exit_code=$?

    assert_eq "validator exits 2 when no event file provided (not found)" "2" "$exit_code"
}
test_preplanning_blocked_when_no_brainstorm_event

print_summary
