#!/usr/bin/env bash
# tests/test-sprint-next-batch.sh
# RED tests: verify sprint-next-batch.sh generalized awaiting_* filter.
#
# Tests:
#   1. test_sprint_next_batch_skips_manual_awaiting_user_story
#      RED — manual:awaiting_user filter does NOT exist yet (task 28ad-3d65)
#   2. test_sprint_next_batch_includes_manual_story_when_flag_off
#      GREEN — baseline behavior (flag off = no filter) already works
#   3. test_sprint_next_batch_generalized_predicate_catches_design_awaiting_import
#      GREEN — design:awaiting_import filter already exists (regression check)
#
# Test 1 MUST FAIL (RED) until task 28ad-3d65 adds the implementation.
# Tests 2 and 3 MUST PASS (baseline and existing behavior).
#
# Usage: bash tests/test-sprint-next-batch.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"
PLUGIN_SCRIPT="$REPO_ROOT/plugins/dso/scripts/sprint-next-batch.sh"

: "${PASS:=0}"
: "${FAIL:=0}"

# Temp dir cleanup on exit
_CLEANUP_DIRS=()
# shellcheck disable=SC2329
_cleanup() { for d in "${_CLEANUP_DIRS[@]:-}"; do rm -rf "$d"; done; }
trap _cleanup EXIT

echo "=== test-sprint-next-batch.sh ==="

# ── Shared helper: build a minimal fake repo ───────────────────────────────────
# Sets up scripts/ticket, scripts/classify-task.py, scripts/read-config.sh,
# .claude/dso-config.conf, and copies sprint-next-batch.sh.
_setup_fake_repo() {
    local repo_dir="$1"
    local flag_enabled="${2:-false}"  # planning.external_dependency_block_enabled value

    git init -q -b main "$repo_dir"
    mkdir -p "$repo_dir/scripts"
    mkdir -p "$repo_dir/.claude"

    # Write dso-config.conf with the flag setting
    if [[ "$flag_enabled" == "true" ]]; then
        printf 'planning.external_dependency_block_enabled=true\n' > "$repo_dir/.claude/dso-config.conf"
    else
        printf '' > "$repo_dir/.claude/dso-config.conf"
    fi

    # classify-task.py stub — labels everything "independent/sonnet"
    cat > "$repo_dir/scripts/classify-task.py" << 'SCORER'
import json, sys
tasks = json.loads(sys.stdin.read())
out = [{"id": t.get("id",""), "priority": 2, "class": "independent",
        "subagent": "general-purpose", "model": "sonnet",
        "complexity": "low", "reason": "stub"} for t in tasks]
print(json.dumps(out))
SCORER

    # read-config.sh stub — returns the configured flag value for the planning key
    cat > "$repo_dir/scripts/read-config.sh" << CFGEOF
#!/usr/bin/env bash
KEY="\${1:-}"; if [[ "\$KEY" == "--list" ]]; then KEY="\${2:-}"; fi
case "\$KEY" in
    paths.src_dir) echo -n "src" ;;
    paths.test_dir) echo -n "tests" ;;
    paths.test_unit_dir) echo -n "tests/unit" ;;
    interpreter.python_venv) echo -n "" ;;
    planning.external_dependency_block_enabled) echo -n "${flag_enabled}" ;;
    *) echo -n "" ;;
esac
CFGEOF
    chmod +x "$repo_dir/scripts/read-config.sh"

    cp "$PLUGIN_SCRIPT" "$repo_dir/scripts/sprint-next-batch.sh"
    chmod +x "$repo_dir/scripts/sprint-next-batch.sh"
}

# ── Test 1: manual:awaiting_user story causes task to be SKIPPED (flag=true) ──
# RED test — manual:awaiting_user filter does NOT exist yet (task 28ad-3d65).
# Expected: output contains "SKIPPED_MANUAL_AWAITING:" and does NOT contain
# "TASK: ma1-task" when planning.external_dependency_block_enabled=true.
test_sprint_next_batch_skips_manual_awaiting_user_story() {
    local _repo
    _repo=$(mktemp -d)
    _CLEANUP_DIRS+=("$_repo")
    _setup_fake_repo "$_repo" "true"

    cat > "$_repo/scripts/ticket" << 'MA1_TICKET'
#!/usr/bin/env bash
SUBCMD="${1:-}"; shift || true; TICKET_ID="${1:-}"
case "$SUBCMD" in
    show)
        if [[ "$TICKET_ID" == "ma1-epic" ]]; then
            echo '{"ticket_id":"ma1-epic","status":"open","ticket_type":"epic","priority":1,"title":"Manual Awaiting Epic","parent_id":null,"comments":[],"deps":[],"tags":[]}'
        elif [[ "$TICKET_ID" == "ma1-story" ]]; then
            echo '{"ticket_id":"ma1-story","status":"open","ticket_type":"story","priority":2,"title":"Story awaiting user","parent_id":"ma1-epic","comments":[],"deps":[],"tags":["manual:awaiting_user"]}'
        elif [[ "$TICKET_ID" == "ma1-task" ]]; then
            echo '{"ticket_id":"ma1-task","status":"open","ticket_type":"task","priority":3,"title":"Task blocked by manual step","parent_id":"ma1-story","comments":[],"deps":[],"tags":[]}'
        else
            echo '{"status":"error","error":"not found","ticket_id":"'"$TICKET_ID"'"}'; exit 1
        fi; exit 0 ;;
    list)
        echo '[{"ticket_id":"ma1-story","status":"open","ticket_type":"story","priority":2,"title":"Story awaiting user","parent_id":"ma1-epic","deps":[],"tags":["manual:awaiting_user"]},{"ticket_id":"ma1-task","status":"open","ticket_type":"task","priority":3,"title":"Task blocked by manual step","parent_id":"ma1-story","deps":[],"tags":[]}]'
        exit 0 ;;
    *) exit 0 ;;
esac
MA1_TICKET
    chmod +x "$_repo/scripts/ticket"

    local _exit=0
    local _output
    _output=$(cd "$_repo" && TICKET_CMD="$_repo/scripts/ticket" bash "$_repo/scripts/sprint-next-batch.sh" "ma1-epic" 2>/dev/null) || _exit=$?

    # RED assertions: SKIPPED_MANUAL_AWAITING must appear, TASK: ma1-task must NOT appear
    [ "$_exit" -eq 0 ] \
        && echo "$_output" | grep -q "SKIPPED_MANUAL_AWAITING:" \
        && ! echo "$_output" | grep -q "TASK:.*ma1-task"
}

echo "Test 1: task under manual:awaiting_user story is SKIPPED_MANUAL_AWAITING (flag=true)"
if test_sprint_next_batch_skips_manual_awaiting_user_story; then
    echo "  PASS: SKIPPED_MANUAL_AWAITING found, TASK: ma1-task absent"
    (( PASS++ ))
else
    echo "  FAIL: test_sprint_next_batch_skips_manual_awaiting_user_story (RED — implementation not yet added)" >&2
    (( FAIL++ ))
fi

# ── Test 2: manual:awaiting_user story does NOT skip task when flag=false ──────
# GREEN — baseline behavior: no manual filter when flag is absent/false.
# Expected: output contains "TASK: ma2-task" (task is not skipped).
test_sprint_next_batch_includes_manual_story_when_flag_off() {
    local _repo
    _repo=$(mktemp -d)
    _CLEANUP_DIRS+=("$_repo")
    _setup_fake_repo "$_repo" "false"  # flag absent/false

    cat > "$_repo/scripts/ticket" << 'MA2_TICKET'
#!/usr/bin/env bash
SUBCMD="${1:-}"; shift || true; TICKET_ID="${1:-}"
case "$SUBCMD" in
    show)
        if [[ "$TICKET_ID" == "ma2-epic" ]]; then
            echo '{"ticket_id":"ma2-epic","status":"open","ticket_type":"epic","priority":1,"title":"Manual Flag Off Epic","parent_id":null,"comments":[],"deps":[],"tags":[]}'
        elif [[ "$TICKET_ID" == "ma2-story" ]]; then
            echo '{"ticket_id":"ma2-story","status":"open","ticket_type":"story","priority":2,"title":"Story with manual tag but flag off","parent_id":"ma2-epic","comments":[],"deps":[],"tags":["manual:awaiting_user"]}'
        elif [[ "$TICKET_ID" == "ma2-task" ]]; then
            echo '{"ticket_id":"ma2-task","status":"open","ticket_type":"task","priority":3,"title":"Task under manual story (flag off)","parent_id":"ma2-story","comments":[],"deps":[],"tags":[]}'
        else
            echo '{"status":"error","error":"not found","ticket_id":"'"$TICKET_ID"'"}'; exit 1
        fi; exit 0 ;;
    list)
        echo '[{"ticket_id":"ma2-story","status":"open","ticket_type":"story","priority":2,"title":"Story with manual tag but flag off","parent_id":"ma2-epic","deps":[],"tags":["manual:awaiting_user"]},{"ticket_id":"ma2-task","status":"open","ticket_type":"task","priority":3,"title":"Task under manual story (flag off)","parent_id":"ma2-story","deps":[],"tags":[]}]'
        exit 0 ;;
    *) exit 0 ;;
esac
MA2_TICKET
    chmod +x "$_repo/scripts/ticket"

    local _exit=0
    local _output
    _output=$(cd "$_repo" && TICKET_CMD="$_repo/scripts/ticket" bash "$_repo/scripts/sprint-next-batch.sh" "ma2-epic" 2>/dev/null) || _exit=$?

    # When flag is off, the task must appear in the batch (not skipped by manual filter).
    # GREEN: baseline behavior (no manual filter when flag=false) already works.
    # Contract: flag=false → no manual filter → task in batch.
    [ "$_exit" -eq 0 ] && echo "$_output" | grep -q "TASK:.*ma2-task"
}

echo "Test 2: task under manual:awaiting_user story is included when flag=false (baseline)"
if test_sprint_next_batch_includes_manual_story_when_flag_off; then
    echo "  PASS: TASK: ma2-task present (flag=false means no manual filter)"
    (( PASS++ ))
else
    echo "  FAIL: test_sprint_next_batch_includes_manual_story_when_flag_off (RED — flag-gate contract)" >&2
    (( FAIL++ ))
fi

# ── Test 3: design:awaiting_import regression ───────────────────────────────
# GREEN test — the design:awaiting_import filter already exists.
# Verifies the existing behavior is not broken when adding the manual filter.
# Expected: output contains "SKIPPED_DESIGN_AWAITING:" and does NOT contain
# "TASK: da3-task".
test_sprint_next_batch_generalized_predicate_catches_design_awaiting_import() {
    local _repo
    _repo=$(mktemp -d)
    _CLEANUP_DIRS+=("$_repo")
    _setup_fake_repo "$_repo" "true"

    cat > "$_repo/scripts/ticket" << 'DA3_TICKET'
#!/usr/bin/env bash
SUBCMD="${1:-}"; shift || true; TICKET_ID="${1:-}"
case "$SUBCMD" in
    show)
        if [[ "$TICKET_ID" == "da3-epic" ]]; then
            echo '{"ticket_id":"da3-epic","status":"open","ticket_type":"epic","priority":1,"title":"Design Regression Epic","parent_id":null,"comments":[],"deps":[],"tags":[]}'
        elif [[ "$TICKET_ID" == "da3-story" ]]; then
            echo '{"ticket_id":"da3-story","status":"open","ticket_type":"story","priority":2,"title":"Story awaiting design import","parent_id":"da3-epic","comments":[],"deps":[],"tags":["design:awaiting_import"]}'
        elif [[ "$TICKET_ID" == "da3-task" ]]; then
            echo '{"ticket_id":"da3-task","status":"open","ticket_type":"task","priority":3,"title":"Task under design-awaiting story","parent_id":"da3-story","comments":[],"deps":[],"tags":[]}'
        else
            echo '{"status":"error","error":"not found","ticket_id":"'"$TICKET_ID"'"}'; exit 1
        fi; exit 0 ;;
    list)
        echo '[{"ticket_id":"da3-story","status":"open","ticket_type":"story","priority":2,"title":"Story awaiting design import","parent_id":"da3-epic","deps":[],"tags":["design:awaiting_import"]},{"ticket_id":"da3-task","status":"open","ticket_type":"task","priority":3,"title":"Task under design-awaiting story","parent_id":"da3-story","deps":[],"tags":[]}]'
        exit 0 ;;
    *) exit 0 ;;
esac
DA3_TICKET
    chmod +x "$_repo/scripts/ticket"

    local _exit=0
    local _output
    _output=$(cd "$_repo" && TICKET_CMD="$_repo/scripts/ticket" bash "$_repo/scripts/sprint-next-batch.sh" "da3-epic" 2>/dev/null) || _exit=$?

    # GREEN assertion: existing design filter must produce SKIPPED_DESIGN_AWAITING
    [ "$_exit" -eq 0 ] \
        && echo "$_output" | grep -q "SKIPPED_DESIGN_AWAITING:" \
        && ! echo "$_output" | grep -q "TASK:.*da3-task"
}

echo "Test 3: design:awaiting_import task is SKIPPED_DESIGN_AWAITING (regression check)"
if test_sprint_next_batch_generalized_predicate_catches_design_awaiting_import; then
    echo "  PASS: SKIPPED_DESIGN_AWAITING found for design:awaiting_import (existing filter intact)"
    (( PASS++ ))
else
    echo "  FAIL: test_sprint_next_batch_generalized_predicate_catches_design_awaiting_import" >&2
    (( FAIL++ ))
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
exit 0
