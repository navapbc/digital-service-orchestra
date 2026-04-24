#!/usr/bin/env bash
# tests/scripts/test-classify-task.sh
# Baseline tests for scripts/classify-task.sh
#
# Usage: bash tests/scripts/test-classify-task.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DSO_PLUGIN_DIR="$PLUGIN_ROOT/plugins/dso"
REPO_ROOT="$(cd "$SCRIPT_DIR" && git rev-parse --show-toplevel)"
SCRIPT="$DSO_PLUGIN_DIR/scripts/classify-task.sh"

# Ensure CLAUDE_PLUGIN_ROOT is set (normally done by tests/run-all.sh)
export CLAUDE_PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$PLUGIN_ROOT}"

source "$(dirname "${BASH_SOURCE[0]}")/../lib/run_test.sh"

# Temp dir cleanup on exit
_CLEANUP_DIRS=()
_cleanup() { for d in "${_CLEANUP_DIRS[@]}"; do rm -rf "$d"; done; }
trap _cleanup EXIT

# ── Check PyYAML availability once ──────────────────────────────────────────
_HAS_PYYAML=false
if python3 -c "import yaml" 2>/dev/null; then
    _HAS_PYYAML=true
fi

# Helper: skip a test when PyYAML is not installed
_skip_no_pyyaml() {
    local test_name="$1"
    echo "  SKIP: $test_name (PyYAML not installed)"
    (( PASS++ ))  # count as pass so the suite doesn't fail
}

# ── Set up v3 ticket CLI stub environment for tests that call classify-task.sh ─
_MOCK_ENV="$(mktemp -d)"
_CLEANUP_DIRS+=("$_MOCK_ENV")

_MOCK_TASK_ID="mock-test-ticket-abc12"

# Create a v3 ticket CLI stub that responds to `ticket show <id>` and `ticket list`.
# This exercises the v3 JSON path that classify-task.sh actually uses.
cat > "$_MOCK_ENV/ticket" <<STUB
#!/usr/bin/env bash
SUBCOMMAND="\$1"; shift
case "\$SUBCOMMAND" in
    show)
        echo '{"ticket_id":"$_MOCK_TASK_ID","title":"Implement widget configuration parser","ticket_type":"story","status":"ready","priority":2}'
        ;;
    list)
        echo '[{"ticket_id":"$_MOCK_TASK_ID","title":"Implement widget configuration parser","ticket_type":"story","status":"ready"}]'
        ;;
    *)
        echo "[]"
        ;;
esac
STUB
chmod +x "$_MOCK_ENV/ticket"

# Point classify-task.sh to the stub so it uses the v3 JSON path.
export TICKET_CMD="$_MOCK_ENV/ticket"

echo "=== test-classify-task.sh ==="

# ── Test 1: Script is executable ──────────────────────────────────────────────
echo "Test 1: Script is executable"
if [ -x "$SCRIPT" ]; then
    echo "  PASS: script is executable"
    (( PASS++ ))
else
    echo "  FAIL: script is not executable" >&2
    (( FAIL++ ))
fi

# ── Test 2: No args exits 2 with usage ───────────────────────────────────────
echo "Test 2: No args exits 2 with usage"
run_test "missing task-id exits 2 with usage" 2 "[Uu]sage|classify-task" bash "$SCRIPT"

# ── Test 3: Valid task ID outputs JSON array ──────────────────────────────────
echo "Test 3: Valid task ID produces JSON array output"
if ! $_HAS_PYYAML; then
    _skip_no_pyyaml "valid task ID produces JSON array"
else
    output=$(bash "$SCRIPT" "$_MOCK_TASK_ID" 2>&1) || true
    if echo "$output" | python3 -c "import sys,json; data=json.load(sys.stdin); assert isinstance(data, list)" 2>/dev/null; then
        echo "  PASS: valid task ID produces JSON array"
        (( PASS++ ))
    else
        echo "  FAIL: valid task ID did not produce JSON array" >&2
        (( FAIL++ ))
    fi
fi

# ── Test 4: Classification output contains required fields ───────────────────
echo "Test 4: Classification output contains required fields (id, subagent, model, class)"
if ! $_HAS_PYYAML; then
    _skip_no_pyyaml "classification contains required fields"
else
    output=$(bash "$SCRIPT" "$_MOCK_TASK_ID" 2>&1) || true
    if echo "$output" | python3 -c "
import sys, json
data = json.load(sys.stdin)
if not data:
    print('Empty result', file=sys.stderr)
    sys.exit(1)
item = data[0]
required = ['id', 'subagent', 'model', 'class']
missing = [k for k in required if k not in item]
if missing:
    print('Missing fields:', missing, file=sys.stderr)
    sys.exit(1)
" 2>/dev/null; then
        echo "  PASS: classification contains required fields"
        (( PASS++ ))
    else
        echo "  FAIL: classification missing required fields" >&2
        (( FAIL++ ))
    fi
fi

# ── Test 5: Model field is one of valid values ───────────────────────────────
echo "Test 5: Model field is one of: haiku, sonnet, opus"
if ! $_HAS_PYYAML; then
    _skip_no_pyyaml "model field is valid (haiku/sonnet/opus)"
else
    output=$(bash "$SCRIPT" "$_MOCK_TASK_ID" 2>&1) || true
    if echo "$output" | python3 -c "
import sys, json
data = json.load(sys.stdin)
if not data:
    sys.exit(1)
model = data[0].get('model', '')
if model not in ('haiku', 'sonnet', 'opus'):
    print(f'Invalid model: {model}', file=sys.stderr)
    sys.exit(1)
" 2>/dev/null; then
        echo "  PASS: model field is valid (haiku/sonnet/opus)"
        (( PASS++ ))
    else
        echo "  FAIL: model field is not one of haiku/sonnet/opus" >&2
        (( FAIL++ ))
    fi
fi

# ── Test 6: --test mode exits 0 ──────────────────────────────────────────────
echo "Test 6: --test mode exits 0"
if ! $_HAS_PYYAML; then
    _skip_no_pyyaml "--test mode exits 0"
else
    exit_code=0
    bash "$SCRIPT" --test 2>&1 || exit_code=$?
    if [ "$exit_code" -eq 0 ]; then
        echo "  PASS: --test mode exits 0"
        (( PASS++ ))
    else
        echo "  FAIL: --test mode exited $exit_code" >&2
        (( FAIL++ ))
    fi
fi

# ── Test 7: No bash syntax errors ─────────────────────────────────────────────
echo "Test 7: No bash syntax errors"
if bash -n "$SCRIPT" 2>/dev/null; then
    echo "  PASS: no syntax errors"
    (( PASS++ ))
else
    echo "  FAIL: syntax errors found" >&2
    (( FAIL++ ))
fi


# ── Routing correctness tests ─────────────────────────────────────────────────
# These tests assert v3 ticket-CLI-based routing behavior.
# ── Test: Bug-type tasks never route to read-only agents ─────────────────────
echo "Test: Bug-type tasks never route to code-explorer (read-only)"
if ! $_HAS_PYYAML; then
    _skip_no_pyyaml "bug-type tasks never route to code-explorer"
else
{
    # Feed a bug-type task with "investigate" keywords to classify-task.py
    # and verify it does NOT get assigned to code-explorer
    PYTHON="python3"
    SCORER="$DSO_PLUGIN_DIR/scripts/classify-task.py"

    bug_task='[{"id":"test-bug","title":"Investigate timeout in ci-status.sh","description":"Trace and fix the timeout handling","task_type":"bug"}]'
    output=$(echo "$bug_task" | "$PYTHON" "$SCORER" 2>&1) || true

    subagent=$(echo "$output" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d[0]['subagent'])" 2>/dev/null) || subagent=""

    if [ "$subagent" = "feature-dev:code-explorer" ]; then
        echo "  FAIL: bug-type task was routed to code-explorer (read-only agent)" >&2
        (( FAIL++ ))
    elif [ -n "$subagent" ]; then
        echo "  PASS: bug-type task routed to $subagent (not code-explorer)"
        (( PASS++ ))
    else
        echo "  FAIL: could not parse subagent from output" >&2
        (( FAIL++ ))
    fi
}
fi

# ── Test: Non-bug investigate tasks still route to code-explorer ─────────────
echo "Test: Non-bug investigate tasks still route to code-explorer"
if ! $_HAS_PYYAML; then
    _skip_no_pyyaml "non-bug investigate tasks route to code-explorer"
else
{
    PYTHON="python3"
    SCORER="$DSO_PLUGIN_DIR/scripts/classify-task.py"

    nonbug_task='[{"id":"test-nonbug","title":"Investigate how the pipeline graph topology works","description":"Trace the pipeline graph topology to understand the execution flow"}]'
    output=$(echo "$nonbug_task" | "$PYTHON" "$SCORER" 2>&1) || true

    subagent=$(echo "$output" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d[0]['subagent'])" 2>/dev/null) || subagent=""

    if [ "$subagent" = "feature-dev:code-explorer" ]; then
        echo "  PASS: non-bug investigate task correctly routed to code-explorer"
        (( PASS++ ))
    else
        echo "  FAIL: non-bug investigate task routed to $subagent instead of code-explorer" >&2
        (( FAIL++ ))
    fi
}
fi

echo ""
echo "=== v3 ticket CLI integration tests ==="

# Helper: create a temp dir with a fake ticket stub that records calls
_setup_migration_test_env() {
    local tmpdir
    tmpdir="$(mktemp -d)"
    _CLEANUP_DIRS+=("$tmpdir")

    # Fake ticket: records invocation to a log file, returns empty JSON array
    cat > "$tmpdir/ticket" <<'STUB'
#!/usr/bin/env bash
echo "ticket $*" >> "$STUB_LOG"
echo "[]"
STUB
    chmod +x "$tmpdir/ticket"

    echo "$tmpdir"
}

# ── Test 8: classify-task.sh --from-epic calls ticket list ───────────────────
echo "Test 8: --from-epic uses ticket list"
{
    _tmpdir="$(_setup_migration_test_env)"
    _CLEANUP_DIRS+=("$_tmpdir")
    _log="$_tmpdir/stub.log"
    touch "$_log"
    export STUB_LOG="$_log"

    # Run with fake ticket on PATH ahead of real tools; suppress scorer errors
    output=$(TICKET_CMD="$_tmpdir/ticket" bash "$SCRIPT" --from-epic "fake-epic-id" 2>/dev/null) || true

    # Assert: ticket must have been invoked
    if grep -q "^ticket " "$_log" 2>/dev/null; then
        echo "  PASS: classify_task_from_epic_calls_ticket_list — --from-epic invoked ticket"
        (( PASS++ ))
    else
        echo "  FAIL: classify_task_from_epic_calls_ticket_list — ticket was not called" >&2
        (( FAIL++ ))
    fi

    rm -rf "$_tmpdir"
}

# ── Test 9: single task ID uses ticket show ───────────────────────────────────
echo "Test 9: single task ID uses ticket show"
{
    _tmpdir="$(_setup_migration_test_env)"
    _CLEANUP_DIRS+=("$_tmpdir")
    _log="$_tmpdir/stub.log"
    touch "$_log"
    export STUB_LOG="$_log"

    # Run with fake ticket; the stub returns [] so scorer gets empty input
    output=$(TICKET_CMD="$_tmpdir/ticket" bash "$SCRIPT" "fake-task-id" 2>/dev/null) || true

    # Assert: ticket must have been invoked with show
    if grep -q "^ticket show" "$_log" 2>/dev/null; then
        echo "  PASS: single task ID invoked ticket show"
        (( PASS++ ))
    else
        echo "  FAIL: classify_task_single_id_uses_ticket_show — ticket show was not called" >&2
        (( FAIL++ ))
    fi

    rm -rf "$_tmpdir"
}


# ── Test 10: v3 event-sourced tickets work without .tickets/*.md files ──────
echo "Test 10: --from-epic works with v3 event-sourced tickets (no .md files)"
{
    _v3_tmpdir="$(mktemp -d)"
    _CLEANUP_DIRS+=("$_v3_tmpdir")

    # Create a minimal v3 .tickets-tracker directory structure with two tickets:
    # - an epic (parent)
    # - a story that belongs to the epic
    _tracker_dir="$_v3_tmpdir/.tickets-tracker"
    _story_id="v3-story-test01"
    _epic_id="v3-epic-test01"
    mkdir -p "$_tracker_dir/$_epic_id"
    mkdir -p "$_tracker_dir/$_story_id"

    # Epic CREATE event
    cat > "$_tracker_dir/$_epic_id/20260101T000000Z_CREATE.json" <<JSON
{"event_type":"CREATE","ticket_id":"$_epic_id","data":{"ticket_type":"epic","title":"Test Epic","status":"open","priority":2},"created_at":"2026-01-01T00:00:00Z","env_id":"test"}
JSON

    # Story CREATE event — parent_id points to epic
    cat > "$_tracker_dir/$_story_id/20260101T000001Z_CREATE.json" <<JSON
{"event_type":"CREATE","ticket_id":"$_story_id","data":{"ticket_type":"story","title":"Implement v3 widget parser","status":"open","priority":2,"parent_id":"$_epic_id"},"created_at":"2026-01-01T00:00:01Z","env_id":"test"}
JSON

    # Create a fake `ticket` stub that serves both `ticket list` and `ticket show <id>`.
    # list: returns JSON array with parent_id included so the Python filter matches.
    # show: reads from the tracker dir via ticket-reducer.py.
    cat > "$_v3_tmpdir/ticket" <<STUB
#!/usr/bin/env bash
SUBCOMMAND="\$1"; shift
case "\$SUBCOMMAND" in
    show)
        python3 "${SCRIPT_DIR}/../../plugins/dso/scripts/ticket-reducer.py" "$_tracker_dir/\$1" 2>/dev/null || echo '{}'
        ;;
    list)
        echo '[{"ticket_id":"$_story_id","status":"open","parent_id":"$_epic_id"},{"ticket_id":"$_epic_id","status":"open"}]'
        ;;
    *)
        echo "[]"
        ;;
esac
STUB
    chmod +x "$_v3_tmpdir/ticket"

    # Run --from-epic with TICKET_CMD pointing to the stub so the new v3 path is exercised.
    # The story has parent_id set to the epic and status=ready, so it must be returned.
    output=$(TICKET_CMD="$_v3_tmpdir/ticket" bash "$SCRIPT" --from-epic "$_epic_id" 2>&1) || true

    # The key assertion: the story must appear in the classification result.
    # The v3 path uses `ticket list` (JSON) for parent filtering and `ticket show`
    # for per-task detail — no .md files are read.
    found_story=$(echo "$output" | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    ids = [item.get('id', '') for item in data]
    print('yes' if '$_story_id' in ids else 'no')
except Exception:
    print('no')
" 2>/dev/null) || found_story="no"

    if [ "$found_story" = "yes" ]; then
        echo "  PASS: classify_from_epic_v3_no_md_files — story found in result using v3 ticket data"
        (( PASS++ ))
    else
        echo "  FAIL: classify_from_epic_v3_no_md_files — story not returned; script likely fell back to .tickets/*.md lookup" >&2
        echo "    output: $output" >&2
        (( FAIL++ ))
    fi
}


# ── v2 dual-path removal regression tests ─────────────────────────────────────
# These tests assert that v2 dual-path code is absent from classify-task.sh.
# They guard against accidental reintroduction of removed v2 logic.

# ── test_classify_task_no_use_v3_detection ────────────────────────────────────
test_classify_task_no_use_v3_detection() {
    echo "Test: no _use_v3 detection flag in classify-task.sh"
    if { grep -q '_use_v3' "$SCRIPT"; test $? -ne 0; }; then
        echo "  PASS: _use_v3 not found in classify-task.sh"
        (( PASS++ ))
    else
        echo "  FAIL: _use_v3 still present in classify-task.sh (v2 dual-path code not removed)" >&2
        (( FAIL++ ))
    fi
}
test_classify_task_no_use_v3_detection

# ── test_classify_task_no_TICKETS_DIR_branch ─────────────────────────────────
test_classify_task_no_TICKETS_DIR_branch() {
    echo "Test: no .tickets/\$id.md file-read branch in classify-task.sh"
    # shellcheck disable=SC2016  # literal pattern match, $ must not expand
    if { grep -q '\.tickets/\$id\.md' "$SCRIPT"; test $? -ne 0; }; then
        echo "  PASS: .tickets/\$id.md branch not found in classify-task.sh"
        (( PASS++ ))
    else
        echo "  FAIL: .tickets/\$id.md still present in classify-task.sh (v2 TICKETS_DIR branch not removed)" >&2
        (( FAIL++ ))
    fi
}
test_classify_task_no_TICKETS_DIR_branch

# ── RED test-writer routing tests ─────────────────────────────────────────────
# These tests verify RED phase routing. The non-RED backward-compatibility test
# is placed BEFORE the RED tests so it sits outside the .test-index RED marker
# boundary ([test_red_create_test_routes_to_red_test_writer]).

# Helper: parse a field from classify-task.py JSON output
_parse_classify_field() {
    local field="$1"
    python3 -c "import sys,json; d=json.load(sys.stdin); print(d[0]['$field'])" 2>/dev/null
}

# ── test_non_red_test_still_routes_to_test_automator ─────────────────────────
# This test PASSES now (backward compat) and must stay outside the RED marker.
# NOTE: The red-test-writer.yaml profile (created in GREEN task d42c-5b5e) must
# NOT outscore test-automator.yaml for generic test-writing keywords like
# "unit tests" or "test coverage". The profile uses RED-specific keywords
# (RED:, create-test, modify-existing-test) to avoid false matches.
echo "Test: non-RED test task still routes to test-automator (not dso:red-test-writer)"
if ! $_HAS_PYYAML; then
    _skip_no_pyyaml "non-RED test task routes to test-automator"
else
{
    PYTHON="python3"
    SCORER="$DSO_PLUGIN_DIR/scripts/classify-task.py"

    regular_test_task='[{"id":"test-regular-test","title":"Write unit tests for parser","description":"Add unit tests covering the parser module logic and error handling"}]'
    output=$(echo "$regular_test_task" | "$PYTHON" "$SCORER" 2>&1) || true

    subagent=$(echo "$output" | _parse_classify_field subagent) || subagent=""

    if [ "$subagent" = "dso:red-test-writer" ]; then
        echo "  FAIL: test_non_red_test_still_routes_to_test_automator — regular test task incorrectly routed to dso:red-test-writer" >&2
        (( FAIL++ ))
    elif [ "$subagent" = "unit-testing:test-automator" ]; then
        echo "  PASS: test_non_red_test_still_routes_to_test_automator — regular test task routed to unit-testing:test-automator"
        (( PASS++ ))
    elif [ -n "$subagent" ]; then
        echo "  FAIL: test_non_red_test_still_routes_to_test_automator — expected unit-testing:test-automator, got $subagent" >&2
        (( FAIL++ ))
    else
        echo "  FAIL: test_non_red_test_still_routes_to_test_automator — could not parse subagent from output" >&2
        (( FAIL++ ))
    fi
}
fi

# ── RED tests below this line — covered by .test-index RED marker ────────────
# These FAIL until red-test-writer.yaml profile is created (GREEN task d42c-5b5e).

# ── test_red_create_test_routes_to_red_test_writer ────────────────────────────
echo "Test: RED create-test task routes to dso:red-test-writer"
if ! $_HAS_PYYAML; then
    _skip_no_pyyaml "RED create-test task routes to dso:red-test-writer"
else
{
    PYTHON="python3"
    SCORER="$DSO_PLUGIN_DIR/scripts/classify-task.py"

    red_create_task='[{"id":"test-red-create","title":"RED: Create test for auth module","description":"create-test behavioral test failing test assert on output"}]'
    output=$(echo "$red_create_task" | "$PYTHON" "$SCORER" 2>&1) || true

    subagent=$(echo "$output" | _parse_classify_field subagent) || subagent=""
    model=$(echo "$output" | _parse_classify_field model) || model=""

    # NOTE: PASS/FAIL lines must start at column 0 (no indent) for red-zone.sh
    # parse_failing_tests_from_output() which matches ^FAIL: at line start.
    if [ "$subagent" = "dso:red-test-writer" ] && [ "$model" = "sonnet" ]; then
        echo "PASS: test_red_create_test_routes_to_red_test_writer — routed to dso:red-test-writer (model=$model)"
        (( PASS++ ))
    elif [ "$subagent" = "dso:red-test-writer" ]; then
        echo "FAIL: test_red_create_test_routes_to_red_test_writer — correct agent but expected model=sonnet, got $model" >&2
        (( FAIL++ ))
    else
        echo "FAIL: test_red_create_test_routes_to_red_test_writer — expected dso:red-test-writer, got $subagent" >&2
        (( FAIL++ ))
    fi
}
fi

# ── test_red_modify_test_routes_to_red_test_writer ────────────────────────────
echo "Test: RED modify-existing-test task routes to dso:red-test-writer"
if ! $_HAS_PYYAML; then
    _skip_no_pyyaml "RED modify-existing-test task routes to dso:red-test-writer"
else
{
    PYTHON="python3"
    SCORER="$DSO_PLUGIN_DIR/scripts/classify-task.py"

    red_modify_task='[{"id":"test-red-modify","title":"RED: Modify existing test for payment flow","description":"modify-existing-test behavioral test assert on updated output"}]'
    output=$(echo "$red_modify_task" | "$PYTHON" "$SCORER" 2>&1) || true

    subagent=$(echo "$output" | _parse_classify_field subagent) || subagent=""
    model=$(echo "$output" | _parse_classify_field model) || model=""

    # NOTE: PASS/FAIL lines at column 0 for red-zone.sh compatibility.
    if [ "$subagent" = "dso:red-test-writer" ] && [ "$model" = "sonnet" ]; then
        echo "PASS: test_red_modify_test_routes_to_red_test_writer — routed to dso:red-test-writer (model=$model)"
        (( PASS++ ))
    elif [ "$subagent" = "dso:red-test-writer" ]; then
        echo "FAIL: test_red_modify_test_routes_to_red_test_writer — correct agent but expected model=sonnet, got $model" >&2
        (( FAIL++ ))
    else
        echo "FAIL: test_red_modify_test_routes_to_red_test_writer — expected dso:red-test-writer, got $subagent" >&2
        (( FAIL++ ))
    fi
}
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
