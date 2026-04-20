#!/usr/bin/env bash
# tests/integration/test-preconditions-chain-5stage.sh
# Integration tests for the full 5-stage preconditions chain:
# brainstorm → preplanning → impl-plan → sprint → commit → epic-closure
#
# Tests the EXECUTABLE preconditions-validator-lib.sh functions, not the
# instruction files. Behavioral TDD applies (per Rule 5 exception for
# executable code).
#
# Tests use temp dirs for isolation — no shared mutable state between runs.
#
# RED: tests fail before 7aa2-70f9 wires the 5-stage chain.
# GREEN: tests pass after full chain integration.
# shellcheck disable=SC2030,SC2031
# SC2030/SC2031: TICKETS_TRACKER_DIR is intentionally scoped to test subshells

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
PLUGIN_ROOT="$REPO_ROOT/plugins/dso"
LIB_PATH="$PLUGIN_ROOT/hooks/lib/preconditions-validator-lib.sh"

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

# ── Helper: write a minimal-tier PRECONDITIONS fixture to tracker dir ─────────
_write_chain_event() {
    local tracker_dir="$1"
    local ticket_id="$2"
    local gate_name="$3"
    local upstream_event_id="${4:-}"
    local extra_fields="${5:-}"  # JSON object string with extra fields (standard-tier test)

    python3 - "$tracker_dir" "$ticket_id" "$gate_name" "$upstream_event_id" "$extra_fields" <<'PYEOF'
import json, os, sys, time, uuid

tracker_dir      = sys.argv[1]
ticket_id        = sys.argv[2]
gate_name        = sys.argv[3]
upstream_event_id = sys.argv[4]
extra_fields_str = sys.argv[5]

ticket_dir = os.path.join(tracker_dir, ticket_id)
os.makedirs(ticket_dir, exist_ok=True)

timestamp_ms = int(time.time() * 1000)
file_uuid = str(uuid.uuid4())
filename = f"{timestamp_ms}-{file_uuid}-PRECONDITIONS.json"
out_path = os.path.join(ticket_dir, filename)

payload = {
    "event_type": "PRECONDITIONS",
    "schema_version": 1,
    "manifest_depth": "minimal",
    "gate_name": gate_name,
    "session_id": f"test-session-chain-{timestamp_ms}",
    "worktree_id": "test-worktree-chain",
    "tier": "minimal",
    "timestamp": timestamp_ms,
    "spec_hash": f"spec-hash-{gate_name}",
    "gate_verdicts": [],
    "workflow_completion_checklist": [],
    "completeness": "complete",
    "data": {},
}

if upstream_event_id:
    payload["upstream_event_id"] = upstream_event_id

# Merge in extra fields (for standard-tier forward-compat test)
if extra_fields_str:
    try:
        extras = json.loads(extra_fields_str)
        payload.update(extras)
    except Exception:
        pass

with open(out_path, "w", encoding="utf-8") as f:
    json.dump(payload, f, ensure_ascii=False)

# Print the event UUID so chain tests can reference it
print(file_uuid, end="")
PYEOF
}

# ── Test 1: brainstorm → preplanning chain ────────────────────────────────────
test_chain_brainstorm_to_preplanning_preconditions() {
    local tmp_dir
    tmp_dir=$(_make_tmp_dir)
    local tracker_dir="$tmp_dir/tracker"
    local ticket_id="chain-test-ticket-001"

    # Write a brainstorm_complete event
    _write_chain_event "$tracker_dir" "$ticket_id" "brainstorm_complete" >/dev/null

    local exit_code=0
    (
        export TICKETS_TRACKER_DIR="$tracker_dir"
        source "$LIB_PATH" 2>/dev/null
        _dso_pv_entry_check "preplanning" "brainstorm_complete" "$ticket_id"
    ) >/dev/null 2>&1 || exit_code=$?

    assert_eq \
        "chain_brainstorm_to_preplanning: entry check passes (exit 0)" \
        "0" \
        "$exit_code"
}

# ── Test 2: preplanning → impl-plan chain ────────────────────────────────────
test_chain_preplanning_to_impl_plan_preconditions() {
    local tmp_dir
    tmp_dir=$(_make_tmp_dir)
    local tracker_dir="$tmp_dir/tracker"
    local ticket_id="chain-test-ticket-002"

    _write_chain_event "$tracker_dir" "$ticket_id" "preplanning_complete" >/dev/null

    local exit_code=0
    (
        export TICKETS_TRACKER_DIR="$tracker_dir"
        source "$LIB_PATH" 2>/dev/null
        _dso_pv_entry_check "implementation-plan" "preplanning_complete" "$ticket_id"
    ) >/dev/null 2>&1 || exit_code=$?

    assert_eq \
        "chain_preplanning_to_impl_plan: entry check passes (exit 0)" \
        "0" \
        "$exit_code"
}

# ── Test 3: impl-plan → sprint chain ─────────────────────────────────────────
test_chain_impl_plan_to_sprint_preconditions() {
    local tmp_dir
    tmp_dir=$(_make_tmp_dir)
    local tracker_dir="$tmp_dir/tracker"
    local ticket_id="chain-test-ticket-003"

    _write_chain_event "$tracker_dir" "$ticket_id" "implementation-plan_complete" >/dev/null

    local exit_code=0
    (
        export TICKETS_TRACKER_DIR="$tracker_dir"
        source "$LIB_PATH" 2>/dev/null
        _dso_pv_entry_check "sprint" "implementation-plan_complete" "$ticket_id"
    ) >/dev/null 2>&1 || exit_code=$?

    assert_eq \
        "chain_impl_plan_to_sprint: entry check passes (exit 0)" \
        "0" \
        "$exit_code"
}

# ── Test 4: sprint → commit chain ────────────────────────────────────────────
test_chain_sprint_to_commit_preconditions() {
    local tmp_dir
    tmp_dir=$(_make_tmp_dir)
    local tracker_dir="$tmp_dir/tracker"
    local ticket_id="chain-test-ticket-004"

    _write_chain_event "$tracker_dir" "$ticket_id" "sprint_complete" >/dev/null

    local exit_code=0
    (
        export TICKETS_TRACKER_DIR="$tracker_dir"
        source "$LIB_PATH" 2>/dev/null
        _dso_pv_entry_check "commit" "sprint_complete" "$ticket_id"
    ) >/dev/null 2>&1 || exit_code=$?

    assert_eq \
        "chain_sprint_to_commit: entry check passes (exit 0)" \
        "0" \
        "$exit_code"
}

# ── Test 5: commit → epic-closure chain ──────────────────────────────────────
test_chain_commit_to_epic_closure_preconditions() {
    local tmp_dir
    tmp_dir=$(_make_tmp_dir)
    local tracker_dir="$tmp_dir/tracker"
    local ticket_id="chain-test-ticket-005"

    _write_chain_event "$tracker_dir" "$ticket_id" "commit_complete" >/dev/null

    local exit_code=0
    (
        export TICKETS_TRACKER_DIR="$tracker_dir"
        source "$LIB_PATH" 2>/dev/null
        _dso_pv_entry_check "epic-closure" "commit_complete" "$ticket_id"
    ) >/dev/null 2>&1 || exit_code=$?

    assert_eq \
        "chain_commit_to_epic_closure: entry check passes (exit 0)" \
        "0" \
        "$exit_code"
}

# ── Test 6: depth-agnostic — standard-tier event accepted by minimal reader ───
test_chain_depth_agnostic_standard_tier_read() {
    local tmp_dir
    tmp_dir=$(_make_tmp_dir)
    local tracker_dir="$tmp_dir/tracker"
    local ticket_id="chain-test-ticket-006"

    # Standard-tier event: has extra fields beyond minimal tier
    local extra='{"decisions_log":[{"decision":"use_default","rationale":"simple"}],"execution_context":{"agent":"preplanning","ordinal":1},"schema_version":2,"manifest_depth":"standard","tier":"standard"}'
    _write_chain_event "$tracker_dir" "$ticket_id" "brainstorm_complete" "" "$extra" >/dev/null

    local exit_code=0
    (
        export TICKETS_TRACKER_DIR="$tracker_dir"
        source "$LIB_PATH" 2>/dev/null
        # entry_check should accept standard-tier events (depth-agnostic: extra fields ignored)
        _dso_pv_entry_check "preplanning" "brainstorm_complete" "$ticket_id"
    ) >/dev/null 2>&1 || exit_code=$?

    assert_eq \
        "chain_depth_agnostic_standard_tier_read: standard-tier event accepted (exit 0)" \
        "0" \
        "$exit_code"
}

# ── Test 7: event_id chain links form a valid 5-event chain ──────────────────
test_chain_event_id_links_form_valid_chain() {
    local tmp_dir
    tmp_dir=$(_make_tmp_dir)
    local tracker_dir="$tmp_dir/tracker"
    local ticket_id="chain-test-ticket-007"

    # Stage 1: write brainstorm event (no upstream)
    local bs_uuid
    bs_uuid=$(_write_chain_event "$tracker_dir" "$ticket_id" "brainstorm_complete")

    # Stage 2: write preplanning event linking to brainstorm
    local pp_uuid
    pp_uuid=$(_write_chain_event "$tracker_dir" "$ticket_id" "preplanning_complete" "$bs_uuid")

    # Stage 3: write impl-plan event linking to preplanning
    local ip_uuid
    ip_uuid=$(_write_chain_event "$tracker_dir" "$ticket_id" "implementation-plan_complete" "$pp_uuid")

    # Verify impl-plan event references preplanning uuid
    local found_pp_ref=0
    python3 - "$tracker_dir" "$ticket_id" "implementation-plan_complete" "$pp_uuid" <<'PYEOF'
import json, os, sys

tracker_dir = sys.argv[1]
ticket_id   = sys.argv[2]
gate_name   = sys.argv[3]
expected_id = sys.argv[4]

ticket_dir = os.path.join(tracker_dir, ticket_id)
candidates = []
for fname in os.listdir(ticket_dir):
    if not fname.endswith("-PRECONDITIONS.json"):
        continue
    fpath = os.path.join(ticket_dir, fname)
    try:
        with open(fpath, encoding="utf-8") as f:
            data = json.load(f)
    except Exception:
        continue
    if data.get("gate_name") == gate_name:
        candidates.append((fname, data))

if not candidates:
    sys.exit(1)

candidates.sort(key=lambda x: x[0])
_, latest = candidates[-1]

upstream_id = latest.get("upstream_event_id", "")
if expected_id in upstream_id:
    sys.exit(0)
sys.exit(1)
PYEOF
    found_pp_ref=$?

    assert_eq \
        "chain_event_id_links_form_valid_chain: impl-plan event references preplanning uuid" \
        "0" \
        "$found_pp_ref"
}

# ── Run all tests ─────────────────────────────────────────────────────────────
echo "=== test-preconditions-chain-5stage.sh ==="
test_chain_brainstorm_to_preplanning_preconditions
test_chain_preplanning_to_impl_plan_preconditions
test_chain_impl_plan_to_sprint_preconditions
test_chain_sprint_to_commit_preconditions
test_chain_commit_to_epic_closure_preconditions
test_chain_depth_agnostic_standard_tier_read
test_chain_event_id_links_form_valid_chain

print_summary
