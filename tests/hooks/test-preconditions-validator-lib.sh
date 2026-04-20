#!/usr/bin/env bash
# tests/hooks/test-preconditions-validator-lib.sh
# RED-phase tests for plugins/dso/hooks/lib/preconditions-validator-lib.sh
#
# Tests FAIL before the library is created (RED), PASS after implementation (GREEN).
# Tests use temp dirs for isolation — no shared mutable state between runs.
# shellcheck disable=SC2030,SC2031,SC2329
# SC2030/SC2031: TICKETS_TRACKER_DIR export is intentionally local to subshells (test isolation)
# SC2329: _read_latest_preconditions stub defined inside subshell for mock override — invoked by sourced library

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
PLUGIN_ROOT="$REPO_ROOT/plugins/dso"
LIB_PATH="$PLUGIN_ROOT/hooks/lib/preconditions-validator-lib.sh"
VALIDATOR_SCRIPT="$PLUGIN_ROOT/scripts/preconditions-validator.sh"

source "$SCRIPT_DIR/../lib/assert.sh"

# ── Isolation helpers ─────────────────────────────────────────────────────────
_TEST_TMPDIRS=()
cleanup() {
    for d in "${_TEST_TMPDIRS[@]:-}"; do
        rm -rf "$d"
    done
}
trap cleanup EXIT

_make_tmp_dir() {
    local d
    d=$(mktemp -d)
    _TEST_TMPDIRS+=("$d")
    echo "$d"
}

# ── Fixture: write a minimal-tier PRECONDITIONS event to a file ───────────────
_write_minimal_preconditions_fixture() {
    local out_file="$1"
    local gate_name="${2:-brainstorm_complete}"
    local upstream_event_id="${3:-}"
    python3 - "$out_file" "$gate_name" "$upstream_event_id" <<'PYEOF'
import json, sys, uuid, time

out_file = sys.argv[1]
gate_name = sys.argv[2]
upstream_event_id = sys.argv[3] if len(sys.argv) > 3 else ""

payload = {
    "event_type": "PRECONDITIONS",
    "schema_version": 1,
    "manifest_depth": "minimal",
    "gate_name": gate_name,
    "session_id": "test-session-001",
    "worktree_id": "test-branch",
    "tier": "minimal",
    "timestamp": int(time.time() * 1000),
    "spec_hash": "abc123",
    "gate_verdicts": [],
    "workflow_completion_checklist": [],
    "completeness": "complete",
    "data": {}
}
if upstream_event_id:
    payload["upstream_event_id"] = upstream_event_id

with open(out_file, "w", encoding="utf-8") as f:
    json.dump(payload, f)
PYEOF
}

# ── Fixture: write a standard-tier PRECONDITIONS event (extra fields) ─────────
_write_standard_preconditions_fixture() {
    local out_file="$1"
    local gate_name="${2:-preplanning_complete}"
    python3 - "$out_file" "$gate_name" <<'PYEOF'
import json, sys, time

out_file = sys.argv[1]
gate_name = sys.argv[2]

payload = {
    "event_type": "PRECONDITIONS",
    "schema_version": 2,
    "manifest_depth": "standard",
    "gate_name": gate_name,
    "session_id": "test-session-std-001",
    "worktree_id": "test-branch-std",
    "tier": "standard",
    "timestamp": int(time.time() * 1000),
    "spec_hash": "def456",
    "gate_verdicts": ["story_gate_pass"],
    "workflow_completion_checklist": ["preplanning_done"],
    "completeness": "complete",
    "decisions_log": [{"decision": "use_default_approach", "rationale": "simplest path"}],
    "execution_context": {"agent": "preplanning", "session_ordinal": 1},
    "data": {}
}

with open(out_file, "w", encoding="utf-8") as f:
    json.dump(payload, f)
PYEOF
}

# ── Fixture: write a malformed/schema-invalid PRECONDITIONS event ─────────────
_write_invalid_preconditions_fixture() {
    local out_file="$1"
    python3 - "$out_file" <<'PYEOF'
import json, sys

out_file = sys.argv[1]

# Missing required fields: spec_hash, gate_verdicts, workflow_completion_checklist, completeness
payload = {
    "event_type": "PRECONDITIONS",
    "gate_name": "brainstorm_complete",
    "session_id": "test-session-bad",
    "data": {}
}

with open(out_file, "w", encoding="utf-8") as f:
    json.dump(payload, f)
PYEOF
}

# ── Test 1: _dso_pv_entry_check accepts a valid minimal-tier PRECONDITIONS event
test_pv_entry_check_accepts_valid_minimal_event() {
    local tmp_dir
    tmp_dir=$(_make_tmp_dir)

    local fixture_file="$tmp_dir/brainstorm_complete.json"
    _write_minimal_preconditions_fixture "$fixture_file" "brainstorm_complete"

    # Source the library — must exist and define _dso_pv_entry_check
    local exit_code=0
    (
        source "$LIB_PATH" 2>/dev/null
        # Override _read_latest_preconditions to return our fixture
        _read_latest_preconditions() { cat "$fixture_file"; }
        _dso_pv_entry_check "preplanning" "brainstorm_complete" "test-ticket-001"
    ) >/dev/null 2>&1 || exit_code=$?

    assert_eq \
        "entry_check_accepts_valid_minimal_event: exit code 0" \
        "0" \
        "$exit_code"
}

# ── Test 2: _dso_pv_entry_check rejects schema-invalid event with diagnostic ──
test_pv_entry_check_rejects_schema_invalid() {
    local tmp_dir
    tmp_dir=$(_make_tmp_dir)

    local fixture_file="$tmp_dir/bad_event.json"
    _write_invalid_preconditions_fixture "$fixture_file"

    local exit_code=0
    local stderr_output=""
    stderr_output=$(
        (
            source "$LIB_PATH" 2>/dev/null
            _read_latest_preconditions() { cat "$fixture_file"; }
            _dso_pv_entry_check "preplanning" "brainstorm_complete" "test-ticket-002"
        ) 2>&1 >/dev/null
    ) || exit_code=$?

    assert_ne \
        "entry_check_rejects_schema_invalid: exit code non-zero" \
        "0" \
        "$exit_code"

    assert_contains \
        "entry_check_rejects_schema_invalid: stderr has diagnostic" \
        "PRECONDITIONS" \
        "$stderr_output"
}

# ── Test 3: _dso_pv_entry_check ignores unknown fields (depth-agnostic) ────────
test_pv_entry_check_ignores_unknown_fields() {
    local tmp_dir
    tmp_dir=$(_make_tmp_dir)

    local fixture_file="$tmp_dir/standard_event.json"
    _write_standard_preconditions_fixture "$fixture_file" "brainstorm_complete"

    local exit_code=0
    (
        source "$LIB_PATH" 2>/dev/null
        _read_latest_preconditions() { cat "$fixture_file"; }
        _dso_pv_entry_check "preplanning" "brainstorm_complete" "test-ticket-003"
    ) >/dev/null 2>&1 || exit_code=$?

    assert_eq \
        "entry_check_ignores_unknown_fields: exit code 0 (depth-agnostic)" \
        "0" \
        "$exit_code"
}

# ── Test 4: _dso_pv_exit_write emits a PRECONDITIONS JSON file ────────────────
test_pv_exit_write_emits_preconditions() {
    local tmp_dir
    tmp_dir=$(_make_tmp_dir)

    local exit_code=0
    local written_file=""
    written_file=$(
        (
            export TICKETS_TRACKER_DIR="$tmp_dir/tracker"
            mkdir -p "$tmp_dir/tracker/test-ticket-004"
            # Create a .git stub so the tracker looks initialized
            touch "$tmp_dir/tracker/.git"
            source "$LIB_PATH" 2>/dev/null
            _dso_pv_exit_write "preplanning" "upstream-event-id-123" "spec-hash-abc" "test-ticket-004" 2>/dev/null
            # Find the written file
            find "$tmp_dir/tracker/test-ticket-004" -name "*-PRECONDITIONS.json" 2>/dev/null | head -1
        )
    ) || exit_code=$?

    assert_ne \
        "exit_write_emits_preconditions: written file path non-empty" \
        "" \
        "$written_file"

    if [[ -n "$written_file" && -f "$written_file" ]]; then
        local event_type
        event_type=$(python3 -c "import json,sys; d=json.load(open(sys.argv[1])); print(d.get('event_type',''))" "$written_file" 2>/dev/null || echo "")
        assert_eq \
            "exit_write_emits_preconditions: event_type is PRECONDITIONS" \
            "PRECONDITIONS" \
            "$event_type"
    else
        (( ++FAIL ))
        printf "FAIL: exit_write_emits_preconditions — file not found at: %s\n" "$written_file" >&2
    fi
}

# ── Test 5: _dso_pv_exit_write schema roundtrip ─────────────────────────────
test_pv_exit_write_schema_roundtrip() {
    local tmp_dir
    tmp_dir=$(_make_tmp_dir)

    local exit_code=0
    local written_file=""
    written_file=$(
        (
            export TICKETS_TRACKER_DIR="$tmp_dir/tracker"
            mkdir -p "$tmp_dir/tracker/test-ticket-005"
            touch "$tmp_dir/tracker/.git"
            source "$LIB_PATH" 2>/dev/null
            _dso_pv_exit_write "preplanning" "upstream-event-id-456" "spec-hash-def" "test-ticket-005" 2>/dev/null
            find "$tmp_dir/tracker/test-ticket-005" -name "*-PRECONDITIONS.json" 2>/dev/null | head -1
        )
    ) || exit_code=$?

    if [[ -z "$written_file" || ! -f "$written_file" ]]; then
        (( ++FAIL ))
        printf "FAIL: exit_write_schema_roundtrip — no PRECONDITIONS file written\n" >&2
        return
    fi

    # Roundtrip: validate the written file against the shared schema validator
    local roundtrip_exit=0
    bash "$VALIDATOR_SCRIPT" "test-ticket-005" "preplanning_complete" \
        "--event-file=$written_file" >/dev/null 2>&1 || roundtrip_exit=$?

    assert_eq \
        "exit_write_schema_roundtrip: roundtrip validation passes (exit 0)" \
        "0" \
        "$roundtrip_exit"
}

# ── Test 6: _dso_pv_exit_write sets upstream_event_id chain link ─────────────
test_pv_exit_write_chain_link() {
    local tmp_dir
    tmp_dir=$(_make_tmp_dir)

    local upstream_id="test-upstream-event-id-789"
    local exit_code=0
    local written_file=""
    written_file=$(
        (
            export TICKETS_TRACKER_DIR="$tmp_dir/tracker"
            mkdir -p "$tmp_dir/tracker/test-ticket-006"
            touch "$tmp_dir/tracker/.git"
            source "$LIB_PATH" 2>/dev/null
            _dso_pv_exit_write "preplanning" "$upstream_id" "spec-hash-ghi" "test-ticket-006" 2>/dev/null
            find "$tmp_dir/tracker/test-ticket-006" -name "*-PRECONDITIONS.json" 2>/dev/null | head -1
        )
    ) || exit_code=$?

    if [[ -z "$written_file" || ! -f "$written_file" ]]; then
        (( ++FAIL ))
        printf "FAIL: exit_write_chain_link — no PRECONDITIONS file written\n" >&2
        return
    fi

    local found_upstream
    found_upstream=$(python3 -c "
import json, sys
d = json.load(open(sys.argv[1]))
print(d.get('upstream_event_id', ''))
" "$written_file" 2>/dev/null || echo "")

    assert_eq \
        "exit_write_chain_link: upstream_event_id matches input" \
        "$upstream_id" \
        "$found_upstream"
}

# ── Run all tests ─────────────────────────────────────────────────────────────
echo "=== test-preconditions-validator-lib.sh ==="
test_pv_entry_check_accepts_valid_minimal_event
test_pv_entry_check_rejects_schema_invalid
test_pv_entry_check_ignores_unknown_fields
test_pv_exit_write_emits_preconditions
test_pv_exit_write_schema_roundtrip
test_pv_exit_write_chain_link

print_summary
