#!/usr/bin/env bash
# tests/scripts/test-sprint-next-batch-design-filter.sh
# RED tests: verify sprint-next-batch.sh filters tasks whose parent story
# has the design:awaiting_import tag (SKIPPED_DESIGN_AWAITING output).
#
# These tests MUST FAIL until sprint-next-batch.sh implements tag-based
# filtering for design:awaiting_import.
#
# Usage: bash tests/scripts/test-sprint-next-batch-design-filter.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DSO_PLUGIN_DIR="$PLUGIN_ROOT/plugins/dso"
PLUGIN_SCRIPT="$DSO_PLUGIN_DIR/scripts/sprint-next-batch.sh"

source "$(dirname "${BASH_SOURCE[0]}")/../lib/run_test.sh"

# Temp dir cleanup on exit
_CLEANUP_DIRS=()
# shellcheck disable=SC2329  # invoked via trap, not directly
_cleanup() { for d in "${_CLEANUP_DIRS[@]}"; do rm -rf "$d"; done; }
trap _cleanup EXIT

echo "=== test-sprint-next-batch-design-filter.sh ==="

# ── Shared helper: build a minimal fake repo ────────────────────────────────
# Sets up scripts/ticket, scripts/classify-task.py, scripts/read-config.sh,
# dso-config.conf, and copies sprint-next-batch.sh.
_setup_fake_repo() {
    local repo_dir="$1"
    git init -q -b main "$repo_dir"
    mkdir -p "$repo_dir/scripts"
    printf '' > "$repo_dir/dso-config.conf"

    # Default classify-task.py stub — labels everything "independent/sonnet"
    cat > "$repo_dir/scripts/classify-task.py" << 'SCORER'
import json, sys
tasks = json.loads(sys.stdin.read())
out = [{"id": t.get("id",""), "priority": 2, "class": "independent",
        "subagent": "general-purpose", "model": "sonnet",
        "complexity": "low", "reason": "stub"} for t in tasks]
print(json.dumps(out))
SCORER

    # read-config.sh stub
    cat > "$repo_dir/scripts/read-config.sh" << 'CFG'
#!/usr/bin/env bash
KEY="${1:-}"; if [[ "$KEY" == "--list" ]]; then KEY="${2:-}"; fi
case "$KEY" in
    paths.src_dir) echo -n "src" ;;
    paths.test_dir) echo -n "tests" ;;
    paths.test_unit_dir) echo -n "tests/unit" ;;
    interpreter.python_venv) echo -n "" ;;
    *) echo -n "" ;;
esac
CFG
    chmod +x "$repo_dir/scripts/read-config.sh"

    cp "$PLUGIN_SCRIPT" "$repo_dir/scripts/sprint-next-batch.sh"
    chmod +x "$repo_dir/scripts/sprint-next-batch.sh"
    cp "$DSO_PLUGIN_DIR/scripts/ticket-next-batch.sh" "$repo_dir/scripts/ticket-next-batch.sh"
}

# ── Test DA-3: Task under non-tagged story is NOT skipped ────────────────────
# A story without the design:awaiting_import tag must not cause its tasks
# to be skipped. This test must PASS even before the feature is implemented.
echo "Test DA-3: Task under story without design:awaiting_import tag is NOT skipped"
_da3_repo=$(mktemp -d)
_CLEANUP_DIRS+=("$_da3_repo")
_setup_fake_repo "$_da3_repo"

cat > "$_da3_repo/scripts/ticket" << 'DA3_TICKET'
#!/usr/bin/env bash
SUBCMD="${1:-}"; shift || true; TICKET_ID="${1:-}"
case "$SUBCMD" in
    show)
        if [[ "$TICKET_ID" == "da3-epic" ]]; then
            echo '{"ticket_id":"da3-epic","status":"open","ticket_type":"epic","priority":1,"title":"Normal Epic","parent_id":null,"comments":[],"deps":[],"tags":[]}'
        elif [[ "$TICKET_ID" == "da3-story" ]]; then
            echo '{"ticket_id":"da3-story","status":"open","ticket_type":"story","priority":2,"title":"Normal story","parent_id":"da3-epic","comments":[],"deps":[],"tags":[]}'
        elif [[ "$TICKET_ID" == "da3-task" ]]; then
            echo '{"ticket_id":"da3-task","status":"open","ticket_type":"task","priority":3,"title":"Task under normal story","parent_id":"da3-story","comments":[],"deps":[],"tags":[]}'
        else
            echo '{"status":"error","error":"not found","ticket_id":"'"$TICKET_ID"'"}'; exit 1
        fi; exit 0 ;;
    list)
        echo '[{"ticket_id":"da3-story","status":"open","ticket_type":"story","priority":2,"title":"Normal story","parent_id":"da3-epic","deps":[],"tags":[]},{"ticket_id":"da3-task","status":"open","ticket_type":"task","priority":3,"title":"Task under normal story","parent_id":"da3-story","deps":[],"tags":[]}]'
        exit 0 ;;
    *) exit 0 ;;
esac
DA3_TICKET
chmod +x "$_da3_repo/scripts/ticket"

da3_exit=0
da3_output=$(cd "$_da3_repo" && TICKET_CMD="$_da3_repo/scripts/ticket" bash "$_da3_repo/scripts/sprint-next-batch.sh" "da3-epic" 2>/dev/null) || da3_exit=$?

# The task should appear in the batch (TASK: line), not be skipped
if [ "$da3_exit" -eq 0 ] && echo "$da3_output" | grep -q "^TASK:" && ! echo "$da3_output" | grep -q "SKIPPED_DESIGN_AWAITING"; then
    echo "  PASS: task under normal story appears in batch, not skipped"
    (( PASS++ ))
else
    echo "  FAIL: task under non-tagged story was unexpectedly skipped or not in batch (exit=$da3_exit)" >&2
    (( FAIL++ ))
fi

# ── Test DA-4: Task under design:approved story is NOT skipped ───────────────
# A story with design:approved (not design:awaiting_import) must not cause
# its tasks to be filtered. This verifies the filter is tag-specific.
echo "Test DA-4: Task under design:approved story (not awaiting) is NOT skipped"
_da4_repo=$(mktemp -d)
_CLEANUP_DIRS+=("$_da4_repo")
_setup_fake_repo "$_da4_repo"

cat > "$_da4_repo/scripts/ticket" << 'DA4_TICKET'
#!/usr/bin/env bash
SUBCMD="${1:-}"; shift || true; TICKET_ID="${1:-}"
case "$SUBCMD" in
    show)
        if [[ "$TICKET_ID" == "da4-epic" ]]; then
            echo '{"ticket_id":"da4-epic","status":"open","ticket_type":"epic","priority":1,"title":"Approved Design Epic","parent_id":null,"comments":[],"deps":[],"tags":[]}'
        elif [[ "$TICKET_ID" == "da4-story" ]]; then
            echo '{"ticket_id":"da4-story","status":"open","ticket_type":"story","priority":2,"title":"Story with approved design","parent_id":"da4-epic","comments":[],"deps":[],"tags":["design:approved"]}'
        elif [[ "$TICKET_ID" == "da4-task" ]]; then
            echo '{"ticket_id":"da4-task","status":"open","ticket_type":"task","priority":3,"title":"Task under approved-design story","parent_id":"da4-story","comments":[],"deps":[],"tags":[]}'
        else
            echo '{"status":"error","error":"not found","ticket_id":"'"$TICKET_ID"'"}'; exit 1
        fi; exit 0 ;;
    list)
        echo '[{"ticket_id":"da4-story","status":"open","ticket_type":"story","priority":2,"title":"Story with approved design","parent_id":"da4-epic","deps":[],"tags":["design:approved"]},{"ticket_id":"da4-task","status":"open","ticket_type":"task","priority":3,"title":"Task under approved-design story","parent_id":"da4-story","deps":[],"tags":[]}]'
        exit 0 ;;
    *) exit 0 ;;
esac
DA4_TICKET
chmod +x "$_da4_repo/scripts/ticket"

da4_exit=0
da4_output=$(cd "$_da4_repo" && TICKET_CMD="$_da4_repo/scripts/ticket" bash "$_da4_repo/scripts/sprint-next-batch.sh" "da4-epic" 2>/dev/null) || da4_exit=$?

# The task should appear in the batch (TASK: line), not be skipped
if [ "$da4_exit" -eq 0 ] && echo "$da4_output" | grep -q "^TASK:" && ! echo "$da4_output" | grep -q "SKIPPED_DESIGN_AWAITING"; then
    echo "  PASS: task under design:approved story appears in batch, not skipped"
    (( PASS++ ))
else
    echo "  FAIL: task under design:approved story was unexpectedly skipped (exit=$da4_exit)" >&2
    (( FAIL++ ))
fi

# ── Tests below verify sprint-next-batch.sh tag-based design filter ──

# ── Test DA-1: Task under design:awaiting_import story is SKIPPED_DESIGN_AWAITING ──
# This is a RED test: sprint-next-batch.sh does not yet filter by tag.
# Expected: the task appears as SKIPPED_DESIGN_AWAITING in text output
# (batch_size=0, skipped_design_awaiting=1).
test_da1_design_awaiting_skipped_text() {
    local _repo
    _repo=$(mktemp -d)
    _CLEANUP_DIRS+=("$_repo")
    _setup_fake_repo "$_repo"

    cat > "$_repo/scripts/ticket" << 'DA1_TICKET'
#!/usr/bin/env bash
SUBCMD="${1:-}"; shift || true; TICKET_ID="${1:-}"
case "$SUBCMD" in
    show)
        if [[ "$TICKET_ID" == "da1-epic" ]]; then
            echo '{"ticket_id":"da1-epic","status":"open","ticket_type":"epic","priority":1,"title":"Design Filter Epic","parent_id":null,"comments":[],"deps":[],"tags":[]}'
        elif [[ "$TICKET_ID" == "da1-story" ]]; then
            echo '{"ticket_id":"da1-story","status":"open","ticket_type":"story","priority":2,"title":"Story awaiting import","parent_id":"da1-epic","comments":[],"deps":[],"tags":["design:awaiting_import"]}'
        elif [[ "$TICKET_ID" == "da1-task" ]]; then
            echo '{"ticket_id":"da1-task","status":"open","ticket_type":"task","priority":3,"title":"Task under awaiting story","parent_id":"da1-story","comments":[],"deps":[],"tags":[]}'
        else
            echo '{"status":"error","error":"not found","ticket_id":"'"$TICKET_ID"'"}'; exit 1
        fi; exit 0 ;;
    list)
        echo '[{"ticket_id":"da1-story","status":"open","ticket_type":"story","priority":2,"title":"Story awaiting import","parent_id":"da1-epic","deps":[],"tags":["design:awaiting_import"]},{"ticket_id":"da1-task","status":"open","ticket_type":"task","priority":3,"title":"Task under awaiting story","parent_id":"da1-story","deps":[],"tags":[]}]'
        exit 0 ;;
    *) exit 0 ;;
esac
DA1_TICKET
    chmod +x "$_repo/scripts/ticket"

    local _exit=0
    local _output
    _output=$(cd "$_repo" && TICKET_CMD="$_repo/scripts/ticket" bash "$_repo/scripts/sprint-next-batch.sh" "da1-epic" 2>/dev/null) || _exit=$?

    # RED assertion: SKIPPED_DESIGN_AWAITING must appear in text output.
    [ "$_exit" -eq 0 ] && echo "$_output" | grep -q "SKIPPED_DESIGN_AWAITING"
}
echo "Test DA-1: Task under design:awaiting_import story appears as SKIPPED_DESIGN_AWAITING"
if test_da1_design_awaiting_skipped_text; then
    echo "  PASS: SKIPPED_DESIGN_AWAITING found in text output"
    (( PASS++ ))
else
    echo "  FAIL: test_da1_design_awaiting_skipped_text" >&2
    (( FAIL++ ))
fi

# ── Test DA-2: JSON output contains skipped_design_awaiting list ─────────────
# Same scenario as DA-1 but checks the --json output key.
test_da2_design_awaiting_json_key() {
    local _repo
    _repo=$(mktemp -d)
    _CLEANUP_DIRS+=("$_repo")
    _setup_fake_repo "$_repo"

    cat > "$_repo/scripts/ticket" << 'DA2_TICKET'
#!/usr/bin/env bash
SUBCMD="${1:-}"; shift || true; TICKET_ID="${1:-}"
case "$SUBCMD" in
    show)
        if [[ "$TICKET_ID" == "da2-epic" ]]; then
            echo '{"ticket_id":"da2-epic","status":"open","ticket_type":"epic","priority":1,"title":"Design Filter Epic","parent_id":null,"comments":[],"deps":[],"tags":[]}'
        elif [[ "$TICKET_ID" == "da2-story" ]]; then
            echo '{"ticket_id":"da2-story","status":"open","ticket_type":"story","priority":2,"title":"Story awaiting import","parent_id":"da2-epic","comments":[],"deps":[],"tags":["design:awaiting_import"]}'
        elif [[ "$TICKET_ID" == "da2-task" ]]; then
            echo '{"ticket_id":"da2-task","status":"open","ticket_type":"task","priority":3,"title":"Task under awaiting story","parent_id":"da2-story","comments":[],"deps":[],"tags":[]}'
        else
            echo '{"status":"error","error":"not found","ticket_id":"'"$TICKET_ID"'"}'; exit 1
        fi; exit 0 ;;
    list)
        echo '[{"ticket_id":"da2-story","status":"open","ticket_type":"story","priority":2,"title":"Story awaiting import","parent_id":"da2-epic","deps":[],"tags":["design:awaiting_import"]},{"ticket_id":"da2-task","status":"open","ticket_type":"task","priority":3,"title":"Task under awaiting story","parent_id":"da2-story","deps":[],"tags":[]}]'
        exit 0 ;;
    *) exit 0 ;;
esac
DA2_TICKET
    chmod +x "$_repo/scripts/ticket"

    local _exit=0
    local _output
    _output=$(cd "$_repo" && TICKET_CMD="$_repo/scripts/ticket" bash "$_repo/scripts/sprint-next-batch.sh" "da2-epic" --json 2>/dev/null) || _exit=$?

    local _skipped _batch
    _skipped=$(echo "$_output" | python3 -c "import sys,json; d=json.load(sys.stdin); print(len(d.get('skipped_design_awaiting',[])))" 2>/dev/null || echo "0")
    _batch=$(echo "$_output" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('batch_size',0))" 2>/dev/null || echo "-1")

    # RED: skipped_design_awaiting key must exist with 1 entry, batch_size=0
    [ "$_exit" -eq 0 ] && [ "$_skipped" -eq 1 ] && [ "$_batch" -eq 0 ]
}
echo "Test DA-2: design:awaiting_import task appears in JSON skipped_design_awaiting list"
if test_da2_design_awaiting_json_key; then
    echo "  PASS: JSON skipped_design_awaiting=1, batch_size=0"
    (( PASS++ ))
else
    echo "  FAIL: test_da2_design_awaiting_json_key" >&2
    (( FAIL++ ))
fi

# ── Test DA-5: SKIPPED_DESIGN_AWAITING output line format ────────────────────
# Validates the exact output line format: "SKIPPED_DESIGN_AWAITING: <id>  <reason>"
# RED test: currently FAILS because the script emits no such line.
test_da5_design_awaiting_line_format() {
    local _repo
    _repo=$(mktemp -d)
    _CLEANUP_DIRS+=("$_repo")
    _setup_fake_repo "$_repo"

    cat > "$_repo/scripts/ticket" << 'DA5_TICKET'
#!/usr/bin/env bash
SUBCMD="${1:-}"; shift || true; TICKET_ID="${1:-}"
case "$SUBCMD" in
    show)
        if [[ "$TICKET_ID" == "da5-epic" ]]; then
            echo '{"ticket_id":"da5-epic","status":"open","ticket_type":"epic","priority":1,"title":"Design Filter Epic","parent_id":null,"comments":[],"deps":[],"tags":[]}'
        elif [[ "$TICKET_ID" == "da5-story" ]]; then
            echo '{"ticket_id":"da5-story","status":"open","ticket_type":"story","priority":2,"title":"Story awaiting import","parent_id":"da5-epic","comments":[],"deps":[],"tags":["design:awaiting_import"]}'
        elif [[ "$TICKET_ID" == "da5-task" ]]; then
            echo '{"ticket_id":"da5-task","status":"open","ticket_type":"task","priority":3,"title":"Task awaiting design","parent_id":"da5-story","comments":[],"deps":[],"tags":[]}'
        else
            echo '{"status":"error","error":"not found","ticket_id":"'"$TICKET_ID"'"}'; exit 1
        fi; exit 0 ;;
    list)
        echo '[{"ticket_id":"da5-story","status":"open","ticket_type":"story","priority":2,"title":"Story awaiting import","parent_id":"da5-epic","deps":[],"tags":["design:awaiting_import"]},{"ticket_id":"da5-task","status":"open","ticket_type":"task","priority":3,"title":"Task awaiting design","parent_id":"da5-story","deps":[],"tags":[]}]'
        exit 0 ;;
    *) exit 0 ;;
esac
DA5_TICKET
    chmod +x "$_repo/scripts/ticket"

    local _exit=0
    local _output
    _output=$(cd "$_repo" && TICKET_CMD="$_repo/scripts/ticket" bash "$_repo/scripts/sprint-next-batch.sh" "da5-epic" 2>/dev/null) || _exit=$?

    # Expected line format: "SKIPPED_DESIGN_AWAITING: <id>\t<reason>"
    [ "$_exit" -eq 0 ] && echo "$_output" | grep -qE "^SKIPPED_DESIGN_AWAITING: da5-task"
}
echo "Test DA-5: SKIPPED_DESIGN_AWAITING output line contains task id"
if test_da5_design_awaiting_line_format; then
    echo "  PASS: SKIPPED_DESIGN_AWAITING line contains da5-task id"
    (( PASS++ ))
else
    echo "  FAIL: test_da5_design_awaiting_line_format" >&2
    (( FAIL++ ))
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
exit 0
