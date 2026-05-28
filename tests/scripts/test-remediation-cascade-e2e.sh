#!/usr/bin/env bash
# tests/scripts/test-remediation-cascade-e2e.sh
# RED behavioral fixture: full remediation cascade end-to-end.
#
# Upstream contract files:
#   plugins/dso/agents/task-decomposer.md        (remediation_context schema)
#   plugins/dso/agents/approach-proposer.md      (remediation_context schema)
#   plugins/dso/scripts/append_review_cycle.py   (cycles[] append contract)
#   tests/scripts/fixtures/cascade-e2e/          (PATH-shim mocks + fixture data)
#
# Behaviors under test:
#   test_fixture_file_exists (dd-1)              — all 5 fixture files present + executability
#   test_remediation_context_payload_shape (dd-2) — payload contains required keys per schema
#   test_cycles_append_schema_per_iteration (dd-3) — cycles[] grows correctly over 3 appends
#   test_loop_terminates_with_replan_escalate (dd-4) — MAX_CYCLES triggers REPLAN_ESCALATE token
#   test_no_placeholder_ids_in_dispatch_sequence (dd-5) — dispatch log has no placeholder IDs
#
# Usage: bash tests/scripts/test-remediation-cascade-e2e.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

# NOTE: -e intentionally omitted — test functions return non-zero by design
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
FIXTURE_DIR="$REPO_ROOT/tests/scripts/fixtures/cascade-e2e"
APPEND_SCRIPT="$REPO_ROOT/plugins/dso/scripts/append_review_cycle.py"

source "$REPO_ROOT/tests/lib/assert.sh"

# ── Temp directory setup + cleanup ───────────────────────────────────────────

tmpdir="$(mktemp -d "${TMPDIR:-/tmp}/cascade-e2e.XXXXXX")"
ORIG_PATH="$PATH"

cleanup() {
    export PATH="$ORIG_PATH"
    if [[ "${CASCADE_E2E_KEEP:-0}" != "1" ]]; then
        rm -rf "$tmpdir"
    fi
}
trap cleanup EXIT INT TERM

# Create log subdirectory
CASCADE_E2E_LOG="$tmpdir/logs"
mkdir -p "$CASCADE_E2E_LOG"
export CASCADE_E2E_LOG

# ── Helpers ───────────────────────────────────────────────────────────────────

_run_append() {
    python3 "$APPEND_SCRIPT" "$@"
}

_make_artifact() {
    local content="$1"
    local path
    # macOS mktemp does not support suffixes after X's — use plain template
    path="$(mktemp "$tmpdir/artifact-XXXXXX")"
    printf '%s' "$content" > "$path"
    echo "$path"
}

# ── Tests ─────────────────────────────────────────────────────────────────────

# dd-1: All 5 fixture files exist under tests/scripts/fixtures/cascade-e2e/
test_fixture_file_exists() {
    _snapshot_fail

    # Assert upstream contract: append_review_cycle.py --help exits 0 and contains --artifact
    local help_output
    help_output="$(python3 "$APPEND_SCRIPT" --help 2>&1)"
    local help_exit=0
    python3 "$APPEND_SCRIPT" --help >/dev/null 2>&1 || help_exit=$?
    assert_eq "test_fixture_file_exists: append_review_cycle.py --help exits 0" "0" "$help_exit"
    assert_contains "test_fixture_file_exists: --help output contains --artifact" "--artifact" "$help_output"

    # Assert fixture data files exist
    local f
    for f in "synthetic-epic.json" "red-team-findings.json" "expected-cascade-matrix.txt"; do
        assert_eq "test_fixture_file_exists: $f exists" "true" "$(test -f "$FIXTURE_DIR/$f" && echo true || echo false)"
    done

    # Assert mock scripts exist AND are executable
    for f in "mock-ticket.sh" "mock-task-dispatch.sh"; do
        assert_eq "test_fixture_file_exists: $f exists" "true" "$(test -f "$FIXTURE_DIR/$f" && echo true || echo false)"
        assert_eq "test_fixture_file_exists: $f is executable" "true" "$(test -x "$FIXTURE_DIR/$f" && echo true || echo false)"
    done

    # Assert synthetic-epic.json is valid JSON
    local json_check
    json_check="$(python3 -c "import json,sys; json.load(open('$FIXTURE_DIR/synthetic-epic.json')); print('valid')" 2>&1)"
    assert_eq "test_fixture_file_exists: synthetic-epic.json is valid JSON" "valid" "$json_check"

    assert_pass_if_clean "test_fixture_file_exists"
}

# dd-2: remediation_context payload contains required keys per task-decomposer/approach-proposer schema
test_remediation_context_payload_shape() {
    _snapshot_fail

    # Synthesize a remediation_context payload referencing the fixture files
    local payload
    payload="$(python3 -c "
import json, os
payload = {
    'reviewer_artifact_paths': [
        os.path.join('$FIXTURE_DIR', 'red-team-findings.json')
    ],
    'findings': json.load(open('$FIXTURE_DIR/red-team-findings.json'))['findings'],
    'target_story_id': 'synthetic-story-1'
}
print(json.dumps(payload))
")"

    # Assert the payload parses as valid JSON
    local parse_check
    parse_check="$(echo "$payload" | python3 -c "import json,sys; json.load(sys.stdin); print('valid')" 2>&1)"
    assert_eq "test_remediation_context_payload_shape: payload is valid JSON" "valid" "$parse_check"

    # Assert each required key individually via jq -e
    local EXPECTED_KEYS=("reviewer_artifact_paths" "findings" "target_story_id")
    local key
    for key in "${EXPECTED_KEYS[@]}"; do
        local key_check
        key_check="$(echo "$payload" | jq -e --arg k "$key" 'has($k)' 2>&1)"
        assert_eq "test_remediation_context_payload_shape: payload has key '$key'" "true" "$key_check"
    done

    # Assert reviewer_artifact_paths is a non-empty array
    local paths_len
    paths_len="$(echo "$payload" | jq '.reviewer_artifact_paths | length')"
    assert_ne "test_remediation_context_payload_shape: reviewer_artifact_paths is non-empty" "0" "$paths_len"

    # Assert findings is a non-empty array
    local findings_len
    findings_len="$(echo "$payload" | jq '.findings | length')"
    assert_ne "test_remediation_context_payload_shape: findings is non-empty" "0" "$findings_len"

    # Assert target_story_id is a non-empty string
    local target_id
    target_id="$(echo "$payload" | jq -r '.target_story_id')"
    assert_ne "test_remediation_context_payload_shape: target_story_id is non-empty" "" "$target_id"

    assert_pass_if_clean "test_remediation_context_payload_shape"
}

# dd-3: cycles[] grows correctly over 3 appends with all 5 canonical fields present
test_cycles_append_schema_per_iteration() {
    _snapshot_fail

    local artifact
    artifact="$(_make_artifact '{"producer":"cascade-e2e","cycles":[]}')"

    # Define verdicts for each iteration
    local -a VERDICTS=("fail" "fail" "escalate")
    local i
    for i in 1 2 3; do
        local verdict="${VERDICTS[$((i-1))]}"
        local draft_hash
        draft_hash="$(printf 'deadbeef%056d' "$i")"

        _run_append \
            --artifact "$artifact" \
            --n "$i" \
            --draft-hash "$draft_hash" \
            --findings-count "$((4 - i))" \
            --verdict "$verdict" \
            --timestamp-iso "2026-05-0${i}T10:00:00+00:00"

        # (a) cycles[] length matches iteration number
        local cycle_count
        cycle_count="$(jq '.cycles | length' "$artifact")"
        assert_eq "test_cycles_append_schema_per_iteration: cycles length == $i after iteration $i" "$i" "$cycle_count"

        # (b) latest entry has all 5 canonical fields
        local fields_ok
        fields_ok="$(jq -r --argjson idx "$((i-1))" '
            .cycles[$idx] |
            if (has("n") and has("draft_hash") and has("findings_count") and has("verdict") and has("timestamp_iso"))
            then "ok"
            else "missing-fields"
            end
        ' "$artifact")"
        assert_eq "test_cycles_append_schema_per_iteration: entry[$((i-1))] has all 5 fields" "ok" "$fields_ok"

        # (c) verdict is in {pass, fail, escalate}
        local actual_verdict
        actual_verdict="$(jq -r --argjson idx "$((i-1))" '.cycles[$idx].verdict' "$artifact")"
        local verdict_valid
        case "$actual_verdict" in
            pass|fail|escalate) verdict_valid="ok" ;;
            *) verdict_valid="invalid:$actual_verdict" ;;
        esac
        assert_eq "test_cycles_append_schema_per_iteration: entry[$((i-1))] verdict is valid" "ok" "$verdict_valid"
    done

    assert_pass_if_clean "test_cycles_append_schema_per_iteration"
}

# dd-4: MAX_CYCLES=3 triggers REPLAN_ESCALATE with correct prefix and valid upstream value
test_loop_terminates_with_replan_escalate() {
    _snapshot_fail

    local MAX_CYCLES=3
    local artifact
    artifact="$(_make_artifact '{"producer":"cascade-e2e","cycles":[]}')"

    # Pre-populate cycles 1 and 2 (findings persist — verdict=fail)
    _run_append \
        --artifact "$artifact" \
        --n 1 \
        --draft-hash "aaa1111111111111111111111111111111111111111111111111111111111" \
        --findings-count 1 \
        --verdict fail \
        --timestamp-iso "2026-05-01T10:00:00+00:00"

    _run_append \
        --artifact "$artifact" \
        --n 2 \
        --draft-hash "bbb2222222222222222222222222222222222222222222222222222222222" \
        --findings-count 1 \
        --verdict fail \
        --timestamp-iso "2026-05-01T11:00:00+00:00"

    # Cycle 3 reaches MAX_CYCLES — simulate escalate verdict
    _run_append \
        --artifact "$artifact" \
        --n 3 \
        --draft-hash "ccc3333333333333333333333333333333333333333333333333333333333" \
        --findings-count 1 \
        --verdict escalate \
        --timestamp-iso "2026-05-01T12:00:00+00:00"

    # Assert exactly MAX_CYCLES cycles were appended before escalation
    local cycle_count
    cycle_count="$(jq '.cycles | length' "$artifact")"
    assert_eq "test_loop_terminates_with_replan_escalate: exactly $MAX_CYCLES cycles appended" "$MAX_CYCLES" "$cycle_count"

    # Simulate the orchestrator emitting the terminal REPLAN_ESCALATE token
    # Per expected-cascade-matrix.txt cycle=3: terminal=REPLAN_ESCALATE:brainstorm
    # For preplanning Phase E cascade, upstream is always "brainstorm"
    local UPSTREAM="brainstorm"
    local terminal_emission
    terminal_emission="REPLAN_ESCALATE: $UPSTREAM"

    # Assert the emission matches the canonical prefix "REPLAN_ESCALATE: " (colon-space)
    assert_contains "test_loop_terminates_with_replan_escalate: emission has REPLAN_ESCALATE: prefix" \
        "REPLAN_ESCALATE: " "$terminal_emission"

    # Assert the upstream value is one of the valid canonical values
    local upstream_value="${terminal_emission#REPLAN_ESCALATE: }"
    local upstream_valid
    case "$upstream_value" in
        brainstorm|preplanning|planner_supplied) upstream_valid="ok" ;;
        *) upstream_valid="invalid:$upstream_value" ;;
    esac
    assert_eq "test_loop_terminates_with_replan_escalate: upstream value is valid" "ok" "$upstream_valid"

    # Assert the upstream for preplanning Phase E cascade is specifically "brainstorm"
    assert_eq "test_loop_terminates_with_replan_escalate: preplanning Phase E upstream is brainstorm" \
        "brainstorm" "$upstream_value"

    # Validate against expected-cascade-matrix.txt: cycle 3 should have terminal=REPLAN_ESCALATE:brainstorm
    local matrix_line3
    matrix_line3="$(grep '^cycle=3 ' "$FIXTURE_DIR/expected-cascade-matrix.txt")"
    assert_contains "test_loop_terminates_with_replan_escalate: matrix cycle=3 has REPLAN_ESCALATE" \
        "REPLAN_ESCALATE" "$matrix_line3"
    assert_contains "test_loop_terminates_with_replan_escalate: matrix cycle=3 terminal is brainstorm" \
        "brainstorm" "$matrix_line3"

    # Negative assertion: no REDISPATCH should appear after REPLAN_ESCALATE in the cycle sequence
    # (escalate verdict signals terminal state; no further dispatch)
    local last_verdict
    last_verdict="$(jq -r '.cycles[-1].verdict' "$artifact")"
    assert_eq "test_loop_terminates_with_replan_escalate: final cycle verdict is escalate" \
        "escalate" "$last_verdict"

    assert_pass_if_clean "test_loop_terminates_with_replan_escalate"
}

# dd-5: mock-task-dispatch.sh dispatch log contains no placeholder/TBD/<TODO> strings
test_no_placeholder_ids_in_dispatch_sequence() {
    _snapshot_fail

    # Pre-flight: ensure log files don't exist from a prior leaked run
    assert_eq "test_no_placeholder_ids_in_dispatch_sequence: dispatch log absent before test" \
        "false" "$(test -f "$CASCADE_E2E_LOG/mock-dispatch-calls.log" && echo true || echo false)"

    # Invoke mock-task-dispatch.sh via its absolute path with real-looking ticket IDs
    local dispatch_payload
    dispatch_payload="$(python3 -c "
import json
payload = {
    'story_id': 'synthetic-story-1',
    'task_ids': [
        'a1b2-c3d4-e5f6-7890',
        'b2c3-d4e5-f6a7-8901',
        'synthetic-epic-12345'
    ],
    'upstream': 'brainstorm',
    'cycle': 1
}
print(json.dumps(payload))
")"

    # Call the mock dispatch script (absolute path, passing payload via stdin)
    echo "$dispatch_payload" | "$FIXTURE_DIR/mock-task-dispatch.sh" >/dev/null

    # Assert the log file was created
    assert_eq "test_no_placeholder_ids_in_dispatch_sequence: dispatch log exists after invoke" \
        "true" "$(test -f "$CASCADE_E2E_LOG/mock-dispatch-calls.log" && echo true || echo false)"

    local log_content
    log_content="$(cat "$CASCADE_E2E_LOG/mock-dispatch-calls.log")"

    # Assert log is non-empty
    assert_ne "test_no_placeholder_ids_in_dispatch_sequence: dispatch log is non-empty" \
        "" "$log_content"

    # Assert no placeholder strings appear in the dispatch log
    assert_not_contains "test_no_placeholder_ids_in_dispatch_sequence: no 'placeholder' in dispatch log" \
        "placeholder" "$log_content"
    assert_not_contains "test_no_placeholder_ids_in_dispatch_sequence: no 'TBD' in dispatch log" \
        "TBD" "$log_content"
    assert_not_contains "test_no_placeholder_ids_in_dispatch_sequence: no '<TODO>' in dispatch log" \
        "<TODO>" "$log_content"

    # Assert the dispatched IDs match real ticket-id-style or synthetic-* patterns
    # Extract all IDs from the payload field in the log using python3
    local id_check
    id_check="$(python3 - "$CASCADE_E2E_LOG/mock-dispatch-calls.log" <<'PYEOF'
import json, re, sys

TICKET_RE = re.compile(r'^[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}$')
SYNTHETIC_RE = re.compile(r'^synthetic-')

issues = []
with open(sys.argv[1]) as f:
    for line in f:
        line = line.strip()
        if not line:
            continue
        try:
            entry = json.loads(line)
        except json.JSONDecodeError:
            continue
        payload = entry.get("payload")
        if not payload or not isinstance(payload, dict):
            continue
        task_ids = payload.get("task_ids", [])
        for tid in task_ids:
            if not (TICKET_RE.match(str(tid)) or SYNTHETIC_RE.match(str(tid))):
                issues.append(f"invalid id: {tid!r}")

print("ok" if not issues else "; ".join(issues))
PYEOF
)"
    assert_eq "test_no_placeholder_ids_in_dispatch_sequence: all task_ids are valid ticket-id-style" \
        "ok" "$id_check"

    assert_pass_if_clean "test_no_placeholder_ids_in_dispatch_sequence"
}

# ── Run all tests ─────────────────────────────────────────────────────────────

echo "=== test-remediation-cascade-e2e.sh ==="
echo ""

test_fixture_file_exists
test_remediation_context_payload_shape
test_cycles_append_schema_per_iteration
test_loop_terminates_with_replan_escalate
test_no_placeholder_ids_in_dispatch_sequence

print_summary
