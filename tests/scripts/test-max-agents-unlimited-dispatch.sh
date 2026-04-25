#!/usr/bin/env bash
# shellcheck disable=SC2154  # _repo_dir set indirectly via eval inside _build_ten_task_repo
# tests/scripts/test-max-agents-unlimited-dispatch.sh
# GREEN test: 10-agent concurrent dispatch with MAX_AGENTS unlimited.
#
# Behavioral contract under test:
#   With --limit=unlimited and 10 independent non-opus tasks, sprint-next-batch.sh
#   must dispatch all 10 tasks in a single batch with no intervening cap truncation.
#
#   Observable assertions:
#     - Exit code 0 (batch generated successfully)
#     - BATCH_SIZE: 10 in stdout
#     - Exactly 10 TASK: lines in stdout
#     - Zero SKIPPED_OPUS_CAP: lines (all tasks are non-opus/sonnet)
#
# This test PASSES after implementation of --limit=unlimited support.
# Usage: bash tests/scripts/test-max-agents-unlimited-dispatch.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DSO_PLUGIN_DIR="$PLUGIN_ROOT/plugins/dso"
PLUGIN_SCRIPT="$DSO_PLUGIN_DIR/scripts/sprint-next-batch.sh"

source "$SCRIPT_DIR/../lib/assert.sh"

echo "=== test-max-agents-unlimited-dispatch.sh ==="

# ── Cleanup registry ─────────────────────────────────────────────────────────
_TEST_TMPDIRS=()
_cleanup_tmpdirs() {
    for d in "${_TEST_TMPDIRS[@]+"${_TEST_TMPDIRS[@]}"}"; do
        rm -rf "$d"
    done
}
trap '_cleanup_tmpdirs' EXIT

# ── Shared fixture builder ────────────────────────────────────────────────────
# Creates an isolated fake git repo with 10 open tasks under a test epic.
# All tasks are independent (no deps, no file overlap) and classified as
# model=sonnet so opus-cap and conflict filtering are not triggered.
#
# Usage: _build_ten_task_repo <varname_for_dir>
_build_ten_task_repo() {
    local _var="$1"
    local _dir
    _dir=$(mktemp -d)
    _TEST_TMPDIRS+=("$_dir")
    git init -q -b main "$_dir"
    mkdir -p "$_dir/scripts"

    # Mock ticket CLI: returns 1 epic + 10 open independent tasks
    cat > "$_dir/scripts/ticket" << 'TICKET_STUB'
#!/usr/bin/env bash
SUBCMD="${1:-}"; shift || true; TICKET_ID="${1:-}"
case "$SUBCMD" in
    show)
        if [[ "$TICKET_ID" == "ma-epic" ]]; then
            echo '{"ticket_id":"ma-epic","status":"open","ticket_type":"epic","priority":1,"title":"Max Agents Unlimited Test Epic","parent_id":null,"comments":[],"deps":[]}'
        else
            echo '{"status":"error","error":"not found","ticket_id":"'"$TICKET_ID"'"}'; exit 1
        fi
        exit 0 ;;
    list)
        echo '[
          {"ticket_id":"ma-t01","status":"open","ticket_type":"task","priority":2,"title":"Task 01","parent_id":"ma-epic","deps":[]},
          {"ticket_id":"ma-t02","status":"open","ticket_type":"task","priority":2,"title":"Task 02","parent_id":"ma-epic","deps":[]},
          {"ticket_id":"ma-t03","status":"open","ticket_type":"task","priority":2,"title":"Task 03","parent_id":"ma-epic","deps":[]},
          {"ticket_id":"ma-t04","status":"open","ticket_type":"task","priority":2,"title":"Task 04","parent_id":"ma-epic","deps":[]},
          {"ticket_id":"ma-t05","status":"open","ticket_type":"task","priority":2,"title":"Task 05","parent_id":"ma-epic","deps":[]},
          {"ticket_id":"ma-t06","status":"open","ticket_type":"task","priority":2,"title":"Task 06","parent_id":"ma-epic","deps":[]},
          {"ticket_id":"ma-t07","status":"open","ticket_type":"task","priority":2,"title":"Task 07","parent_id":"ma-epic","deps":[]},
          {"ticket_id":"ma-t08","status":"open","ticket_type":"task","priority":2,"title":"Task 08","parent_id":"ma-epic","deps":[]},
          {"ticket_id":"ma-t09","status":"open","ticket_type":"task","priority":2,"title":"Task 09","parent_id":"ma-epic","deps":[]},
          {"ticket_id":"ma-t10","status":"open","ticket_type":"task","priority":2,"title":"Task 10","parent_id":"ma-epic","deps":[]}
        ]'
        exit 0 ;;
    *) exit 0 ;;
esac
TICKET_STUB
    chmod +x "$_dir/scripts/ticket"

    # Scorer: all 10 tasks classified as independent/sonnet — no opus-cap deferrals
    # Each task gets a unique file path to prevent overlap filtering.
    cat > "$_dir/scripts/classify-task.py" << 'SCORER_STUB'
import json, sys
tasks = json.loads(sys.stdin.read())
out = [{"id": t.get("id", t.get("ticket_id", "")),
        "priority": 2, "class": "independent",
        "subagent": "general-purpose", "model": "sonnet",
        "complexity": "low", "reason": "stub"} for t in tasks]
print(json.dumps(out))
SCORER_STUB

    # Minimal read-config.sh stub — no special config caps
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

    eval "${_var}=\"$_dir\""
}

# ── Helper: count lines starting with prefix ─────────────────────────────────
_count_prefixed_lines() {
    local prefix="$1" output="$2"
    printf '%s\n' "$output" | grep -c "^${prefix}" || true
}

# ── Helper: extract BATCH_SIZE value ────────────────────────────────────────
_extract_batch_size() {
    local output="$1"
    printf '%s\n' "$output" | grep '^BATCH_SIZE:' | awk '{print $2}' | head -1
}

# ── test_ten_agent_unlimited_dispatch ────────────────────────────────────────
# With --limit=unlimited and a pool of 10 independent sonnet tasks, the script
# must return all 10 tasks in one batch with no SKIPPED_OPUS_CAP truncation.
#
# Observable behavior:
#   - Exit code 0 (batch generated)
#   - BATCH_SIZE: 10
#   - Exactly 10 TASK: lines
#   - Zero SKIPPED_OPUS_CAP: lines

_snapshot_fail
_build_ten_task_repo _repo_dir

_exit_code=0
_output=$(
    cd "$_repo_dir" && \
    TICKET_CMD="$_repo_dir/scripts/ticket" \
    bash "$_repo_dir/scripts/sprint-next-batch.sh" "ma-epic" --limit=unlimited 2>&1
) || _exit_code=$?

_task_count=$(_count_prefixed_lines "TASK:" "$_output")
_batch_size=$(_extract_batch_size "$_output")
_opus_cap_count=$(_count_prefixed_lines "SKIPPED_OPUS_CAP:" "$_output")

assert_eq "ten_agent_dispatch: exit code 0" "0" "$_exit_code"
assert_eq "ten_agent_dispatch: BATCH_SIZE is 10" "10" "${_batch_size:-none}"
assert_eq "ten_agent_dispatch: exactly 10 TASK: lines" "10" "$_task_count"
assert_eq "ten_agent_dispatch: no SKIPPED_OPUS_CAP lines" "0" "$_opus_cap_count"

assert_pass_if_clean "test_ten_agent_unlimited_dispatch"

print_summary
