#!/usr/bin/env bash
# tests/scripts/test-emit-commit-workflow-event.sh
# RED tests for plugins/dso/scripts/emit-commit-workflow-event.sh (does NOT exist yet).
#
# Covers: valid JSONL output for commit workflow start/end phases, failure
# reason capture, start timestamp persistence for duration calculation, and
# graceful failure (best-effort — wrapper returns 0 even if emit fails).
#
# Usage: bash tests/scripts/test-emit-commit-workflow-event.sh

# NOTE: -e is intentionally omitted — test functions return non-zero by design
# (they assert against unimplemented features). -e would abort the runner.
set -uo pipefail

_CLEANUP_DIRS=()

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"
EMIT_SCRIPT="$REPO_ROOT/plugins/dso/scripts/emit-commit-workflow-event.sh"

source "$REPO_ROOT/tests/lib/assert.sh"
source "$REPO_ROOT/tests/lib/git-fixtures.sh"

echo "=== test-emit-commit-workflow-event.sh ==="

# ── Helper: create a fresh temp dir for artifacts ─────────────────────────────
_make_artifacts_dir() {
    local tmp
    tmp=$(mktemp -d)
    _CLEANUP_DIRS+=("$tmp")
    echo "$tmp"
}

# ── Test 1: start phase emits valid JSONL ─────────────────────────────────────
echo "Test 1: emit-commit-workflow-event.sh --phase=start emits valid JSONL"
test_commit_event_start_emits_valid_jsonl() {
    # emit-commit-workflow-event.sh must exist — RED: it does not exist yet
    if [ ! -f "$EMIT_SCRIPT" ]; then
        assert_eq "emit-commit-workflow-event.sh exists" "exists" "missing"
        return
    fi

    local artifacts_dir
    artifacts_dir=$(_make_artifacts_dir)
    export WORKFLOW_PLUGIN_ARTIFACTS_DIR="$artifacts_dir"

    # Call with --phase=start
    local output exit_code=0
    output=$(bash "$EMIT_SCRIPT" --phase=start 2>/dev/null) || exit_code=$?

    assert_eq "start phase exits zero" "0" "$exit_code"

    # Parse output as JSONL — must be valid JSON
    local parse_exit=0
    local parsed
    parsed=$(python3 -c "
import json, sys
data = json.loads(sys.argv[1])
# Verify required fields
assert data.get('event_type') == 'commit_workflow', f\"event_type={data.get('event_type')}\"
assert data.get('phase') == 'start', f\"phase={data.get('phase')}\"
assert 'timestamp' in data, 'timestamp missing'
print('valid')
" "$output" 2>&1) || parse_exit=$?

    assert_eq "start event is valid JSONL with correct fields" "0" "$parse_exit"
    assert_eq "parsed output says valid" "valid" "$parsed"
}
test_commit_event_start_emits_valid_jsonl

# ── Test 2: end phase emits valid JSONL with success and duration ─────────────
echo "Test 2: emit-commit-workflow-event.sh --phase=end --success=true emits JSONL with duration_ms"
test_commit_event_end_emits_valid_jsonl() {
    # emit-commit-workflow-event.sh must exist — RED: it does not exist yet
    if [ ! -f "$EMIT_SCRIPT" ]; then
        assert_eq "emit-commit-workflow-event.sh exists for end-phase test" "exists" "missing"
        return
    fi

    local artifacts_dir
    artifacts_dir=$(_make_artifacts_dir)
    export WORKFLOW_PLUGIN_ARTIFACTS_DIR="$artifacts_dir"

    # Simulate a start event first (so duration can be calculated)
    bash "$EMIT_SCRIPT" --phase=start 2>/dev/null || true
    sleep 1

    # Call with --phase=end --success=true
    local output exit_code=0
    output=$(bash "$EMIT_SCRIPT" --phase=end --success=true 2>/dev/null) || exit_code=$?

    assert_eq "end phase exits zero" "0" "$exit_code"

    # Parse and verify fields
    local parse_exit=0
    local parsed
    parsed=$(python3 -c "
import json, sys
data = json.loads(sys.argv[1])
assert data.get('event_type') == 'commit_workflow', f\"event_type={data.get('event_type')}\"
assert data.get('phase') == 'end', f\"phase={data.get('phase')}\"
assert data.get('success') is True, f\"success={data.get('success')}\"
assert 'duration_ms' in data, 'duration_ms missing'
assert isinstance(data['duration_ms'], (int, float)), f\"duration_ms type={type(data['duration_ms'])}\"
print('valid')
" "$output" 2>&1) || parse_exit=$?

    assert_eq "end event has phase=end, success=true, duration_ms" "0" "$parse_exit"
}
test_commit_event_end_emits_valid_jsonl

# ── Test 3: end phase with failure captures failure_reason ────────────────────
echo "Test 3: emit-commit-workflow-event.sh --phase=end --success=false --failure-reason captures reason"
test_commit_event_end_failure() {
    # emit-commit-workflow-event.sh must exist — RED: it does not exist yet
    if [ ! -f "$EMIT_SCRIPT" ]; then
        assert_eq "emit-commit-workflow-event.sh exists for end-failure test" "exists" "missing"
        return
    fi

    local artifacts_dir
    artifacts_dir=$(_make_artifacts_dir)
    export WORKFLOW_PLUGIN_ARTIFACTS_DIR="$artifacts_dir"

    # Start phase first
    bash "$EMIT_SCRIPT" --phase=start 2>/dev/null || true

    # Call with --phase=end --success=false --failure-reason="review failed"
    local output exit_code=0
    output=$(bash "$EMIT_SCRIPT" --phase=end --success=false --failure-reason="review failed" 2>/dev/null) || exit_code=$?

    assert_eq "end-failure phase exits zero" "0" "$exit_code"

    # Parse and verify failure_reason field
    local parse_exit=0
    local parsed
    parsed=$(python3 -c "
import json, sys
data = json.loads(sys.argv[1])
assert data.get('phase') == 'end', f\"phase={data.get('phase')}\"
assert data.get('success') is False, f\"success={data.get('success')}\"
assert 'failure_reason' in data, 'failure_reason missing'
assert data['failure_reason'] == 'review failed', f\"failure_reason={data.get('failure_reason')}\"
print('valid')
" "$output" 2>&1) || parse_exit=$?

    assert_eq "end-failure event has failure_reason='review failed'" "0" "$parse_exit"
}
test_commit_event_end_failure

# ── Test 4: start phase persists timestamp for duration calculation ───────────
echo "Test 4: emit-commit-workflow-event.sh --phase=start records timestamp to artifact"
test_commit_event_start_records_timestamp() {
    # emit-commit-workflow-event.sh must exist — RED: it does not exist yet
    if [ ! -f "$EMIT_SCRIPT" ]; then
        assert_eq "emit-commit-workflow-event.sh exists for timestamp-persistence test" "exists" "missing"
        return
    fi

    local artifacts_dir
    artifacts_dir=$(_make_artifacts_dir)
    export WORKFLOW_PLUGIN_ARTIFACTS_DIR="$artifacts_dir"

    # Call with --phase=start
    bash "$EMIT_SCRIPT" --phase=start 2>/dev/null || true

    # Verify a start timestamp file was persisted to the artifacts dir
    local ts_file="$artifacts_dir/commit-workflow-start-ts"
    assert_eq "start timestamp file exists" "1" "$([ -f "$ts_file" ] && echo 1 || echo 0)"

    # Verify content is a numeric epoch timestamp (milliseconds or seconds)
    if [ -f "$ts_file" ]; then
        local ts_content
        ts_content=$(cat "$ts_file")
        local is_numeric
        is_numeric=$(python3 -c "
import sys
try:
    val = int(sys.argv[1])
    print('yes' if val > 0 else 'no')
except ValueError:
    print('no')
" "$ts_content" 2>/dev/null || echo "no")
        assert_eq "start timestamp is a positive integer" "yes" "$is_numeric"
    fi
}
test_commit_event_start_records_timestamp

# ── Test 5: graceful failure — wrapper returns 0 even if underlying emit fails
echo "Test 5: emit-commit-workflow-event.sh returns 0 even when emit-review-event.sh fails (best-effort)"
test_commit_event_graceful_failure() {
    # emit-commit-workflow-event.sh must exist — RED: it does not exist yet
    if [ ! -f "$EMIT_SCRIPT" ]; then
        assert_eq "emit-commit-workflow-event.sh exists for graceful-failure test" "exists" "missing"
        return
    fi

    local artifacts_dir
    artifacts_dir=$(_make_artifacts_dir)
    export WORKFLOW_PLUGIN_ARTIFACTS_DIR="$artifacts_dir"

    # Stub emit-review-event.sh to always fail
    local stub_dir
    stub_dir=$(mktemp -d)
    _CLEANUP_DIRS+=("$stub_dir")
    cat > "$stub_dir/emit-review-event.sh" <<'STUB'
#!/usr/bin/env bash
echo "ERROR: stubbed failure" >&2
exit 1
STUB
    chmod +x "$stub_dir/emit-review-event.sh"

    # Prepend stub dir to PATH so wrapper finds the failing stub first
    local exit_code=0
    PATH="$stub_dir:$PATH" bash "$EMIT_SCRIPT" --phase=start 2>/dev/null || exit_code=$?

    # Wrapper must return 0 (best-effort, never propagates emit failure to caller)
    assert_eq "returns 0 despite underlying emit failure" "0" "$exit_code"
}
test_commit_event_graceful_failure

print_summary
