#!/usr/bin/env bash
# lockpick-workflow/tests/scripts/test-classify-task.sh
# Baseline tests for scripts/classify-task.sh
#
# Usage: bash lockpick-workflow/tests/scripts/test-classify-task.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
SCRIPT="$REPO_ROOT/lockpick-workflow/scripts/classify-task.sh"

source "$(dirname "${BASH_SOURCE[0]}")/../lib/run_test.sh"

# Temp dir cleanup on exit
_CLEANUP_DIRS=()
_cleanup() { for d in "${_CLEANUP_DIRS[@]}"; do rm -rf "$d"; done; }
trap _cleanup EXIT

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
output=$(bash "$SCRIPT" "lockpick-doc-to-logic-l12cy" 2>&1) || true
if echo "$output" | python3 -c "import sys,json; data=json.load(sys.stdin); assert isinstance(data, list)" 2>/dev/null; then
    echo "  PASS: valid task ID produces JSON array"
    (( PASS++ ))
else
    echo "  FAIL: valid task ID did not produce JSON array" >&2
    (( FAIL++ ))
fi

# ── Test 4: Classification output contains required fields ───────────────────
echo "Test 4: Classification output contains required fields (id, subagent, model, class)"
output=$(bash "$SCRIPT" "lockpick-doc-to-logic-l12cy" 2>&1) || true
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

# ── Test 5: Model field is one of valid values ───────────────────────────────
echo "Test 5: Model field is one of: haiku, sonnet, opus"
output=$(bash "$SCRIPT" "lockpick-doc-to-logic-l12cy" 2>&1) || true
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

# ── Test 6: --test mode exits 0 ──────────────────────────────────────────────
echo "Test 6: --test mode exits 0"
exit_code=0
bash "$SCRIPT" --test 2>&1 || exit_code=$?
if [ "$exit_code" -eq 0 ]; then
    echo "  PASS: --test mode exits 0"
    (( PASS++ ))
else
    echo "  FAIL: --test mode exited $exit_code" >&2
    (( FAIL++ ))
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
{
    # Feed a bug-type task with "investigate" keywords to classify-task.py
    # and verify it does NOT get assigned to code-explorer
    PYTHON="$(cd "$REPO_ROOT/app" && poetry env info -e 2>/dev/null || echo "python3")"
    SCORER="$REPO_ROOT/lockpick-workflow/scripts/classify-task.py"

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

# ── Test: Non-bug investigate tasks still route to code-explorer ─────────────
echo "Test: Non-bug investigate tasks still route to code-explorer"
{
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

echo ""
echo "=== TDD RED Phase: bd→tk migration tests ==="

# Helper: create a controlled TICKETS_DIR with a fake bd stub that records calls
# and a fake tk stub that also records calls. Used to assert which CLI is invoked.
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

# ── RED Test 8: classify-task.sh --from-epic calls tk ready, not bd ready ─────
echo "Test 8 (RED): --from-epic uses tk ready (MUST FAIL until migration)"
{
    _tmpdir="$(_setup_migration_test_env)"
    _CLEANUP_DIRS+=("$_tmpdir")
    _log="$_tmpdir/stub.log"
    touch "$_log"
    export STUB_LOG="$_log"

    # Run with fake bd/tk on PATH ahead of real tools; suppress scorer errors
    output=$(PATH="$_tmpdir:$PATH" bash "$SCRIPT" --from-epic "fake-epic-id" 2>/dev/null) || true

    # Assert: tk must have been invoked (currently fails because script calls bd)
    if grep -q "^tk " "$_log" 2>/dev/null; then
        echo "  PASS: classify_task_from_epic_calls_tk_ready — --from-epic invoked tk"
        (( PASS++ ))
    else
        echo "  FAIL: classify_task_from_epic_calls_tk_ready — tk was not called (script still calls bd)" >&2
        (( FAIL++ ))
    fi

    rm -rf "$_tmpdir"
}

# ── RED Test 9: single task ID uses tk show, not bd show ─────────────────────
echo "Test 9 (RED): single task ID uses tk show (MUST FAIL until migration)"
{
    _tmpdir="$(_setup_migration_test_env)"
    _CLEANUP_DIRS+=("$_tmpdir")
    _log="$_tmpdir/stub.log"
    touch "$_log"
    export STUB_LOG="$_log"

    # Provide a fixture ticket so tk show would have something to return;
    # but current script calls bd show — tk won't be invoked at all.
    output=$(PATH="$_tmpdir:$PATH" bash "$SCRIPT" "fake-task-id" 2>/dev/null) || true

    # Assert: tk must have been invoked with show (currently fails — script calls bd show)
    if grep -q "^tk show" "$_log" 2>/dev/null; then
        echo "  PASS: single task ID invoked tk show"
        (( PASS++ ))
    else
        echo "  FAIL: classify_task_single_id_uses_tk_show — tk show was not called (script still calls bd show)" >&2
        (( FAIL++ ))
    fi

    rm -rf "$_tmpdir"
}

echo ""
echo "Results (including RED phase): $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
