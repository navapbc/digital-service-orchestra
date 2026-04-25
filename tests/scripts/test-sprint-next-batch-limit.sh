#!/usr/bin/env bash
# shellcheck disable=SC2154  # _t{u,z,p,o}_dir set indirectly via eval inside _build_fake_repo
# tests/scripts/test-sprint-next-batch-limit.sh
# RED tests for sprint-next-batch.sh --limit parameter edge cases:
#   - --limit=unlimited  → full pool returned (no cap applied)
#   - --limit=0          → BATCH_SIZE: 0 immediately, no TASK: lines
#   - --limit=3          → caps batch to 3 (regression guard)
#   - (no --limit)       → full pool returned (unlimited default)
#
# Tests for unlimited and 0 are RED: they FAIL before implementation.
# Tests for positive integer and omitted are GREEN regression guards.
#
# Usage: bash tests/scripts/test-sprint-next-batch-limit.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DSO_PLUGIN_DIR="$PLUGIN_ROOT/plugins/dso"
PLUGIN_SCRIPT="$DSO_PLUGIN_DIR/scripts/sprint-next-batch.sh"

source "$SCRIPT_DIR/../lib/run_test.sh"

_CLEANUP_DIRS=()
_cleanup() { for d in "${_CLEANUP_DIRS[@]+"${_CLEANUP_DIRS[@]}"}"; do rm -rf "$d"; done; }
trap _cleanup EXIT

echo "=== test-sprint-next-batch-limit.sh ==="

# ---------------------------------------------------------------------------
# Shared scaffold builder.
# Creates an isolated fake git repo with 5 open tasks under a test epic.
# The classify-task.py stub marks all tasks as independent/sonnet so none
# are deferred by opus-cap or conflict filtering — the pool is exactly 5.
#
# Usage: _build_fake_repo <varname_for_dir>
# Sets the named variable to the path of the fake repo dir.
# ---------------------------------------------------------------------------
_build_fake_repo() {
    local _var="$1"
    local _dir
    _dir=$(mktemp -d)
    _CLEANUP_DIRS+=("$_dir")
    git init -q -b main "$_dir"
    mkdir -p "$_dir/scripts"

    # Mock ticket CLI: returns 1 epic + 5 open tasks
    cat > "$_dir/scripts/ticket" << 'TICKET_STUB'
#!/usr/bin/env bash
SUBCMD="${1:-}"; shift || true; TICKET_ID="${1:-}"
case "$SUBCMD" in
    show)
        if [[ "$TICKET_ID" == "lim-epic" ]]; then
            echo '{"ticket_id":"lim-epic","status":"open","ticket_type":"epic","priority":1,"title":"Limit Test Epic","parent_id":null,"comments":[],"deps":[]}'
        else
            echo '{"status":"error","error":"not found","ticket_id":"'"$TICKET_ID"'"}'; exit 1
        fi
        exit 0 ;;
    list)
        echo '[
          {"ticket_id":"lim-t1","status":"open","ticket_type":"task","priority":2,"title":"Task 1","parent_id":"lim-epic","deps":[]},
          {"ticket_id":"lim-t2","status":"open","ticket_type":"task","priority":2,"title":"Task 2","parent_id":"lim-epic","deps":[]},
          {"ticket_id":"lim-t3","status":"open","ticket_type":"task","priority":2,"title":"Task 3","parent_id":"lim-epic","deps":[]},
          {"ticket_id":"lim-t4","status":"open","ticket_type":"task","priority":2,"title":"Task 4","parent_id":"lim-epic","deps":[]},
          {"ticket_id":"lim-t5","status":"open","ticket_type":"task","priority":2,"title":"Task 5","parent_id":"lim-epic","deps":[]}
        ]'
        exit 0 ;;
    *) exit 0 ;;
esac
TICKET_STUB
    chmod +x "$_dir/scripts/ticket"

    # Scorer: all tasks classified as independent/sonnet — no opus-cap deferrals
    cat > "$_dir/scripts/classify-task.py" << 'SCORER_STUB'
import json, sys
tasks = json.loads(sys.stdin.read())
out = [{"id": t.get("id", t.get("ticket_id", "")),
        "priority": 2, "class": "independent",
        "subagent": "general-purpose", "model": "sonnet",
        "complexity": "low", "reason": "stub"} for t in tasks]
print(json.dumps(out))
SCORER_STUB

    # Minimal read-config.sh stub
    cat > "$_dir/scripts/read-config.sh" << 'CFG_STUB'
#!/usr/bin/env bash
KEY="${1:-}"; if [[ "$KEY" == "--list" ]]; then KEY="${2:-}"; fi
case "$KEY" in
    paths.src_dir)       echo -n "src" ;;
    paths.test_dir)      echo -n "tests" ;;
    paths.test_unit_dir) echo -n "tests/unit" ;;
    interpreter.python_venv) echo -n "" ;;
    *) echo -n "" ;;
esac
CFG_STUB
    chmod +x "$_dir/scripts/read-config.sh"

    printf '' > "$_dir/dso-config.conf"

    cp "$PLUGIN_SCRIPT" "$_dir/scripts/sprint-next-batch.sh"
    chmod +x "$_dir/scripts/sprint-next-batch.sh"
    cp "$DSO_PLUGIN_DIR/scripts/ticket-next-batch.sh" "$_dir/scripts/ticket-next-batch.sh"

    # Return the dir path via the named variable
    eval "${_var}=\"$_dir\""
}

# Helper: count TASK: lines in output
_count_task_lines() {
    local output="$1"
    echo "$output" | grep -c '^TASK:' || true
}

# Helper: extract BATCH_SIZE value from output
_extract_batch_size() {
    local output="$1"
    echo "$output" | grep '^BATCH_SIZE:' | awk '{print $2}' | head -1
}

# ---------------------------------------------------------------------------
# test_limit_unlimited
# --limit=unlimited must be accepted (exit 0) and return the full pool of 5
# tasks with no cap applied. BATCH_SIZE must be > 0 (not an error sentinel).
#
# RED: currently the script rejects "unlimited" as non-numeric and exits 2.
# ---------------------------------------------------------------------------
echo "Test: test_limit_unlimited — --limit=unlimited returns full pool (RED)"
_build_fake_repo _tu_dir
_tu_exit=0
_tu_output=$(
    cd "$_tu_dir" && \
    TICKET_CMD="$_tu_dir/scripts/ticket" \
    bash "$_tu_dir/scripts/sprint-next-batch.sh" "lim-epic" --limit=unlimited 2>&1
) || _tu_exit=$?

_tu_task_count=$(_count_task_lines "$_tu_output")
_tu_batch_size=$(_extract_batch_size "$_tu_output")

# Assert: must exit 0 (accepted as valid flag)
if [ "$_tu_exit" -ne 0 ]; then
    echo "  FAIL: test_limit_unlimited — expected exit 0, got $_tu_exit" >&2
    (( FAIL++ ))
# Assert: BATCH_SIZE must reflect the full pool (5 tasks available, none capped)
elif [ "${_tu_batch_size:-0}" -lt 1 ]; then
    echo "  FAIL: test_limit_unlimited — BATCH_SIZE should be >= 1 (full pool), got '${_tu_batch_size:-none}'" >&2
    (( FAIL++ ))
# Assert: TASK: lines must be present (full pool, not zero)
elif [ "${_tu_task_count:-0}" -lt 1 ]; then
    echo "  FAIL: test_limit_unlimited — expected TASK: lines in output, found none" >&2
    (( FAIL++ ))
else
    echo "  PASS: test_limit_unlimited"
    (( PASS++ ))
fi

# ---------------------------------------------------------------------------
# test_limit_zero
# --limit=0 must return BATCH_SIZE: 0 immediately with NO TASK: lines.
# Zero is now a "return empty batch" sentinel, not an "unlimited" alias.
#
# RED: currently the script treats 0 as unlimited (returns full pool of 5).
# ---------------------------------------------------------------------------
echo "Test: test_limit_zero — --limit=0 returns BATCH_SIZE: 0 with no TASK: lines (RED)"
_build_fake_repo _tz_dir
_tz_exit=0
_tz_output=$(
    cd "$_tz_dir" && \
    TICKET_CMD="$_tz_dir/scripts/ticket" \
    bash "$_tz_dir/scripts/sprint-next-batch.sh" "lim-epic" --limit=0 2>&1
) || _tz_exit=$?

_tz_task_count=$(_count_task_lines "$_tz_output")
_tz_batch_size=$(_extract_batch_size "$_tz_output")

# Assert: must exit 0 (0 is a valid limit meaning "empty batch")
if [ "$_tz_exit" -ne 0 ]; then
    echo "  FAIL: test_limit_zero — expected exit 0, got $_tz_exit" >&2
    (( FAIL++ ))
# Assert: BATCH_SIZE must be exactly 0
elif [ "${_tz_batch_size:-x}" != "0" ]; then
    echo "  FAIL: test_limit_zero — expected BATCH_SIZE: 0, got '${_tz_batch_size:-none}'" >&2
    (( FAIL++ ))
# Assert: no TASK: lines may appear
elif [ "${_tz_task_count:-0}" -gt 0 ]; then
    echo "  FAIL: test_limit_zero — expected no TASK: lines, found ${_tz_task_count}" >&2
    (( FAIL++ ))
else
    echo "  PASS: test_limit_zero"
    (( PASS++ ))
fi

# ---------------------------------------------------------------------------
# test_limit_positive
# --limit=3 must cap the batch to exactly 3 tasks from the pool of 5.
# This is a regression guard — existing behavior must be preserved.
#
# GREEN (should already pass before implementation).
# ---------------------------------------------------------------------------
echo "Test: test_limit_positive — --limit=3 caps batch to 3 tasks (regression guard)"
_build_fake_repo _tp_dir
_tp_exit=0
_tp_output=$(
    cd "$_tp_dir" && \
    TICKET_CMD="$_tp_dir/scripts/ticket" \
    bash "$_tp_dir/scripts/sprint-next-batch.sh" "lim-epic" --limit=3 2>&1
) || _tp_exit=$?

_tp_task_count=$(_count_task_lines "$_tp_output")
_tp_batch_size=$(_extract_batch_size "$_tp_output")

# Assert: must exit 0
if [ "$_tp_exit" -ne 0 ]; then
    echo "  FAIL: test_limit_positive — expected exit 0, got $_tp_exit" >&2
    (( FAIL++ ))
# Assert: BATCH_SIZE must be 3 (capped)
elif [ "${_tp_batch_size:-x}" != "3" ]; then
    echo "  FAIL: test_limit_positive — expected BATCH_SIZE: 3, got '${_tp_batch_size:-none}'" >&2
    (( FAIL++ ))
# Assert: exactly 3 TASK: lines
elif [ "${_tp_task_count:-0}" -ne 3 ]; then
    echo "  FAIL: test_limit_positive — expected 3 TASK: lines, found ${_tp_task_count}" >&2
    (( FAIL++ ))
else
    echo "  PASS: test_limit_positive"
    (( PASS++ ))
fi

# ---------------------------------------------------------------------------
# test_limit_omitted
# Omitting --limit must return the full pool (5 tasks) — same as unlimited.
# This is a regression guard — existing default behavior must be preserved.
#
# GREEN (should already pass before implementation).
# ---------------------------------------------------------------------------
echo "Test: test_limit_omitted — no --limit returns full pool (regression guard)"
_build_fake_repo _to_dir
_to_exit=0
_to_output=$(
    cd "$_to_dir" && \
    TICKET_CMD="$_to_dir/scripts/ticket" \
    bash "$_to_dir/scripts/sprint-next-batch.sh" "lim-epic" 2>&1
) || _to_exit=$?

_to_task_count=$(_count_task_lines "$_to_output")
_to_batch_size=$(_extract_batch_size "$_to_output")

# Assert: must exit 0
if [ "$_to_exit" -ne 0 ]; then
    echo "  FAIL: test_limit_omitted — expected exit 0, got $_to_exit" >&2
    (( FAIL++ ))
# Assert: full pool (5 tasks) returned; BATCH_SIZE >= 1
elif [ "${_to_batch_size:-0}" -lt 1 ]; then
    echo "  FAIL: test_limit_omitted — expected BATCH_SIZE >= 1, got '${_to_batch_size:-none}'" >&2
    (( FAIL++ ))
# Assert: all 5 tasks appear as TASK: lines
elif [ "${_to_task_count:-0}" -lt 5 ]; then
    echo "  FAIL: test_limit_omitted — expected 5 TASK: lines (full pool), found ${_to_task_count}" >&2
    (( FAIL++ ))
else
    echo "  PASS: test_limit_omitted"
    (( PASS++ ))
fi

print_results
