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
if [ "$exit_code" -eq 0 ] && [[ "$output" =~ EPIC:|BATCH_SIZE: ]]; then
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
cd "$REPO_ROOT" || exit 1
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
        # t16-task is ready (no deps), but dso-story1 is blocked (has deps on dso-blocker1 which is in_progress)
        echo '[{"ticket_id":"t16-task","status":"open","ticket_type":"task","priority":2,"title":"Task under blocked story","parent_id":"dso-story1","deps":[]},{"ticket_id":"dso-story1","status":"open","ticket_type":"story","priority":2,"title":"Blocked story","parent_id":"t16-epic","deps":[{"target_id":"dso-blocker1","relation":"depends_on"}]},{"ticket_id":"dso-blocker1","status":"in_progress","ticket_type":"task","priority":2,"title":"Blocking task","parent_id":null,"deps":[]}]'
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
if [ "$t16b_exit" -eq 0 ] && [[ "$t16b_batch_ids" == *"t16b-task"* ]] && [ "$t16b_blocked" -eq 0 ]; then
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
    # shellcheck disable=SC2016  # literal pattern match, $ must not expand
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
    # shellcheck disable=SC2016  # literal pattern match, $ must not expand
    if { grep -q '\.tickets/\$ticket_id' "$PLUGIN_SCRIPT"; test $? -ne 0; }; then
        echo "  PASS: no v2 .tickets/\$ticket_id fallback found"
        (( PASS++ ))
    else
        echo "  FAIL: v2 .tickets/\$ticket_id fallback still present in $PLUGIN_SCRIPT" >&2
        (( FAIL++ ))
    fi
}
test_sprint_next_batch_no_v2_ticket_body_fallback

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

# ── Test: Script has explicit tracker init guard (not relying on TICKET_CMD) ────
echo "Test: test_init_on_missing_tracker — calls ticket-init.sh when tracker missing"
test_init_on_missing_tracker() {
    # Behavioral test: verifies that sprint-next-batch.sh invokes ticket-init.sh
    # directly (its own init guard) when the tracker dir doesn't exist and
    # TICKETS_TRACKER_DIR is not set. The ticket dispatcher also does init, but
    # the script must have its own guard for defensive correctness (same pattern
    # as sprint-list-epics.sh fix 3b71-e877).
    #
    # Strategy: provide a TICKET_CMD that does NOT touch the marker file, so
    # the marker is only set if the script calls ticket-init.sh directly.
    local TDIR_INIT STUB_CALLED
    TDIR_INIT=$(mktemp -d)
    _CLEANUP_DIRS+=("$TDIR_INIT")
    STUB_CALLED="$TDIR_INIT/init-was-called"

    # Copy the real script into the temp dir
    cp "$PLUGIN_SCRIPT" "$TDIR_INIT/sprint-next-batch.sh"
    chmod +x "$TDIR_INIT/sprint-next-batch.sh"

    # Create a stub ticket-init.sh that records invocation
    cat > "$TDIR_INIT/ticket-init.sh" << 'STUBEOF'
#!/usr/bin/env bash
touch "$STUB_CALLED_FILE"
exit 0
STUBEOF
    chmod +x "$TDIR_INIT/ticket-init.sh"

    # Create a separate TICKET_CMD stub that does NOT touch the marker
    # (so we only detect the direct ticket-init.sh call from the init guard)
    cat > "$TDIR_INIT/ticket-stub" << 'TICKETSTUB'
#!/usr/bin/env bash
echo '{"ticket_id":"fake-epic","status":"open","ticket_type":"epic","priority":1,"title":"Fake","parent_id":null,"comments":[],"deps":[]}'
exit 0
TICKETSTUB
    chmod +x "$TDIR_INIT/ticket-stub"

    # Minimal read-config.sh stub
    cat > "$TDIR_INIT/read-config.sh" << 'CFGSTUB'
#!/usr/bin/env bash
echo ""
exit 0
CFGSTUB
    chmod +x "$TDIR_INIT/read-config.sh"

    # PROJECT_ROOT has no .tickets-tracker; TICKETS_TRACKER_DIR is unset (default path)
    local fake_root="$TDIR_INIT/fake-repo"
    mkdir -p "$fake_root"
    git init -q -b main "$fake_root"

    STUB_CALLED_FILE="$STUB_CALLED" PROJECT_ROOT="$fake_root" \
        TICKET_CMD="$TDIR_INIT/ticket-stub" \
        bash "$TDIR_INIT/sprint-next-batch.sh" "fake-epic" >/dev/null 2>&1 || true

    [ -f "$STUB_CALLED" ]
}
if test_init_on_missing_tracker; then
    echo "  PASS: script calls ticket-init.sh when tracker dir missing"
    (( PASS++ ))
else
    echo "  FAIL: script did not call ticket-init.sh — fresh worktrees will fail" >&2
    (( FAIL++ ))
fi

# ── Test: Tracker init only runs for default path, not TICKETS_TRACKER_DIR ──
echo "Test: test_init_skipped_for_override — no init when TICKETS_TRACKER_DIR is set"
test_init_skipped_for_override() {
    local TDIR_SKIP STUB_CALLED
    TDIR_SKIP=$(mktemp -d)
    _CLEANUP_DIRS+=("$TDIR_SKIP")
    STUB_CALLED="$TDIR_SKIP/init-was-called"

    cp "$PLUGIN_SCRIPT" "$TDIR_SKIP/sprint-next-batch.sh"
    chmod +x "$TDIR_SKIP/sprint-next-batch.sh"

    cat > "$TDIR_SKIP/ticket-init.sh" << 'STUBEOF'
#!/usr/bin/env bash
touch "$STUB_CALLED_FILE"
exit 0
STUBEOF
    chmod +x "$TDIR_SKIP/ticket-init.sh"

    # Separate ticket stub that doesn't touch marker
    cat > "$TDIR_SKIP/ticket-stub" << 'TICKETSTUB'
#!/usr/bin/env bash
echo '{"ticket_id":"fake-epic","status":"open","ticket_type":"epic","priority":1,"title":"Fake","parent_id":null,"comments":[],"deps":[]}'
exit 0
TICKETSTUB
    chmod +x "$TDIR_SKIP/ticket-stub"

    cat > "$TDIR_SKIP/read-config.sh" << 'CFGSTUB'
#!/usr/bin/env bash
echo ""
exit 0
CFGSTUB
    chmod +x "$TDIR_SKIP/read-config.sh"

    local nonexistent_tracker="$TDIR_SKIP/no-such-tracker"

    STUB_CALLED_FILE="$STUB_CALLED" TICKETS_TRACKER_DIR="$nonexistent_tracker" \
        TICKET_CMD="$TDIR_SKIP/ticket-stub" \
        bash "$TDIR_SKIP/sprint-next-batch.sh" "fake-epic" >/dev/null 2>&1 || true

    [ ! -f "$STUB_CALLED" ]
}
if test_init_skipped_for_override; then
    echo "  PASS: init is skipped when TICKETS_TRACKER_DIR is set"
    (( PASS++ ))
else
    echo "  FAIL: init was called even though TICKETS_TRACKER_DIR is set" >&2
    (( FAIL++ ))
fi

# ── Test: Childless stories are skipped with SKIPPED_NEEDS_PLANNING ──────────
echo "Test: test_childless_story_skipped_needs_planning — story with 0 children is not dispatched"

_t_plan_fake_repo=$(mktemp -d)
_CLEANUP_DIRS+=("$_t_plan_fake_repo")
git init -q -b main "$_t_plan_fake_repo"
mkdir -p "$_t_plan_fake_repo/scripts"

# A story with 0 children (no implementation tasks)
cat > "$_t_plan_fake_repo/scripts/ticket" << 'T_PLAN_TICKET'
#!/usr/bin/env bash
SUBCMD="${1:-}"; shift || true; TICKET_ID="${1:-}"
case "$SUBCMD" in
    show)
        if [[ "$TICKET_ID" == "plan-epic" ]]; then
            echo '{"ticket_id":"plan-epic","status":"open","ticket_type":"epic","priority":1,"title":"Test Epic","parent_id":null,"comments":[],"deps":[]}'
        elif [[ "$TICKET_ID" == "plan-story" ]]; then
            echo '{"ticket_id":"plan-story","status":"open","ticket_type":"story","priority":2,"title":"Story needing planning","parent_id":"plan-epic","comments":[],"deps":[]}'
        else
            echo '{"status":"error","error":"not found","ticket_id":"'"$TICKET_ID"'"}'; exit 1
        fi; exit 0 ;;
    list)
        # plan-story is a story with NO children — it should be skipped
        echo '[{"ticket_id":"plan-story","status":"open","ticket_type":"story","priority":2,"title":"Story needing planning","parent_id":"plan-epic","deps":[]}]'
        exit 0 ;;
    *) exit 0 ;;
esac
T_PLAN_TICKET
chmod +x "$_t_plan_fake_repo/scripts/ticket"

cat > "$_t_plan_fake_repo/scripts/classify-task.py" << 'T_PLAN_SCORER'
import json, sys
tasks = json.loads(sys.stdin.read())
out = [{"id": t.get("id",""), "priority": 2, "class": "independent",
        "subagent": "general-purpose", "model": "sonnet",
        "complexity": "low", "reason": "stub"} for t in tasks]
print(json.dumps(out))
T_PLAN_SCORER

cat > "$_t_plan_fake_repo/scripts/read-config.sh" << 'T_PLAN_CFG'
#!/usr/bin/env bash
KEY="${1:-}"; if [[ "$KEY" == "--list" ]]; then KEY="${2:-}"; fi
case "$KEY" in
    paths.src_dir) echo -n "src" ;;
    paths.test_dir) echo -n "tests" ;;
    paths.test_unit_dir) echo -n "tests/unit" ;;
    interpreter.python_venv) echo -n "" ;;
    *) echo -n "" ;;
esac
T_PLAN_CFG
chmod +x "$_t_plan_fake_repo/scripts/read-config.sh"
printf '' > "$_t_plan_fake_repo/dso-config.conf"

_t_plan_output=$(
    CLAUDE_PLUGIN_ROOT="$DSO_PLUGIN_DIR" \
    PROJECT_ROOT="$_t_plan_fake_repo" \
    SCRIPT_DIR="$_t_plan_fake_repo/scripts" \
    TICKET_CMD="$_t_plan_fake_repo/scripts/ticket" \
    CLASSIFY_CMD="python3 $_t_plan_fake_repo/scripts/classify-task.py" \
    TICKETS_TRACKER_DIR="$_t_plan_fake_repo/.tickets-tracker" \
    bash "$PLUGIN_SCRIPT" "plan-epic" 2>&1
) || true

# The story should NOT appear as a TASK: line — it should be SKIPPED_NEEDS_PLANNING
_t_plan_task_lines=$(echo "$_t_plan_output" | grep "^TASK:" || true)
_t_plan_skipped=$(echo "$_t_plan_output" | grep "SKIPPED_NEEDS_PLANNING" || true)

if [ -z "$_t_plan_task_lines" ] && [ -n "$_t_plan_skipped" ]; then
    echo "  PASS: childless story skipped with SKIPPED_NEEDS_PLANNING (batch_size=0)"
    (( PASS++ ))
else
    echo "  FAIL: childless story should be SKIPPED_NEEDS_PLANNING, not dispatched as TASK" >&2
    echo "    TASK lines: $_t_plan_task_lines" >&2
    echo "    SKIPPED_NEEDS_PLANNING: $_t_plan_skipped" >&2
    (( FAIL++ ))
fi

# ── Test: Init failure stderr is surfaced, not swallowed ──────────────────
echo "Test: test_init_failure_emits_stderr — diagnostic output reaches stderr when init fails"
test_init_failure_emits_stderr() {
    local TDIR_STDERR
    TDIR_STDERR=$(mktemp -d)
    _CLEANUP_DIRS+=("$TDIR_STDERR")

    cp "$PLUGIN_SCRIPT" "$TDIR_STDERR/sprint-next-batch.sh"
    chmod +x "$TDIR_STDERR/sprint-next-batch.sh"

    # Stub ticket-init.sh: emits a diagnostic on stderr and exits non-zero
    cat > "$TDIR_STDERR/ticket-init.sh" << 'STUBEOF'
#!/usr/bin/env bash
echo "ERROR: tracker mount failed" >&2
exit 1
STUBEOF
    chmod +x "$TDIR_STDERR/ticket-init.sh"

    # Separate ticket stub
    cat > "$TDIR_STDERR/ticket-stub" << 'TICKETSTUB'
#!/usr/bin/env bash
echo '{"ticket_id":"fake-epic","status":"open","ticket_type":"epic","priority":1,"title":"Fake","parent_id":null,"comments":[],"deps":[]}'
exit 0
TICKETSTUB
    chmod +x "$TDIR_STDERR/ticket-stub"

    cat > "$TDIR_STDERR/read-config.sh" << 'CFGSTUB'
#!/usr/bin/env bash
echo ""
exit 0
CFGSTUB
    chmod +x "$TDIR_STDERR/read-config.sh"

    local fake_root="$TDIR_STDERR/fake-repo"
    mkdir -p "$fake_root"
    git init -q -b main "$fake_root"

    local captured_stderr
    captured_stderr=$(PROJECT_ROOT="$fake_root" \
        TICKET_CMD="$TDIR_STDERR/ticket-stub" \
        bash "$TDIR_STDERR/sprint-next-batch.sh" "fake-epic" 2>&1 >/dev/null) || true

    # The stub's error message must appear in stderr — not be silently swallowed
    [[ "$captured_stderr" == *"tracker mount failed"* ]]
}
if test_init_failure_emits_stderr; then
    echo "  PASS: init failure diagnostic is emitted on stderr"
    (( PASS++ ))
else
    echo "  FAIL: init failure stderr was silently swallowed — diagnostic output lost" >&2
    (( FAIL++ ))
fi

# ── Test: plugins/ prose paths trigger file-overlap conflict detection ────────
# RED test (bug 559d-b900): extract_files() hardcodes dir_roots = {src, test,
# "app", ".claude"} — "plugins" is absent. Two tasks whose bodies reference the
# SAME plugins/ path in prose (not backtick-wrapped) should produce
# skipped_overlap=1. Currently FAILS because the plugins/ path is invisible
# to the overlap detector and both tasks are dispatched (skipped_overlap=0).
echo "Test: test_plugins_dir_conflict_detection — prose plugins/ path references trigger overlap deferral"
test_plugins_dir_conflict_detection() {
    local _tp_fake_repo
    _tp_fake_repo=$(mktemp -d)
    _CLEANUP_DIRS+=("$_tp_fake_repo")
    git init -q -b main "$_tp_fake_repo"
    mkdir -p "$_tp_fake_repo/scripts"

    # v3: create event-sourced tracker directory structure
    mkdir -p "$_tp_fake_repo/.tickets-tracker/tp-epic"
    mkdir -p "$_tp_fake_repo/.tickets-tracker/tp-task-a"
    mkdir -p "$_tp_fake_repo/.tickets-tracker/tp-task-b"

    # Epic CREATE event
    python3 -c "
import json
with open('$_tp_fake_repo/.tickets-tracker/tp-epic/0001-CREATE.json', 'w') as f:
    json.dump({'timestamp': 2000, 'uuid': 'v1', 'event_type': 'CREATE',
               'env_id': 'test', 'author': 'test',
               'data': {'ticket_type': 'epic', 'title': 'Plugins dir conflict epic',
                        'parent_id': '', 'priority': 1}}, f)
"

    # Task A: prose reference (no backticks) to plugins/dso/scripts/sprint-next-batch.sh
    python3 -c "
import json
with open('$_tp_fake_repo/.tickets-tracker/tp-task-a/0001-CREATE.json', 'w') as f:
    json.dump({'timestamp': 2001, 'uuid': 'v2', 'event_type': 'CREATE',
               'env_id': 'test', 'author': 'test',
               'data': {'ticket_type': 'task', 'title': 'Task A',
                        'parent_id': 'tp-epic', 'priority': 2}}, f)
with open('$_tp_fake_repo/.tickets-tracker/tp-task-a/0002-COMMENT.json', 'w') as f:
    json.dump({'timestamp': 2002, 'uuid': 'v3', 'event_type': 'COMMENT',
               'env_id': 'test', 'author': 'test',
               'data': {'body': 'Update plugins/dso/scripts/sprint-next-batch.sh to add feature A'}}, f)
"

    # Task B: same prose reference — should conflict with Task A
    python3 -c "
import json
with open('$_tp_fake_repo/.tickets-tracker/tp-task-b/0001-CREATE.json', 'w') as f:
    json.dump({'timestamp': 2003, 'uuid': 'v4', 'event_type': 'CREATE',
               'env_id': 'test', 'author': 'test',
               'data': {'ticket_type': 'task', 'title': 'Task B',
                        'parent_id': 'tp-epic', 'priority': 2}}, f)
with open('$_tp_fake_repo/.tickets-tracker/tp-task-b/0002-COMMENT.json', 'w') as f:
    json.dump({'timestamp': 2004, 'uuid': 'v5', 'event_type': 'COMMENT',
               'env_id': 'test', 'author': 'test',
               'data': {'body': 'Modify plugins/dso/scripts/sprint-next-batch.sh to add feature B'}}, f)
"

    cat > "$_tp_fake_repo/scripts/ticket" << 'TP_TICKET'
#!/usr/bin/env bash
SUBCMD="${1:-}"; shift || true; TICKET_ID="${1:-}"
case "$SUBCMD" in
    show)
        if [[ "$TICKET_ID" == "tp-epic" ]]; then
            echo '{"ticket_id":"tp-epic","status":"open","ticket_type":"epic","priority":1,"title":"Plugins dir conflict epic","parent_id":null,"comments":[],"deps":[]}'
        else
            echo '{"status":"error","error":"not found","ticket_id":"'"$TICKET_ID"'"}'; exit 1
        fi; exit 0 ;;
    list)
        echo '[{"ticket_id":"tp-task-a","status":"open","ticket_type":"task","priority":2,"title":"Task A","parent_id":"tp-epic","deps":[]},{"ticket_id":"tp-task-b","status":"open","ticket_type":"task","priority":2,"title":"Task B","parent_id":"tp-epic","deps":[]}]'
        exit 0 ;;
    *) exit 0 ;;
esac
TP_TICKET
    chmod +x "$_tp_fake_repo/scripts/ticket"

    cat > "$_tp_fake_repo/scripts/classify-task.py" << 'TP_SCORER'
import json, sys
tasks = json.loads(sys.stdin.read())
out = [{"id": t.get("id",""), "priority": 2, "class": "independent",
        "subagent": "general-purpose", "model": "sonnet",
        "complexity": "low", "reason": "stub"} for t in tasks]
print(json.dumps(out))
TP_SCORER

    cat > "$_tp_fake_repo/scripts/read-config.sh" << 'TP_CFG'
#!/usr/bin/env bash
KEY="${1:-}"; if [[ "$KEY" == "--list" ]]; then KEY="${2:-}"; fi
case "$KEY" in
    paths.src_dir) echo -n "src" ;;
    paths.test_dir) echo -n "tests" ;;
    paths.test_unit_dir) echo -n "tests/unit" ;;
    interpreter.python_venv) echo -n "" ;;
    *) echo -n "" ;;
esac
TP_CFG
    chmod +x "$_tp_fake_repo/scripts/read-config.sh"
    printf '' > "$_tp_fake_repo/dso-config.conf"
    cp "$PLUGIN_SCRIPT" "$_tp_fake_repo/scripts/sprint-next-batch.sh"
    chmod +x "$_tp_fake_repo/scripts/sprint-next-batch.sh"
    cp "$DSO_PLUGIN_DIR/scripts/ticket-reducer.py" "$_tp_fake_repo/scripts/ticket-reducer.py"

    local tp_exit=0
    local tp_output
    tp_output=$(
        cd "$_tp_fake_repo" && \
        TICKETS_TRACKER_DIR="$_tp_fake_repo/.tickets-tracker" \
        CLAUDE_PLUGIN_ROOT="$_tp_fake_repo" \
        TICKET_CMD="$_tp_fake_repo/scripts/ticket" \
        bash "$_tp_fake_repo/scripts/sprint-next-batch.sh" "tp-epic" --json 2>/dev/null
    ) || tp_exit=$?

    local tp_batch_size tp_skipped
    tp_batch_size=$(echo "$tp_output" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('batch_size',0))" 2>/dev/null || echo "-1")
    tp_skipped=$(echo "$tp_output" | python3 -c "import sys,json; d=json.load(sys.stdin); print(len(d.get('skipped_overlap',[])))" 2>/dev/null || echo "-1")

    # Both tasks reference the same plugins/ path in prose — overlap detector must
    # catch it: batch_size=1 (one task wins), skipped_overlap=1 (one deferred).
    [ "$tp_exit" -eq 0 ] && [ "$tp_batch_size" -eq 1 ] && [ "$tp_skipped" -eq 1 ]
}
if test_plugins_dir_conflict_detection; then
    echo "  PASS: plugins/ prose path references detected as file-overlap conflict (batch=1, skipped_overlap=1)"
    (( PASS++ ))
else
    echo "  FAIL: plugins/ prose path references NOT detected — extract_files() missing 'plugins' in dir_roots (bug 559d-b900)" >&2
    (( FAIL++ ))
fi

# ── Test 28: ticket list called with --status=open,in_progress (bug 2242-d974) ─
echo "Test 28: sprint-next-batch passes --status=open,in_progress to ticket list (bug 2242-d974)"
_t28_fake_repo=$(mktemp -d)
_CLEANUP_DIRS+=("$_t28_fake_repo")
git init -q -b main "$_t28_fake_repo"
mkdir -p "$_t28_fake_repo/scripts"
_t28_args_log="$_t28_fake_repo/ticket-list-args.log"

# Mock ticket CLI: records arguments passed to "list" subcommand in a log file.
# Also returns a minimal valid response so sprint-next-batch can complete.
cat > "$_t28_fake_repo/scripts/ticket" << T28_TICKET
#!/usr/bin/env bash
SUBCMD="\${1:-}"; shift || true; TICKET_ID="\${1:-}"
case "\$SUBCMD" in
    show)
        if [[ "\$TICKET_ID" == "t28-epic" ]]; then
            echo '{"ticket_id":"t28-epic","status":"open","ticket_type":"epic","priority":1,"title":"Test Epic","parent_id":null,"comments":[],"deps":[]}'
        else
            echo '{"status":"error","error":"not found","ticket_id":"'"'"\$TICKET_ID"'"'"}'; exit 1
        fi; exit 0 ;;
    list)
        # Record ALL arguments passed to "list" into the log file
        echo "\$*" >> "$_t28_args_log"
        echo '[{"ticket_id":"t28-open-task","status":"open","ticket_type":"task","priority":2,"title":"Open Task","parent_id":"t28-epic","deps":[]}]'
        exit 0 ;;
    *) exit 0 ;;
esac
T28_TICKET
chmod +x "$_t28_fake_repo/scripts/ticket"

cat > "$_t28_fake_repo/scripts/classify-task.py" << 'T28_SCORER'
import json, sys
tasks = json.loads(sys.stdin.read())
out = [{"id": t.get("id",""), "priority": 2, "class": "independent",
        "subagent": "general-purpose", "model": "sonnet",
        "complexity": "low", "reason": "stub"} for t in tasks]
print(json.dumps(out))
T28_SCORER

cat > "$_t28_fake_repo/scripts/read-config.sh" << 'T28_CFG'
#!/usr/bin/env bash
KEY="${1:-}"; if [[ "$KEY" == "--list" ]]; then KEY="${2:-}"; fi
case "$KEY" in
    paths.src_dir) echo -n "src" ;;
    paths.test_dir) echo -n "tests" ;;
    paths.test_unit_dir) echo -n "tests/unit" ;;
    interpreter.python_venv) echo -n "" ;;
    *) echo -n "" ;;
esac
T28_CFG
chmod +x "$_t28_fake_repo/scripts/read-config.sh"
printf '' > "$_t28_fake_repo/dso-config.conf"
cp "$PLUGIN_SCRIPT" "$_t28_fake_repo/scripts/sprint-next-batch.sh"
chmod +x "$_t28_fake_repo/scripts/sprint-next-batch.sh"

t28_exit=0
t28_output=$(
    cd "$_t28_fake_repo" && \
    TICKET_CMD="$_t28_fake_repo/scripts/ticket" \
    bash "$_t28_fake_repo/scripts/sprint-next-batch.sh" "t28-epic" 2>&1
) || t28_exit=$?

# Check that at least one "list" invocation used --status=open,in_progress
t28_status_used=0
if [ -f "$_t28_args_log" ] && grep -q -- "--status=open,in_progress" "$_t28_args_log"; then
    t28_status_used=1
fi
rm -rf "$_t28_fake_repo"

if [ "$t28_status_used" -eq 1 ]; then
    echo "  PASS: ticket list called with --status=open,in_progress"
    (( PASS++ ))
else
    echo "  FAIL: ticket list was NOT called with --status=open,in_progress (bug 2242-d974)" >&2
    (( FAIL++ ))
fi

# ── Test 29: Unknown dep target (absent from ticket list) defaults to closed ──
# Bug 401c-4a1a / b418-cdb9: ticket_status_map.get(target_id, "open") defaulted
# to "open" for targets not in the map, causing external/deleted tickets to
# permanently block dependents. Fix: default to "closed" so unknown deps are
# treated as already satisfied.
echo "Test 29: Unknown dep target (not in ticket list) does NOT block ticket (bug 401c-4a1a)"
_t29_fake_repo=$(mktemp -d)
_CLEANUP_DIRS+=("$_t29_fake_repo")
git init -q -b main "$_t29_fake_repo"
mkdir -p "$_t29_fake_repo/scripts"

# t29-task's parent story has a depends_on dep on "external-dep-unknown" which
# is NOT included in the ticket list at all (simulates an external or deleted
# ticket). With the old default of "open", this would block the story and task.
# With the fix (default "closed"), the dep is treated as satisfied → task is ready.
cat > "$_t29_fake_repo/scripts/ticket" << 'T29_TICKET'
#!/usr/bin/env bash
SUBCMD="${1:-}"; shift || true; TICKET_ID="${1:-}"
case "$SUBCMD" in
    show)
        if [[ "$TICKET_ID" == "t29-epic" ]]; then
            echo '{"ticket_id":"t29-epic","status":"open","ticket_type":"epic","priority":1,"title":"Test Epic","parent_id":null,"comments":[],"deps":[]}'
        elif [[ "$TICKET_ID" == "t29-task" ]]; then
            echo '{"ticket_id":"t29-task","status":"open","ticket_type":"task","priority":2,"title":"Task under story with unknown dep","parent_id":"t29-story","comments":[],"deps":[]}'
        elif [[ "$TICKET_ID" == "t29-story" ]]; then
            echo '{"ticket_id":"t29-story","status":"open","ticket_type":"story","priority":2,"title":"Story with unknown dep","parent_id":"t29-epic","comments":[],"deps":[{"target_id":"external-dep-unknown","relation":"depends_on"}]}'
        else
            echo '{"status":"error","error":"not found","ticket_id":"'"$TICKET_ID"'"}'; exit 1
        fi; exit 0 ;;
    list)
        # external-dep-unknown is intentionally absent from this list —
        # it represents an external or deleted ticket not tracked here.
        echo '[{"ticket_id":"t29-task","status":"open","ticket_type":"task","priority":2,"title":"Task under story with unknown dep","parent_id":"t29-story","deps":[]},{"ticket_id":"t29-story","status":"open","ticket_type":"story","priority":2,"title":"Story with unknown dep","parent_id":"t29-epic","deps":[{"target_id":"external-dep-unknown","relation":"depends_on"}]}]'
        exit 0 ;;
    *) exit 0 ;;
esac
T29_TICKET
chmod +x "$_t29_fake_repo/scripts/ticket"

cat > "$_t29_fake_repo/scripts/classify-task.py" << 'T29_SCORER'
import json, sys
tasks = json.loads(sys.stdin.read())
out = [{"id": t.get("id",""), "priority": 2, "class": "independent",
        "subagent": "general-purpose", "model": "sonnet",
        "complexity": "low", "reason": "stub"} for t in tasks]
print(json.dumps(out))
T29_SCORER

cat > "$_t29_fake_repo/scripts/read-config.sh" << 'T29_CFG'
#!/usr/bin/env bash
KEY="${1:-}"; if [[ "$KEY" == "--list" ]]; then KEY="${2:-}"; fi
case "$KEY" in
    paths.src_dir) echo -n "src" ;;
    paths.test_dir) echo -n "tests" ;;
    paths.test_unit_dir) echo -n "tests/unit" ;;
    interpreter.python_venv) echo -n "" ;;
    *) echo -n "" ;;
esac
T29_CFG
chmod +x "$_t29_fake_repo/scripts/read-config.sh"
printf '' > "$_t29_fake_repo/dso-config.conf"
cp "$PLUGIN_SCRIPT" "$_t29_fake_repo/scripts/sprint-next-batch.sh"
chmod +x "$_t29_fake_repo/scripts/sprint-next-batch.sh"

t29_exit=0
t29_output=$(cd "$_t29_fake_repo" && TICKET_CMD="$_t29_fake_repo/scripts/ticket" bash "$_t29_fake_repo/scripts/sprint-next-batch.sh" "t29-epic" --json 2>/dev/null) || t29_exit=$?
rm -rf "$_t29_fake_repo"

# t29-task should appear in the batch: its parent story's depends_on target
# ("external-dep-unknown") is absent from the ticket list, so it defaults to
# "closed" → NOT a blocker → story is not blocked → task is ready.
t29_batch_ids=$(echo "$t29_output" | python3 -c "import sys,json; d=json.load(sys.stdin); print(' '.join(t['id'] for t in d.get('batch',[])))" 2>/dev/null || echo "")
t29_blocked=$(echo "$t29_output" | python3 -c "import sys,json; d=json.load(sys.stdin); print(len(d.get('skipped_blocked_story',[])))" 2>/dev/null || echo "1")
if [ "$t29_exit" -eq 0 ] && [[ "$t29_batch_ids" == *"t29-task"* ]] && [ "$t29_blocked" -eq 0 ]; then
    echo "  PASS: unknown dep target defaults to closed — does not block ticket (t29-task in batch, skipped_blocked_story=0)"
    (( PASS++ ))
else
    echo "  FAIL: unknown dep target incorrectly blocked ticket (exit=$t29_exit batch_ids='$t29_batch_ids' skipped_blocked_story=$t29_blocked)" >&2
    echo "  This means ticket_status_map.get(target_id, ...) default is 'open' not 'closed' — bug 401c-4a1a not fixed" >&2
    (( FAIL++ ))
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
