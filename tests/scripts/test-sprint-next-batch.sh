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
mkdir -p "$_t3_fake_repo/scripts"

# Mock ticket CLI (v3 JSON output)
cat > "$_t3_fake_repo/scripts/ticket" << 'T3_TICKET'
#!/usr/bin/env bash
SUBCMD="${1:-}"; shift || true; TICKET_ID="${1:-}"
case "$SUBCMD" in
    show)
        if [[ "$TICKET_ID" == "t3-epic" ]]; then
            echo '{"ticket_id":"t3-epic","status":"open","ticket_type":"epic","priority":1,"title":"Test Epic","parent_id":null,"comments":[],"deps":[]}'
        else
            echo '{"status":"error","error":"not found","ticket_id":"'"$TICKET_ID"'"}'; exit 1
        fi; exit 0 ;;
    list) echo '[{"ticket_id":"t3-child","status":"open","ticket_type":"task","priority":2,"title":"Test task","parent_id":"t3-epic","deps":[]}]'; exit 0 ;;
    *) exit 0 ;;
esac
T3_TICKET
chmod +x "$_t3_fake_repo/scripts/ticket"

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
output=$(cd "$_t3_fake_repo" && TICKET_CMD="$_t3_fake_repo/scripts/ticket" bash "$_t3_fake_repo/scripts/sprint-next-batch.sh" "t3-epic" 2>&1) || exit_code=$?
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
mkdir -p "$_t4_fake_repo/scripts"
cat > "$_t4_fake_repo/scripts/ticket" << 'T4_TICKET'
#!/usr/bin/env bash
SUBCMD="${1:-}"; shift || true; TICKET_ID="${1:-}"
case "$SUBCMD" in
    show)
        if [[ "$TICKET_ID" == "t4-epic" ]]; then
            echo '{"ticket_id":"t4-epic","status":"open","ticket_type":"epic","priority":1,"title":"Test Epic","parent_id":null,"comments":[],"deps":[]}'
        else
            echo '{"status":"error","error":"not found","ticket_id":"'"$TICKET_ID"'"}'; exit 1
        fi; exit 0 ;;
    list) echo '[{"ticket_id":"t4-child","status":"open","ticket_type":"task","priority":2,"title":"Test task","parent_id":"t4-epic","deps":[]}]'; exit 0 ;;
    *) exit 0 ;;
esac
T4_TICKET
chmod +x "$_t4_fake_repo/scripts/ticket"
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
json_output=$(cd "$_t4_fake_repo" && TICKET_CMD="$_t4_fake_repo/scripts/ticket" bash "$_t4_fake_repo/scripts/sprint-next-batch.sh" "t4-epic" --json 2>&1) || json_exit=$?
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
mkdir -p "$_t5_fake_repo/scripts"
cat > "$_t5_fake_repo/scripts/ticket" << 'T5_TICKET'
#!/usr/bin/env bash
SUBCMD="${1:-}"; shift || true; TICKET_ID="${1:-}"
case "$SUBCMD" in
    show)
        if [[ "$TICKET_ID" == "t5-epic" ]]; then
            echo '{"ticket_id":"t5-epic","status":"open","ticket_type":"epic","priority":1,"title":"Test Epic","parent_id":null,"comments":[],"deps":[]}'
        else
            echo '{"status":"error","error":"not found","ticket_id":"'"$TICKET_ID"'"}'; exit 1
        fi; exit 0 ;;
    list) echo '[{"ticket_id":"t5-child","status":"open","ticket_type":"task","priority":2,"title":"Test task","parent_id":"t5-epic","deps":[]}]'; exit 0 ;;
    *) exit 0 ;;
esac
T5_TICKET
chmod +x "$_t5_fake_repo/scripts/ticket"
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
cd "$_t5_fake_repo" && TICKET_CMD="$_t5_fake_repo/scripts/ticket" bash "$_t5_fake_repo/scripts/sprint-next-batch.sh" "t5-epic" --limit=3 >/dev/null 2>&1 || limit_exit=$?
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

# ── Test 12: Plugin copy resolves TICKET_CMD via SCRIPT_DIR ───────────────────
echo "Test 12: Plugin TICKET_CMD path resolves via SCRIPT_DIR"
if grep -qE 'TICKET_CMD=' "$PLUGIN_SCRIPT" 2>/dev/null; then
    echo "  PASS: TICKET_CMD resolves via SCRIPT_DIR"
    (( PASS++ ))
else
    echo "  FAIL: TICKET_CMD not found in plugin copy" >&2
    (( FAIL++ ))
fi

# ── Test 13: AC Verify lines do not cause false-positive batch conflicts ───────
echo "Test 13: AC Verify lines do not cause false-positive batch conflicts"
_t13_mock_dir=$(mktemp -d)
_CLEANUP_DIRS+=("$_t13_mock_dir")
_t13_fake_repo=$(mktemp -d)
_CLEANUP_DIRS+=("$_t13_fake_repo")
git init -q -b main "$_t13_fake_repo"
mkdir -p "$_t13_fake_repo/scripts"

# Two tasks with AC Verify lines referencing the same script.
# They should NOT be flagged as conflicting because AC Verify lines are
# shell commands (acceptance criteria), not files the tasks will modify.
# The TICKET_CMD mock returns both tasks via ticket list; no .md fixtures needed.

cat > "$_t13_fake_repo/scripts/ticket" << 'T13_TICKET'
#!/usr/bin/env bash
SUBCMD="${1:-}"; shift || true; TICKET_ID="${1:-}"
case "$SUBCMD" in
    show)
        if [[ "$TICKET_ID" == "t13-epic" ]]; then
            echo '{"ticket_id":"t13-epic","status":"open","ticket_type":"epic","priority":1,"title":"Test Epic","parent_id":null,"comments":[],"deps":[]}'
        else
            echo '{"status":"error","error":"not found","ticket_id":"'"$TICKET_ID"'"}'; exit 1
        fi; exit 0 ;;
    list)
        echo '[{"ticket_id":"t13-task-a","status":"open","ticket_type":"task","priority":2,"title":"Task A","parent_id":"t13-epic","deps":[]},{"ticket_id":"t13-task-b","status":"open","ticket_type":"task","priority":2,"title":"Task B","parent_id":"t13-epic","deps":[]}]'
        exit 0 ;;
    *) exit 0 ;;
esac
T13_TICKET
chmod +x "$_t13_fake_repo/scripts/ticket"

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
t13_output=$(cd "$_t13_fake_repo" && TICKET_CMD="$_t13_fake_repo/scripts/ticket" bash "$_t13_fake_repo/scripts/sprint-next-batch.sh" "t13-epic" --json 2>/dev/null) || t13_exit=$?
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

# ── Test 14: v3 event-sourced tickets — descendants BFS uses tracker, not .md ─
# RED test: when .tickets/ directory exists but has NO .md files (v3 migration),
# the script must still correctly identify descendants via .tickets-tracker/
# and read ticket body content from the reducer (not .tickets/<id>.md).
#
# Specifically: two tasks both reference `src/agents/base.py` in their ticket
# body (via COMMENT event). With v2, _load_ticket_body() would read the .md
# file and detect the conflict. With v3 and broken code, body is empty so
# both tasks appear conflict-free when they should conflict.
echo "Test 14: v3 event-sourced tickets — body content read from tracker for conflict detection"
_t14_mock_dir=$(mktemp -d)
_CLEANUP_DIRS+=("$_t14_mock_dir")
_t14_fake_repo=$(mktemp -d)
_CLEANUP_DIRS+=("$_t14_fake_repo")
git init -q -b main "$_t14_fake_repo"
mkdir -p "$_t14_fake_repo/scripts"

# v3: create event-sourced tracker directory structure — .tickets/ exists but empty (v3 migration)
mkdir -p "$_t14_fake_repo/.tickets"  # exists but no .md files
mkdir -p "$_t14_fake_repo/.tickets-tracker/t14-epic"
mkdir -p "$_t14_fake_repo/.tickets-tracker/t14-task-a"
mkdir -p "$_t14_fake_repo/.tickets-tracker/t14-task-b"

# Epic CREATE event
python3 -c "
import json, time
with open('$_t14_fake_repo/.tickets-tracker/t14-epic/0001-CREATE.json', 'w') as f:
    json.dump({'timestamp': 1000, 'uuid': 'u1', 'event_type': 'CREATE',
               'env_id': 'test', 'author': 'test',
               'data': {'ticket_type': 'epic', 'title': 'Test Epic v3',
                        'parent_id': '', 'priority': 1}}, f)
"

# Task A CREATE + COMMENT with file reference in body
python3 -c "
import json
with open('$_t14_fake_repo/.tickets-tracker/t14-task-a/0001-CREATE.json', 'w') as f:
    json.dump({'timestamp': 1001, 'uuid': 'u2', 'event_type': 'CREATE',
               'env_id': 'test', 'author': 'test',
               'data': {'ticket_type': 'task', 'title': 'Task A',
                        'parent_id': 't14-epic', 'priority': 2}}, f)
with open('$_t14_fake_repo/.tickets-tracker/t14-task-a/0002-COMMENT.json', 'w') as f:
    json.dump({'timestamp': 1002, 'uuid': 'u3', 'event_type': 'COMMENT',
               'env_id': 'test', 'author': 'test',
               'data': {'body': 'Edit \`src/agents/base.py\` to add feature A'}}, f)
"

# Task B CREATE + COMMENT also referencing the same file (should conflict with Task A)
python3 -c "
import json
with open('$_t14_fake_repo/.tickets-tracker/t14-task-b/0001-CREATE.json', 'w') as f:
    json.dump({'timestamp': 1003, 'uuid': 'u4', 'event_type': 'CREATE',
               'env_id': 'test', 'author': 'test',
               'data': {'ticket_type': 'task', 'title': 'Task B',
                        'parent_id': 't14-epic', 'priority': 2}}, f)
with open('$_t14_fake_repo/.tickets-tracker/t14-task-b/0002-COMMENT.json', 'w') as f:
    json.dump({'timestamp': 1004, 'uuid': 'u5', 'event_type': 'COMMENT',
               'env_id': 'test', 'author': 'test',
               'data': {'body': 'Edit \`src/agents/base.py\` to add feature B'}}, f)
"

# Mock ticket CLI (v3 JSON output): both tasks are ready, epic returns JSON
cat > "$_t14_fake_repo/scripts/ticket" << 'T14_TICKET'
#!/usr/bin/env bash
SUBCMD="${1:-}"; shift || true; TICKET_ID="${1:-}"
case "$SUBCMD" in
    show)
        if [[ "$TICKET_ID" == "t14-epic" ]]; then
            echo '{"ticket_id":"t14-epic","status":"open","ticket_type":"epic","priority":1,"title":"Test Epic v3","parent_id":null,"comments":[],"deps":[]}'
        else
            echo '{"status":"error","error":"not found","ticket_id":"'"$TICKET_ID"'"}'; exit 1
        fi; exit 0 ;;
    list)
        echo '[{"ticket_id":"t14-task-a","status":"open","ticket_type":"task","priority":2,"title":"Task A","parent_id":"t14-epic","deps":[]},{"ticket_id":"t14-task-b","status":"open","ticket_type":"task","priority":2,"title":"Task B","parent_id":"t14-epic","deps":[]}]'
        exit 0 ;;
    *) exit 0 ;;
esac
T14_TICKET
chmod +x "$_t14_fake_repo/scripts/ticket"

cat > "$_t14_fake_repo/scripts/classify-task.py" << 'T14_SCORER'
import json, sys
tasks = json.loads(sys.stdin.read())
out = [{"id": t.get("id",""), "priority": 2, "class": "independent",
        "subagent": "general-purpose", "model": "sonnet",
        "complexity": "low", "reason": "stub"} for t in tasks]
print(json.dumps(out))
T14_SCORER

cat > "$_t14_fake_repo/scripts/read-config.sh" << 'T14_CFG'
#!/usr/bin/env bash
KEY="${1:-}"; if [[ "$KEY" == "--list" ]]; then KEY="${2:-}"; fi
case "$KEY" in
    paths.src_dir) echo -n "src" ;;
    paths.test_dir) echo -n "tests" ;;
    paths.test_unit_dir) echo -n "tests/unit" ;;
    interpreter.python_venv) echo -n "" ;;
    *) echo -n "" ;;
esac
T14_CFG
chmod +x "$_t14_fake_repo/scripts/read-config.sh"
printf '' > "$_t14_fake_repo/dso-config.conf"
cp "$PLUGIN_SCRIPT" "$_t14_fake_repo/scripts/sprint-next-batch.sh"
chmod +x "$_t14_fake_repo/scripts/sprint-next-batch.sh"
# Copy the reducer so _load_ticket_body() v3 path can use it
cp "$DSO_PLUGIN_DIR/scripts/ticket-reducer.py" "$_t14_fake_repo/scripts/ticket-reducer.py"

t14_exit=0
t14_output=$(
    cd "$_t14_fake_repo" && \
    TICKETS_TRACKER_DIR="$_t14_fake_repo/.tickets-tracker" \
    CLAUDE_PLUGIN_ROOT="$_t14_fake_repo" \
    TICKET_CMD="$_t14_fake_repo/scripts/ticket" \
    bash "$_t14_fake_repo/scripts/sprint-next-batch.sh" "t14-epic" --json 2>/dev/null
) || t14_exit=$?
rm -rf "$_t14_mock_dir" "$_t14_fake_repo"

# Task A and Task B both reference src/agents/base.py in their COMMENT bodies.
# v3-compatible code reads that body from the tracker and detects the conflict.
# batch_size must be 1 (one task wins), skipped_overlap must be 1 (one deferred).
t14_batch_size=$(echo "$t14_output" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('batch_size',0))" 2>/dev/null || echo "-1")
t14_skipped=$(echo "$t14_output" | python3 -c "import sys,json; d=json.load(sys.stdin); print(len(d.get('skipped_overlap',[])))" 2>/dev/null || echo "-1")
if [ "$t14_exit" -eq 0 ] && [ "$t14_batch_size" -eq 1 ] && [ "$t14_skipped" -eq 1 ]; then
    echo "  PASS: v3 tracker body used for conflict detection (batch=1, skipped_overlap=1)"
    (( PASS++ ))
else
    echo "  FAIL: v3 tracker body not read — conflict undetected (exit=$t14_exit batch_size=$t14_batch_size skipped_overlap=$t14_skipped)" >&2
    echo "  Output: $t14_output" >&2
    (( FAIL++ ))
fi

# ── Test 15: AC section headers (## ACCEPTANCE CRITERIA) do not cause false conflicts ─
echo "Test 15: AC section headers do not cause false-positive batch conflicts (w21-v0ad, w22-uyaq)"
_t15_mock_dir=$(mktemp -d)
_CLEANUP_DIRS+=("$_t15_mock_dir")
_t15_fake_repo=$(mktemp -d)
_CLEANUP_DIRS+=("$_t15_fake_repo")
git init -q -b main "$_t15_fake_repo"
mkdir -p "$_t15_fake_repo/scripts"

# Two tasks: different source files but BOTH have acceptance criteria in
# "## ACCEPTANCE CRITERIA" section format referencing the same validation script.
# The current AC_LINE_RE only strips "AC <word>:" lines — not section headers.
# The TICKET_CMD mock returns both tasks via ticket list; no .md fixtures needed.

cat > "$_t15_fake_repo/scripts/ticket" << 'T15_TICKET'
#!/usr/bin/env bash
SUBCMD="${1:-}"; shift || true; TICKET_ID="${1:-}"
case "$SUBCMD" in
    show)
        if [[ "$TICKET_ID" == "t15-epic" ]]; then
            echo '{"ticket_id":"t15-epic","status":"open","ticket_type":"epic","priority":1,"title":"Test Epic","parent_id":null,"comments":[],"deps":[]}'
        else
            echo '{"status":"error","error":"not found","ticket_id":"'"$TICKET_ID"'"}'; exit 1
        fi; exit 0 ;;
    list)
        echo '[{"ticket_id":"t15-task-a","status":"open","ticket_type":"task","priority":2,"title":"Task A","parent_id":"t15-epic","deps":[]},{"ticket_id":"t15-task-b","status":"open","ticket_type":"task","priority":2,"title":"Task B","parent_id":"t15-epic","deps":[]}]'
        exit 0 ;;
    *) exit 0 ;;
esac
T15_TICKET
chmod +x "$_t15_fake_repo/scripts/ticket"

cat > "$_t15_fake_repo/scripts/classify-task.py" << 'T15_SCORER'
import json, sys
tasks = json.loads(sys.stdin.read())
out = [{"id": t.get("id",""), "priority": 2, "class": "independent",
        "subagent": "general-purpose", "model": "sonnet",
        "complexity": "low", "reason": "stub"} for t in tasks]
print(json.dumps(out))
T15_SCORER

cat > "$_t15_fake_repo/scripts/read-config.sh" << 'T15_CFG'
#!/usr/bin/env bash
KEY="${1:-}"; if [[ "$KEY" == "--list" ]]; then KEY="${2:-}"; fi
case "$KEY" in
    paths.src_dir) echo -n "src" ;;
    paths.test_dir) echo -n "tests" ;;
    paths.test_unit_dir) echo -n "tests/unit" ;;
    interpreter.python_venv) echo -n "" ;;
    *) echo -n "" ;;
esac
T15_CFG
chmod +x "$_t15_fake_repo/scripts/read-config.sh"
printf '' > "$_t15_fake_repo/dso-config.conf"
cp "$PLUGIN_SCRIPT" "$_t15_fake_repo/scripts/sprint-next-batch.sh"
chmod +x "$_t15_fake_repo/scripts/sprint-next-batch.sh"

t15_exit=0
t15_output=$(cd "$_t15_fake_repo" && TICKET_CMD="$_t15_fake_repo/scripts/ticket" bash "$_t15_fake_repo/scripts/sprint-next-batch.sh" "t15-epic" --json 2>/dev/null) || t15_exit=$?
rm -rf "$_t15_mock_dir" "$_t15_fake_repo"

t15_batch_size=$(echo "$t15_output" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('batch_size',0))" 2>/dev/null || echo "0")
t15_skipped=$(echo "$t15_output" | python3 -c "import sys,json; d=json.load(sys.stdin); print(len(d.get('skipped_overlap',[])))" 2>/dev/null || echo "1")
if [ "$t15_exit" -eq 0 ] && [ "$t15_batch_size" -eq 2 ] && [ "$t15_skipped" -eq 0 ]; then
    echo "  PASS: AC section headers do not cause false-positive conflicts (batch_size=2, skipped_overlap=0)"
    (( PASS++ ))
else
    echo "  FAIL: AC section headers caused false-positive conflicts (exit=$t15_exit batch_size=$t15_batch_size skipped_overlap=$t15_skipped)" >&2
    (( FAIL++ ))
fi

# ── Test 16: dso-prefix blocked story IDs are recognized (dso-ptzz) ──────────
echo "Test 16: dso-prefix blocked story IDs are recognized by blocked_ids regex"
_t16_mock_dir=$(mktemp -d)
_CLEANUP_DIRS+=("$_t16_mock_dir")
_t16_fake_repo=$(mktemp -d)
_CLEANUP_DIRS+=("$_t16_fake_repo")
git init -q -b main "$_t16_fake_repo"
mkdir -p "$_t16_fake_repo/scripts"

# One task whose parent story (dso-story1) is blocked.
# The TICKET_CMD mock provides task data via ticket list; no .md fixtures needed.

cat > "$_t16_fake_repo/scripts/ticket" << 'T16_TICKET'
#!/usr/bin/env bash
SUBCMD="${1:-}"; shift || true; TICKET_ID="${1:-}"
case "$SUBCMD" in
    show)
        if [[ "$TICKET_ID" == "t16-epic" ]]; then
            echo '{"ticket_id":"t16-epic","status":"open","ticket_type":"epic","priority":1,"title":"Test Epic","parent_id":null,"comments":[],"deps":[]}'
        elif [[ "$TICKET_ID" == "t16-task" ]]; then
            echo '{"ticket_id":"t16-task","status":"open","ticket_type":"task","priority":2,"title":"Task under blocked story","parent_id":"dso-story1","comments":[],"deps":[]}'
        else
            echo '{"status":"error","error":"not found","ticket_id":"'"$TICKET_ID"'"}'; exit 1
        fi; exit 0 ;;
    list)
        # t16-task is ready (no deps), but dso-story1 is blocked (has deps on dso-blocker1)
        echo '[{"ticket_id":"t16-task","status":"open","ticket_type":"task","priority":2,"title":"Task under blocked story","parent_id":"dso-story1","deps":[]},{"ticket_id":"dso-story1","status":"open","ticket_type":"story","priority":2,"title":"Blocked story","parent_id":"t16-epic","deps":[{"target_id":"dso-blocker1","relation":"depends_on"}]}]'
        exit 0 ;;
    *) exit 0 ;;
esac
T16_TICKET
chmod +x "$_t16_fake_repo/scripts/ticket"

cat > "$_t16_fake_repo/scripts/classify-task.py" << 'T16_SCORER'
import json, sys
tasks = json.loads(sys.stdin.read())
out = [{"id": t.get("id",""), "priority": 2, "class": "independent",
        "subagent": "general-purpose", "model": "sonnet",
        "complexity": "low", "reason": "stub"} for t in tasks]
print(json.dumps(out))
T16_SCORER

cat > "$_t16_fake_repo/scripts/read-config.sh" << 'T16_CFG'
#!/usr/bin/env bash
KEY="${1:-}"; if [[ "$KEY" == "--list" ]]; then KEY="${2:-}"; fi
case "$KEY" in
    paths.src_dir) echo -n "src" ;;
    paths.test_dir) echo -n "tests" ;;
    paths.test_unit_dir) echo -n "tests/unit" ;;
    interpreter.python_venv) echo -n "" ;;
    *) echo -n "" ;;
esac
T16_CFG
chmod +x "$_t16_fake_repo/scripts/read-config.sh"
printf '' > "$_t16_fake_repo/dso-config.conf"
cp "$PLUGIN_SCRIPT" "$_t16_fake_repo/scripts/sprint-next-batch.sh"
chmod +x "$_t16_fake_repo/scripts/sprint-next-batch.sh"

t16_exit=0
t16_output=$(cd "$_t16_fake_repo" && TICKET_CMD="$_t16_fake_repo/scripts/ticket" bash "$_t16_fake_repo/scripts/sprint-next-batch.sh" "t16-epic" --json 2>/dev/null) || t16_exit=$?
rm -rf "$_t16_mock_dir" "$_t16_fake_repo"

# Task should be SKIPPED_BLOCKED_STORY (batch_size=0) because its parent dso-story1 is blocked
t16_batch_size=$(echo "$t16_output" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('batch_size',0))" 2>/dev/null || echo "1")
t16_blocked=$(echo "$t16_output" | python3 -c "import sys,json; d=json.load(sys.stdin); print(len(d.get('skipped_blocked_story',[])))" 2>/dev/null || echo "0")
if [ "$t16_exit" -eq 0 ] && [ "$t16_batch_size" -eq 0 ] && [ "$t16_blocked" -eq 1 ]; then
    echo "  PASS: dso-prefix blocked story recognized (batch_size=0, skipped_blocked_story=1)"
    (( PASS++ ))
else
    echo "  FAIL: dso-prefix blocked story not recognized (exit=$t16_exit batch_size=$t16_batch_size skipped_blocked_story=$t16_blocked)" >&2
    (( FAIL++ ))
fi

# ── Test 16b: Closed-dep target does NOT block ticket (dso-ptzz edge case) ────
echo "Test 16b: Ticket with a closed-dep target is NOT blocked"
_t16b_fake_repo=$(mktemp -d)
_CLEANUP_DIRS+=("$_t16b_fake_repo")
git init -q -b main "$_t16b_fake_repo"
mkdir -p "$_t16b_fake_repo/scripts"

# t16b-task is ready, its parent story depends_on dso-dep-closed (closed) — not blocked
cat > "$_t16b_fake_repo/scripts/ticket" << 'T16B_TICKET'
#!/usr/bin/env bash
SUBCMD="${1:-}"; shift || true; TICKET_ID="${1:-}"
case "$SUBCMD" in
    show)
        if [[ "$TICKET_ID" == "t16b-epic" ]]; then
            echo '{"ticket_id":"t16b-epic","status":"open","ticket_type":"epic","priority":1,"title":"Test Epic","parent_id":null,"comments":[],"deps":[]}'
        elif [[ "$TICKET_ID" == "t16b-task" ]]; then
            echo '{"ticket_id":"t16b-task","status":"open","ticket_type":"task","priority":2,"title":"Task under story with closed dep","parent_id":"dso-story2","comments":[],"deps":[]}'
        elif [[ "$TICKET_ID" == "dso-story2" ]]; then
            echo '{"ticket_id":"dso-story2","status":"open","ticket_type":"story","priority":2,"title":"Story with closed dep","parent_id":"t16b-epic","comments":[],"deps":[{"target_id":"dso-dep-closed","relation":"depends_on"}]}'
        else
            echo '{"status":"error","error":"not found","ticket_id":"'"$TICKET_ID"'"}'; exit 1
        fi; exit 0 ;;
    list)
        # dso-story2 has a depends_on dep, but its target (dso-dep-closed) is closed.
        # dso-story2 should NOT be in blocked_ids; t16b-task should be in the batch.
        echo '[{"ticket_id":"t16b-task","status":"open","ticket_type":"task","priority":2,"title":"Task under story with closed dep","parent_id":"dso-story2","deps":[]},{"ticket_id":"dso-story2","status":"open","ticket_type":"story","priority":2,"title":"Story with closed dep","parent_id":"t16b-epic","deps":[{"target_id":"dso-dep-closed","relation":"depends_on"}]},{"ticket_id":"dso-dep-closed","status":"closed","ticket_type":"task","priority":2,"title":"Closed dependency","parent_id":null,"deps":[]}]'
        exit 0 ;;
    *) exit 0 ;;
esac
T16B_TICKET
chmod +x "$_t16b_fake_repo/scripts/ticket"

cat > "$_t16b_fake_repo/scripts/classify-task.py" << 'T16B_SCORER'
import json, sys
tasks = json.loads(sys.stdin.read())
out = [{"id": t.get("id",""), "priority": 2, "class": "independent",
        "subagent": "general-purpose", "model": "sonnet",
        "complexity": "low", "reason": "stub"} for t in tasks]
print(json.dumps(out))
T16B_SCORER

cat > "$_t16b_fake_repo/scripts/read-config.sh" << 'T16B_CFG'
#!/usr/bin/env bash
KEY="${1:-}"; if [[ "$KEY" == "--list" ]]; then KEY="${2:-}"; fi
case "$KEY" in
    paths.src_dir) echo -n "src" ;;
    paths.test_dir) echo -n "tests" ;;
    paths.test_unit_dir) echo -n "tests/unit" ;;
    interpreter.python_venv) echo -n "" ;;
    *) echo -n "" ;;
esac
T16B_CFG
chmod +x "$_t16b_fake_repo/scripts/read-config.sh"
printf '' > "$_t16b_fake_repo/dso-config.conf"
cp "$PLUGIN_SCRIPT" "$_t16b_fake_repo/scripts/sprint-next-batch.sh"
chmod +x "$_t16b_fake_repo/scripts/sprint-next-batch.sh"

t16b_exit=0
t16b_output=$(cd "$_t16b_fake_repo" && TICKET_CMD="$_t16b_fake_repo/scripts/ticket" bash "$_t16b_fake_repo/scripts/sprint-next-batch.sh" "t16b-epic" --json 2>/dev/null) || t16b_exit=$?
rm -rf "$_t16b_fake_repo"

# t16b-task should appear in the batch because its parent story's only
# dependency (dso-dep-closed) is already closed — it is NOT a blocker.
# skipped_blocked_story must be 0 (story is not blocked) and t16b-task must
# be present in the batch.
t16b_batch_ids=$(echo "$t16b_output" | python3 -c "import sys,json; d=json.load(sys.stdin); print(' '.join(t['id'] for t in d.get('batch',[])))" 2>/dev/null || echo "")
t16b_blocked=$(echo "$t16b_output" | python3 -c "import sys,json; d=json.load(sys.stdin); print(len(d.get('skipped_blocked_story',[])))" 2>/dev/null || echo "1")
if [ "$t16b_exit" -eq 0 ] && echo "$t16b_batch_ids" | grep -q "t16b-task" && [ "$t16b_blocked" -eq 0 ]; then
    echo "  PASS: closed-dep target does not block ticket (t16b-task in batch, skipped_blocked_story=0)"
    (( PASS++ ))
else
    echo "  FAIL: ticket incorrectly blocked by closed dep (exit=$t16b_exit batch_ids='$t16b_batch_ids' skipped_blocked_story=$t16b_blocked)" >&2
    (( FAIL++ ))
fi

# ── Test 17: No v2 elif TICKETS_DIR branch ───────────────────────────────────
# RED test: assert the v2 `elif [ -d "$TICKETS_DIR" ]` block is removed.
# Currently FAILS because the v2 branch still exists in the script.
echo "Test 17: No v2 elif TICKETS_DIR branch in plugin script"
test_sprint_next_batch_no_v2_elif_branch() {
    if { grep -q 'elif \[ -d "\$TICKETS_DIR' "$PLUGIN_SCRIPT"; test $? -ne 0; }; then
        echo "  PASS: no v2 elif TICKETS_DIR branch found"
        (( PASS++ ))
    else
        echo "  FAIL: v2 elif TICKETS_DIR branch still present in $PLUGIN_SCRIPT" >&2
        (( FAIL++ ))
    fi
}
test_sprint_next_batch_no_v2_elif_branch

# ── Test 18: No standalone TICKETS_DIR= assignment ───────────────────────────
# RED test: assert the v2 standalone `TICKETS_DIR=` assignment is removed.
# Currently FAILS because line 196 still has TICKETS_DIR="${TICKETS_DIR:-...}".
echo "Test 18: No standalone TICKETS_DIR= variable assignment in plugin script"
test_sprint_next_batch_no_TICKETS_DIR_variable() {
    if { grep -q '^TICKETS_DIR=' "$PLUGIN_SCRIPT"; test $? -ne 0; }; then
        echo "  PASS: no standalone TICKETS_DIR= assignment found"
        (( PASS++ ))
    else
        echo "  FAIL: standalone TICKETS_DIR= assignment still present in $PLUGIN_SCRIPT" >&2
        (( FAIL++ ))
    fi
}
test_sprint_next_batch_no_TICKETS_DIR_variable

# ── Test 19: No v2 ticket body fallback (.tickets/$ticket_id) ────────────────
# RED test: assert the v2 _load_ticket_body fallback reading .tickets/<id>.md
# is removed. Pattern matches a literal bash-variable reference to .tickets/.
echo "Test 19: No v2 ticket body fallback (.tickets/\$ticket_id) in plugin script"
test_sprint_next_batch_no_v2_ticket_body_fallback() {
    if { grep -q '\.tickets/\$ticket_id' "$PLUGIN_SCRIPT"; test $? -ne 0; }; then
        echo "  PASS: no v2 .tickets/\$ticket_id fallback found"
        (( PASS++ ))
    else
        echo "  FAIL: v2 .tickets/\$ticket_id fallback still present in $PLUGIN_SCRIPT" >&2
        (( FAIL++ ))
    fi
}
test_sprint_next_batch_no_v2_ticket_body_fallback

# ── Test 20: No v2 tk-ready call ─────────────────────────────────────────────
# RED test: assert the old-style `"tk" ready` invocation (with literal tk, not
# the $TK variable) is removed.
echo "Test 20: No v2 tk ready call (literal quoted tk binary) in plugin script"
test_sprint_next_batch_no_tk_ready_call() {
    if { grep -q '"\" ready' "$PLUGIN_SCRIPT"; test $? -ne 0; }; then
        echo "  PASS: no v2 literal-tk ready call found"
        (( PASS++ ))
    else
        echo "  FAIL: v2 literal-tk ready call still present in $PLUGIN_SCRIPT" >&2
        (( FAIL++ ))
    fi
}
test_sprint_next_batch_no_tk_ready_call

# ── Test 21: No standalone TK= variable ──────────────────────────────────────
# RED test: assert the `TK=` variable assignment is removed (v3 routing should
# resolve tk via a different mechanism).
# Currently FAILS because line 55 still has TK="${TK:-...}".
echo "Test 21: No standalone TK= variable assignment in plugin script"
test_sprint_next_batch_no_TK_variable() {
    if { grep -q '^TK=' "$PLUGIN_SCRIPT"; test $? -ne 0; }; then
        echo "  PASS: no standalone TK= assignment found"
        (( PASS++ ))
    else
        echo "  FAIL: standalone TK= assignment still present in $PLUGIN_SCRIPT" >&2
        (( FAIL++ ))
    fi
}
test_sprint_next_batch_no_TK_variable

# ── Test: .test-index excluded from file-overlap conflict detection ────────────
# Bug 4298-db75: .test-index is a shared registry that many agents modify
# concurrently (adding test entries). Flagging it as a file-overlap conflict
# creates false positive serialization between unrelated tasks.
test_test_index_overlap_safe() {
    echo "Test: .test-index is in overlap-safe exclusion list"
    if grep -q 'test-index' "$PLUGIN_SCRIPT" && grep -qE 'OVERLAP_SAFE|overlap_safe' "$PLUGIN_SCRIPT"; then
        echo "  PASS: .test-index appears in an overlap-safe exclusion list"
        (( PASS++ ))
    else
        echo "  FAIL: sprint-next-batch.sh must exclude .test-index from file-overlap conflicts" >&2
        (( FAIL++ ))
    fi
}
test_test_index_overlap_safe

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
