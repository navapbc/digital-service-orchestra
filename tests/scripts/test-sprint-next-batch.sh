#!/usr/bin/env bash
# tests/scripts/test-sprint-next-batch.sh
# Baseline tests for scripts/sprint-next-batch.sh
#
# Usage: bash tests/scripts/test-sprint-next-batch.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DSO_PLUGIN_DIR="$PLUGIN_ROOT/plugins/dso"
REPO_ROOT="$(cd "$SCRIPT_DIR" && git rev-parse --show-toplevel)"
SCRIPT="$DSO_PLUGIN_DIR/scripts/sprint-next-batch.sh"
PLUGIN_SCRIPT="$DSO_PLUGIN_DIR/scripts/sprint-next-batch.sh"

source "$(dirname "${BASH_SOURCE[0]}")/../lib/run_test.sh"

# Temp dir cleanup on exit
_CLEANUP_DIRS=()
_cleanup() { for d in "${_CLEANUP_DIRS[@]}"; do rm -rf "$d"; done; }
trap _cleanup EXIT

echo "=== test-sprint-next-batch.sh ==="

# ── Test 1: Script is executable ──────────────────────────────────────────────
echo "Test 1: Script is executable"
if [ -x "$SCRIPT" ]; then
    echo "  PASS: script is executable"
    (( PASS++ ))
else
    echo "  FAIL: script is not executable" >&2
    (( FAIL++ ))
fi

# ── Test 2: No args exits 2 (usage error) ─────────────────────────────────────
echo "Test 2: No args exits 2 with usage"
run_test "missing epic-id exits 2" 2 "[Uu]sage|epic" bash "$SCRIPT"

# ── Test 3: Plugin copy exits 0 with EPIC and BATCH_SIZE output for mock epic ─
echo "Test 3: Plugin copy exits 0 with expected output format (mock epic)"
_t3_mock_dir=$(mktemp -d)
_CLEANUP_DIRS+=("$_t3_mock_dir")
_t3_fake_repo=$(mktemp -d)
_CLEANUP_DIRS+=("$_t3_fake_repo")
git init -q -b main "$_t3_fake_repo"
mkdir -p "$_t3_fake_repo/.tickets" "$_t3_fake_repo/scripts" "$_t3_fake_repo/scripts"
printf -- "---\nid: t3-child\nstatus: open\ntype: task\npriority: 2\nparent: t3-epic\n---\n# Test task\n\nEdit \`src/agents/base.py\`\n" > "$_t3_fake_repo/.tickets/t3-child.md"

# Mock tk
cat > "$_t3_mock_dir/tk" << 'T3_TK'
#!/usr/bin/env bash
echo "$*" >> /dev/null
SUBCMD="${1:-}"; TICKET_ID="${2:-}"
case "$SUBCMD" in
    show)
        if [[ "$TICKET_ID" == "t3-epic" ]]; then
            printf -- "---\nid: t3-epic\nstatus: open\ntype: epic\npriority: 1\n---\n# Test Epic\n"
        else
            echo ""; exit 1
        fi; exit 0 ;;
    ready) echo "t3-child [P2][open] - Test task"; exit 0 ;;
    blocked) exit 0 ;;
    children) echo "t3-child"; exit 0 ;;
    *) exit 0 ;;
esac
T3_TK
chmod +x "$_t3_mock_dir/tk"

# Minimal classify-task.py stub
cat > "$_t3_fake_repo/scripts/classify-task.py" << 'T3_SCORER'
import json, sys
tasks = json.loads(sys.stdin.read())
out = [{"id": t.get("id",""), "priority": 2, "class": "independent",
        "subagent": "general-purpose", "model": "sonnet",
        "complexity": "low", "reason": "stub"} for t in tasks]
print(json.dumps(out))
T3_SCORER

# Minimal read-config.sh stub
cat > "$_t3_fake_repo/scripts/read-config.sh" << 'T3_CFG'
#!/usr/bin/env bash
KEY="${1:-}"; if [[ "$KEY" == "--list" ]]; then KEY="${2:-}"; fi
case "$KEY" in
    paths.src_dir) echo -n "src" ;;
    paths.test_dir) echo -n "tests" ;;
    paths.test_unit_dir) echo -n "tests/unit" ;;
    interpreter.python_venv) echo -n "" ;;
    *) echo -n "" ;;
esac
T3_CFG
chmod +x "$_t3_fake_repo/scripts/read-config.sh"
printf '' > "$_t3_fake_repo/dso-config.conf"
cp "$PLUGIN_SCRIPT" "$_t3_fake_repo/scripts/sprint-next-batch.sh"
chmod +x "$_t3_fake_repo/scripts/sprint-next-batch.sh"

exit_code=0
output=$(cd "$_t3_fake_repo" && TK="$_t3_mock_dir/tk" bash "$_t3_fake_repo/scripts/sprint-next-batch.sh" "t3-epic" 2>&1) || exit_code=$?
rm -rf "$_t3_mock_dir" "$_t3_fake_repo"
if [ "$exit_code" -eq 0 ] && echo "$output" | grep -qE "EPIC:|BATCH_SIZE:"; then
    echo "  PASS: plugin exits 0 with EPIC and BATCH_SIZE lines"
    (( PASS++ ))
else
    echo "  FAIL: plugin exited $exit_code or output missing EPIC:/BATCH_SIZE:" >&2
    (( FAIL++ ))
fi

# ── Test 4: Plugin copy --json flag produces valid JSON ───────────────────────
echo "Test 4: Plugin copy --json flag produces valid JSON (mock epic)"
_t4_mock_dir=$(mktemp -d)
_CLEANUP_DIRS+=("$_t4_mock_dir")
_t4_fake_repo=$(mktemp -d)
_CLEANUP_DIRS+=("$_t4_fake_repo")
git init -q -b main "$_t4_fake_repo"
mkdir -p "$_t4_fake_repo/.tickets" "$_t4_fake_repo/scripts"
printf -- "---\nid: t4-child\nstatus: open\ntype: task\npriority: 2\nparent: t4-epic\n---\n# Test task\n\nEdit \`src/agents/base.py\`\n" > "$_t4_fake_repo/.tickets/t4-child.md"
cat > "$_t4_mock_dir/tk" << 'T4_TK'
#!/usr/bin/env bash
SUBCMD="${1:-}"; TICKET_ID="${2:-}"
case "$SUBCMD" in
    show)
        if [[ "$TICKET_ID" == "t4-epic" ]]; then
            printf -- "---\nid: t4-epic\nstatus: open\ntype: epic\npriority: 1\n---\n# Test Epic\n"
        else
            echo ""; exit 1
        fi; exit 0 ;;
    ready) echo "t4-child [P2][open] - Test task"; exit 0 ;;
    blocked) exit 0 ;;
    children) echo "t4-child"; exit 0 ;;
    *) exit 0 ;;
esac
T4_TK
chmod +x "$_t4_mock_dir/tk"
cat > "$_t4_fake_repo/scripts/classify-task.py" << 'T4_SCORER'
import json, sys
tasks = json.loads(sys.stdin.read())
out = [{"id": t.get("id",""), "priority": 2, "class": "independent",
        "subagent": "general-purpose", "model": "sonnet",
        "complexity": "low", "reason": "stub"} for t in tasks]
print(json.dumps(out))
T4_SCORER
cat > "$_t4_fake_repo/scripts/read-config.sh" << 'T4_CFG'
#!/usr/bin/env bash
KEY="${1:-}"; if [[ "$KEY" == "--list" ]]; then KEY="${2:-}"; fi
case "$KEY" in
    paths.src_dir) echo -n "src" ;;
    paths.test_dir) echo -n "tests" ;;
    paths.test_unit_dir) echo -n "tests/unit" ;;
    *) echo -n "" ;;
esac
T4_CFG
chmod +x "$_t4_fake_repo/scripts/read-config.sh"
printf '' > "$_t4_fake_repo/dso-config.conf"
cp "$PLUGIN_SCRIPT" "$_t4_fake_repo/scripts/sprint-next-batch.sh"
chmod +x "$_t4_fake_repo/scripts/sprint-next-batch.sh"

json_exit=0
json_output=$(cd "$_t4_fake_repo" && TK="$_t4_mock_dir/tk" bash "$_t4_fake_repo/scripts/sprint-next-batch.sh" "t4-epic" --json 2>&1) || json_exit=$?
rm -rf "$_t4_mock_dir" "$_t4_fake_repo"
if echo "$json_output" | python3 -c "import sys,json; data=json.load(sys.stdin)" 2>/dev/null; then
    echo "  PASS: --json produces valid JSON"
    (( PASS++ ))
else
    echo "  FAIL: --json did not produce valid JSON (exit=$json_exit)" >&2
    (( FAIL++ ))
fi

# ── Test 5: Plugin copy --limit=N flag is accepted ────────────────────────────
echo "Test 5: Plugin copy --limit=N flag is accepted (mock epic)"
_t5_mock_dir=$(mktemp -d)
_CLEANUP_DIRS+=("$_t5_mock_dir")
_t5_fake_repo=$(mktemp -d)
_CLEANUP_DIRS+=("$_t5_fake_repo")
git init -q -b main "$_t5_fake_repo"
mkdir -p "$_t5_fake_repo/.tickets" "$_t5_fake_repo/scripts"
printf -- "---\nid: t5-child\nstatus: open\ntype: task\npriority: 2\nparent: t5-epic\n---\n# Test task\n\nEdit \`src/agents/base.py\`\n" > "$_t5_fake_repo/.tickets/t5-child.md"
cat > "$_t5_mock_dir/tk" << 'T5_TK'
#!/usr/bin/env bash
SUBCMD="${1:-}"; TICKET_ID="${2:-}"
case "$SUBCMD" in
    show)
        if [[ "$TICKET_ID" == "t5-epic" ]]; then
            printf -- "---\nid: t5-epic\nstatus: open\ntype: epic\npriority: 1\n---\n# Test Epic\n"
        else
            echo ""; exit 1
        fi; exit 0 ;;
    ready) echo "t5-child [P2][open] - Test task"; exit 0 ;;
    blocked) exit 0 ;;
    children) echo "t5-child"; exit 0 ;;
    *) exit 0 ;;
esac
T5_TK
chmod +x "$_t5_mock_dir/tk"
cat > "$_t5_fake_repo/scripts/classify-task.py" << 'T5_SCORER'
import json, sys
tasks = json.loads(sys.stdin.read())
out = [{"id": t.get("id",""), "priority": 2, "class": "independent",
        "subagent": "general-purpose", "model": "sonnet",
        "complexity": "low", "reason": "stub"} for t in tasks]
print(json.dumps(out))
T5_SCORER
cat > "$_t5_fake_repo/scripts/read-config.sh" << 'T5_CFG'
#!/usr/bin/env bash
KEY="${1:-}"; if [[ "$KEY" == "--list" ]]; then KEY="${2:-}"; fi
case "$KEY" in
    paths.src_dir) echo -n "src" ;;
    paths.test_dir) echo -n "tests" ;;
    paths.test_unit_dir) echo -n "tests/unit" ;;
    *) echo -n "" ;;
esac
T5_CFG
chmod +x "$_t5_fake_repo/scripts/read-config.sh"
printf '' > "$_t5_fake_repo/dso-config.conf"
cp "$PLUGIN_SCRIPT" "$_t5_fake_repo/scripts/sprint-next-batch.sh"
chmod +x "$_t5_fake_repo/scripts/sprint-next-batch.sh"

limit_exit=0
cd "$_t5_fake_repo" && TK="$_t5_mock_dir/tk" bash "$_t5_fake_repo/scripts/sprint-next-batch.sh" "t5-epic" --limit=3 >/dev/null 2>&1 || limit_exit=$?
cd "$REPO_ROOT"
rm -rf "$_t5_mock_dir" "$_t5_fake_repo"
if [ "$limit_exit" -eq 0 ]; then
    echo "  PASS: --limit=3 exits 0"
    (( PASS++ ))
else
    echo "  FAIL: --limit=3 exited $limit_exit" >&2
    (( FAIL++ ))
fi

# ── Test 6: No bash syntax errors ─────────────────────────────────────────────
echo "Test 6: No bash syntax errors"
if bash -n "$SCRIPT" 2>/dev/null; then
    echo "  PASS: no syntax errors"
    (( PASS++ ))
else
    echo "  FAIL: syntax errors found" >&2
    (( FAIL++ ))
fi

# ── Test 7: Nonexistent epic ID exits 1 ─────────────────────────────────────
echo "Test 7: Nonexistent epic ID exits 1"
exit_code=0
bash "$SCRIPT" "nonexistent-epic-zzz99999" 2>&1 || exit_code=$?
if [ "$exit_code" -eq 1 ]; then
    echo "  PASS: nonexistent epic exits 1"
    (( PASS++ ))
else
    echo "  FAIL: nonexistent epic exited $exit_code (expected 1)" >&2
    (( FAIL++ ))
fi

# ── Test 8: Plugin copy documents TASK: output format ────────────────────────
echo "Test 8: Plugin copy documents TASK: output format"
if grep -q "TASK:" "$PLUGIN_SCRIPT" && grep -q "BATCH_SIZE:" "$PLUGIN_SCRIPT"; then
    echo "  PASS: plugin copy documents TASK: and BATCH_SIZE: output format"
    (( PASS++ ))
else
    echo "  FAIL: plugin copy missing TASK: or BATCH_SIZE: output format docs" >&2
    (( FAIL++ ))
fi

# ── Test 10: Plugin copy exists and is executable ────────────────────────────
echo "Test 10: Plugin copy exists and is executable"
if [ -x "$PLUGIN_SCRIPT" ]; then
    echo "  PASS: plugin copy is executable"
    (( PASS++ ))
else
    echo "  FAIL: plugin copy missing or not executable at $PLUGIN_SCRIPT" >&2
    (( FAIL++ ))
fi

# ── Test 11: Plugin copy contains no poetry env info ─────────────────────────
echo "Test 11: Plugin copy contains no poetry env info"
if ! grep -qE "poetry env info" "$PLUGIN_SCRIPT" 2>/dev/null; then
    echo "  PASS: no poetry env info in plugin copy"
    (( PASS++ ))
else
    echo "  FAIL: plugin copy still contains 'poetry env info'" >&2
    (( FAIL++ ))
fi

# ── Test 12: Plugin copy resolves TK via REPO_ROOT (not SCRIPT_DIR/tk) ───────
echo "Test 12: Plugin TK path resolves via REPO_ROOT"
if grep -qE 'REPO_ROOT.*scripts/tk|TK=' "$PLUGIN_SCRIPT" 2>/dev/null; then
    echo "  PASS: TK resolves via REPO_ROOT"
    (( PASS++ ))
else
    echo "  FAIL: TK does not resolve via REPO_ROOT in plugin copy" >&2
    (( FAIL++ ))
fi

# ── Test 13: AC Verify lines do not cause false-positive batch conflicts ───────
echo "Test 13: AC Verify lines do not cause false-positive batch conflicts"
_t13_mock_dir=$(mktemp -d)
_CLEANUP_DIRS+=("$_t13_mock_dir")
_t13_fake_repo=$(mktemp -d)
_CLEANUP_DIRS+=("$_t13_fake_repo")
git init -q -b main "$_t13_fake_repo"
mkdir -p "$_t13_fake_repo/.tickets" "$_t13_fake_repo/scripts"

# Create two tasks with AC Verify lines referencing the same script
# They should NOT be flagged as conflicting because AC Verify lines are
# shell commands (acceptance criteria), not files the tasks will modify.
printf -- "---\nid: t13-task-a\nstatus: open\ntype: task\npriority: 2\nparent: t13-epic\n---\n# Task A\n\nEdit src/foo.py\n\nAC Verify: bash scripts/validate.sh --ci\n" \
    > "$_t13_fake_repo/.tickets/t13-task-a.md"
printf -- "---\nid: t13-task-b\nstatus: open\ntype: task\npriority: 2\nparent: t13-epic\n---\n# Task B\n\nEdit src/bar.py\n\nAC Verify: bash scripts/validate.sh --ci\n" \
    > "$_t13_fake_repo/.tickets/t13-task-b.md"

cat > "$_t13_mock_dir/tk" << 'T13_TK'
#!/usr/bin/env bash
SUBCMD="${1:-}"; TICKET_ID="${2:-}"
case "$SUBCMD" in
    show)
        if [[ "$TICKET_ID" == "t13-epic" ]]; then
            printf -- "---\nid: t13-epic\nstatus: open\ntype: epic\npriority: 1\n---\n# Test Epic\n"
        else
            echo ""; exit 1
        fi; exit 0 ;;
    ready)
        echo "t13-task-a [P2][open] - Task A"
        echo "t13-task-b [P2][open] - Task B"
        exit 0 ;;
    blocked) exit 0 ;;
    children) echo "t13-task-a"; echo "t13-task-b"; exit 0 ;;
    *) exit 0 ;;
esac
T13_TK
chmod +x "$_t13_mock_dir/tk"

cat > "$_t13_fake_repo/scripts/classify-task.py" << 'T13_SCORER'
import json, sys
tasks = json.loads(sys.stdin.read())
out = [{"id": t.get("id",""), "priority": 2, "class": "independent",
        "subagent": "general-purpose", "model": "sonnet",
        "complexity": "low", "reason": "stub"} for t in tasks]
print(json.dumps(out))
T13_SCORER

cat > "$_t13_fake_repo/scripts/read-config.sh" << 'T13_CFG'
#!/usr/bin/env bash
KEY="${1:-}"; if [[ "$KEY" == "--list" ]]; then KEY="${2:-}"; fi
case "$KEY" in
    paths.src_dir) echo -n "src" ;;
    paths.test_dir) echo -n "tests" ;;
    paths.test_unit_dir) echo -n "tests/unit" ;;
    interpreter.python_venv) echo -n "" ;;
    *) echo -n "" ;;
esac
T13_CFG
chmod +x "$_t13_fake_repo/scripts/read-config.sh"
printf '' > "$_t13_fake_repo/dso-config.conf"
cp "$PLUGIN_SCRIPT" "$_t13_fake_repo/scripts/sprint-next-batch.sh"
chmod +x "$_t13_fake_repo/scripts/sprint-next-batch.sh"

t13_exit=0
t13_output=$(cd "$_t13_fake_repo" && TK="$_t13_mock_dir/tk" bash "$_t13_fake_repo/scripts/sprint-next-batch.sh" "t13-epic" --json 2>/dev/null) || t13_exit=$?
rm -rf "$_t13_mock_dir" "$_t13_fake_repo"

# Both tasks should be in the batch (BATCH_SIZE: 2), not conflicting
t13_batch_size=$(echo "$t13_output" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('batch_size',0))" 2>/dev/null || echo "0")
t13_skipped=$(echo "$t13_output" | python3 -c "import sys,json; d=json.load(sys.stdin); print(len(d.get('skipped_overlap',[])))" 2>/dev/null || echo "1")
if [ "$t13_exit" -eq 0 ] && [ "$t13_batch_size" -eq 2 ] && [ "$t13_skipped" -eq 0 ]; then
    echo "  PASS: AC Verify lines do not cause false-positive conflicts (batch_size=2, skipped_overlap=0)"
    (( PASS++ ))
else
    echo "  FAIL: AC Verify lines caused false-positive conflicts (exit=$t13_exit batch_size=$t13_batch_size skipped_overlap=$t13_skipped)" >&2
    (( FAIL++ ))
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
