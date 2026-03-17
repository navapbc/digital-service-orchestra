#!/usr/bin/env bash
# tests/scripts/test-classify-task.sh
# Baseline tests for scripts/classify-task.sh
#
# Usage: bash tests/scripts/test-classify-task.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR" && git rev-parse --show-toplevel)"
SCRIPT="$PLUGIN_ROOT/scripts/classify-task.sh"

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

# ── Set up mock ticket environment for tests that call classify-task.sh ─────
_MOCK_ENV="$(mktemp -d)"
_CLEANUP_DIRS+=("$_MOCK_ENV")

_MOCK_TICKETS_DIR="$_MOCK_ENV/.tickets"
mkdir -p "$_MOCK_TICKETS_DIR"

# Create a mock ticket file that tk show can read
cat > "$_MOCK_TICKETS_DIR/mock-test-ticket-abc12.md" <<'TICKET'
---
id: mock-test-ticket-abc12
status: ready
type: feature
---
# Implement widget configuration parser

Parse the YAML configuration files and generate typed settings objects.
TICKET

# Export TICKETS_DIR so the plugin's tk script finds our mock .tickets/
export TICKETS_DIR="$_MOCK_TICKETS_DIR"

# Put the plugin's scripts dir on PATH so classify-task.sh finds tk
export PATH="$PLUGIN_ROOT/scripts:$PATH"

# Use the mock ticket ID for tests that need a valid task
_MOCK_TASK_ID="mock-test-ticket-abc12"

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


# ── TDD RED Phase: bd→tk migration tests ──────────────────────────────────────
# These tests assert tk-based behavior. They FAIL against the current bd-based
# implementation and will PASS once classify-task.sh is migrated to use tk.
# ── Test: Bug-type tasks never route to read-only agents ─────────────────────
echo "Test: Bug-type tasks never route to code-explorer (read-only)"
if ! $_HAS_PYYAML; then
    _skip_no_pyyaml "bug-type tasks never route to code-explorer"
else
{
    # Feed a bug-type task with "investigate" keywords to classify-task.py
    # and verify it does NOT get assigned to code-explorer
    PYTHON="python3"
    SCORER="$PLUGIN_ROOT/scripts/classify-task.py"

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
    SCORER="$PLUGIN_ROOT/scripts/classify-task.py"

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
echo "=== TDD RED Phase: bd→tk migration tests ==="

# Helper: create a controlled TICKETS_DIR with a fake tk stub that records calls
_setup_migration_test_env() {
    local tmpdir
    tmpdir="$(mktemp -d)"
    _CLEANUP_DIRS+=("$tmpdir")

    # Fake tk: records invocation to a log file, returns empty JSON array
    cat > "$tmpdir/tk" <<'STUB'
#!/usr/bin/env bash
echo "tk $*" >> "$STUB_LOG"
echo "[]"
STUB
    chmod +x "$tmpdir/tk"

    echo "$tmpdir"
}

# ── Test 8: classify-task.sh --from-epic calls tk ready ──────────────────────
echo "Test 8: --from-epic uses tk ready"
{
    _tmpdir="$(_setup_migration_test_env)"
    _CLEANUP_DIRS+=("$_tmpdir")
    _log="$_tmpdir/stub.log"
    touch "$_log"
    export STUB_LOG="$_log"

    # Run with fake tk on PATH ahead of real tools; suppress scorer errors
    output=$(PATH="$_tmpdir:$PATH" bash "$SCRIPT" --from-epic "fake-epic-id" 2>/dev/null) || true

    # Assert: tk must have been invoked
    if grep -q "^tk " "$_log" 2>/dev/null; then
        echo "  PASS: classify_task_from_epic_calls_tk_ready — --from-epic invoked tk"
        (( PASS++ ))
    else
        echo "  FAIL: classify_task_from_epic_calls_tk_ready — tk was not called" >&2
        (( FAIL++ ))
    fi

    rm -rf "$_tmpdir"
}

# ── Test 9: single task ID uses tk show ──────────────────────────────────────
echo "Test 9: single task ID uses tk show"
{
    _tmpdir="$(_setup_migration_test_env)"
    _CLEANUP_DIRS+=("$_tmpdir")
    _log="$_tmpdir/stub.log"
    touch "$_log"
    export STUB_LOG="$_log"

    # Run with fake tk on PATH; the stub returns [] so scorer gets empty input
    output=$(PATH="$_tmpdir:$PATH" bash "$SCRIPT" "fake-task-id" 2>/dev/null) || true

    # Assert: tk must have been invoked with show
    if grep -q "^tk show" "$_log" 2>/dev/null; then
        echo "  PASS: single task ID invoked tk show"
        (( PASS++ ))
    else
        echo "  FAIL: classify_task_single_id_uses_tk_show — tk show was not called" >&2
        (( FAIL++ ))
    fi

    rm -rf "$_tmpdir"
}

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
