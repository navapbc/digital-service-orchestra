#!/usr/bin/env bash
# tests/scripts/test-preconditions-validator.sh
# RED tests for plugins/dso/scripts/preconditions-validator.sh (does NOT exist yet).
#
# Covers:
#   1. Validator accepts a well-formed PRECONDITIONS event file (exit 0)
#   2. Validator rejects a fixture missing required field 'gate_name' (exit 1 + stderr diagnostic)
#   3. Validator tolerates unknown/extra fields (exit 0 — depth-agnostic forward-compat)
#
# Usage: bash tests/scripts/test-preconditions-validator.sh

# NOTE: -e is intentionally omitted — test functions return non-zero by design
# (they assert against unimplemented features). -e would abort the runner.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"
VALIDATOR_SCRIPT="$REPO_ROOT/plugins/dso/scripts/preconditions-validator.sh"

source "$REPO_ROOT/tests/lib/assert.sh"

echo "=== test-preconditions-validator.sh ==="

# ── Cleanup tracker ───────────────────────────────────────────────────────────
declare -a _CLEANUP_DIRS=()
_cleanup() {
    local d
    for d in "${_CLEANUP_DIRS[@]:-}"; do
        [ -n "$d" ] && rm -rf "$d"
    done
}
trap _cleanup EXIT

# ── Helper: create a minimal valid PRECONDITIONS fixture JSON ─────────────────
_make_valid_fixture() {
    local path="$1"
    python3 -c "
import json, sys
payload = {
    'event_type': 'PRECONDITIONS',
    'gate_name': 'brainstorm_complete',
    'session_id': 'sess-test-001',
    'worktree_id': 'worktree-test',
    'tier': 'minimal',
    'timestamp': 1714000000000,
    'data': {},
}
with open(sys.argv[1], 'w', encoding='utf-8') as f:
    json.dump(payload, f)
" "$path"
}

# ── Test 1: validator accepts a well-formed event file (exit 0) ───────────────
echo "Test 1: preconditions-validator.sh exits 0 for a well-formed PRECONDITIONS event"
test_validator_accepts_well_formed() {
    if [ ! -f "$VALIDATOR_SCRIPT" ]; then
        assert_eq "preconditions-validator.sh exists" "exists" "missing"
        return
    fi

    local tmp
    tmp=$(mktemp -d)
    _CLEANUP_DIRS+=("$tmp")

    local fixture="$tmp/valid-event.json"
    _make_valid_fixture "$fixture"

    local exit_code=0
    bash "$VALIDATOR_SCRIPT" "ticket-abc1" "brainstorm_complete" "--event-file=$fixture" \
        >/dev/null 2>&1 || exit_code=$?

    assert_eq "validator exits 0 for well-formed event" "0" "$exit_code"
}
test_validator_accepts_well_formed

# ── Test 2: validator rejects fixture missing 'gate_name' (exit 1 + stderr) ──
echo "Test 2: preconditions-validator.sh exits 1 and emits diagnostic when gate_name is missing"
test_validator_rejects_invalid() {
    if [ ! -f "$VALIDATOR_SCRIPT" ]; then
        assert_eq "preconditions-validator.sh exists for rejection test" "exists" "missing"
        return
    fi

    local tmp
    tmp=$(mktemp -d)
    _CLEANUP_DIRS+=("$tmp")

    local fixture="$tmp/invalid-event.json"
    # Write a fixture without the required 'gate_name' field
    python3 -c "
import json, sys
payload = {
    'event_type': 'PRECONDITIONS',
    'session_id': 'sess-test-002',
    'worktree_id': 'worktree-test',
    'tier': 'minimal',
    'timestamp': 1714000000001,
    'data': {},
    # NOTE: gate_name intentionally absent
}
with open(sys.argv[1], 'w', encoding='utf-8') as f:
    json.dump(payload, f)
" "$fixture"

    local exit_code=0
    local stderr_output
    stderr_output=$(bash "$VALIDATOR_SCRIPT" "ticket-abc2" "brainstorm_complete" \
        "--event-file=$fixture" 2>&1 >/dev/null) || exit_code=$?

    assert_eq "validator exits 1 for missing gate_name" "1" "$exit_code"
    # Stderr must contain a diagnostic mentioning the missing field or validation failure
    local has_diagnostic
    has_diagnostic=$(echo "$stderr_output" | grep -ic "gate_name\|missing\|invalid\|required\|validation" || true)
    assert_eq "stderr contains diagnostic for missing gate_name" "1" \
        "$([ "${has_diagnostic:-0}" -gt 0 ] && echo 1 || echo 0)"
}
test_validator_rejects_invalid

# ── Test 3: validator tolerates unknown/extra fields (depth-agnostic forward-compat) ──
echo "Test 3: preconditions-validator.sh exits 0 when fixture has extra/unknown fields"
test_validator_tolerates_unknown_fields() {
    if [ ! -f "$VALIDATOR_SCRIPT" ]; then
        assert_eq "preconditions-validator.sh exists for extra-fields test" "exists" "missing"
        return
    fi

    local tmp
    tmp=$(mktemp -d)
    _CLEANUP_DIRS+=("$tmp")

    local fixture="$tmp/extra-fields-event.json"
    # Write a fixture with all required fields PLUS unknown extras
    python3 -c "
import json, sys
payload = {
    'event_type': 'PRECONDITIONS',
    'gate_name': 'brainstorm_complete',
    'session_id': 'sess-test-003',
    'worktree_id': 'worktree-test',
    'tier': 'minimal',
    'timestamp': 1714000000002,
    'data': {},
    # Extra fields that a future version might add:
    'decisions_log': [{'decision': 'foo', 'rationale': 'bar'}],
    'foo_bar': 'unknown_future_field',
    'upstream_event_id': 'evt-xyz-999',
}
with open(sys.argv[1], 'w', encoding='utf-8') as f:
    json.dump(payload, f)
" "$fixture"

    local exit_code=0
    bash "$VALIDATOR_SCRIPT" "ticket-abc3" "brainstorm_complete" "--event-file=$fixture" \
        >/dev/null 2>&1 || exit_code=$?

    assert_eq "validator exits 0 when extra fields are present (forward-compat)" "0" "$exit_code"
}
test_validator_tolerates_unknown_fields

print_summary
