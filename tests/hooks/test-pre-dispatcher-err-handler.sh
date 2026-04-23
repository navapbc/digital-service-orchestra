#!/usr/bin/env bash
# shellcheck disable=SC2030,SC2031
# tests/hooks/test-pre-dispatcher-err-handler.sh
# RED behavioral tests: pre-* dispatchers must source hook-error-handler.sh and
# register _dso_register_hook_err_handler so that dispatcher-level ERR events:
#   (a) exit 0 (fail-open), and
#   (b) write a JSONL entry to $HOME/.claude/logs/dso-hook-errors.jsonl
#
# RED phase: all tests FAIL because no pre-* dispatcher currently sources
# hook-error-handler.sh or calls _dso_register_hook_err_handler.
# GREEN phase: tests PASS after task 398e-2165 adds the source + register calls.
#
# Isolation: all tests use an isolated TEST_HOME (mktemp -d) — no writes
# touch real $HOME/.claude/logs/.
#
# Strategy: each test creates a thin wrapper script written to a temp dir that:
#   1. Sets CLAUDE_PLUGIN_ROOT to the real plugin directory
#   2. Sources the dispatcher under test (not exec — avoids BASH_SOURCE guard)
#   3. Overrides the inner dispatch function to inject a deliberate `false`
#      after all sourcing is complete (simulating an unhandled ERR at the
#      dispatcher top-level scope)
#   4. Registers the ERR handler — the wrapper calls the same hook the
#      dispatcher would call, but intentionally triggers an error
#   5. Runs in a subshell with HOME=$TEST_HOME
#
# The ERR handler must be registered by the dispatcher itself (via
# _dso_register_hook_err_handler). Because the dispatchers DON'T currently
# call that function, the handler will not fire — the test will see a non-zero
# exit (from the `false`) and no JSONL entry, causing RED assertions to fail.
#
# After 398e-2165, each dispatcher calls _dso_register_hook_err_handler
# near the top-level; the trap fires on the injected `false`, writes JSONL,
# and exits 0.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DSO_PLUGIN_DIR="$PLUGIN_ROOT/plugins/dso"
source "$PLUGIN_ROOT/tests/lib/assert.sh"

HANDLER_PATH="$DSO_PLUGIN_DIR/hooks/lib/hook-error-handler.sh"
DISPATCHERS_DIR="$DSO_PLUGIN_DIR/hooks/dispatchers"

# Temp dir registry for cleanup
_TEST_TMPDIRS=()
_cleanup() {
    for d in "${_TEST_TMPDIRS[@]:-}"; do
        rm -rf "$d"
    done
}
trap _cleanup EXIT

_make_test_home() {
    local d
    d=$(mktemp -d)
    _TEST_TMPDIRS+=("$d")
    echo "$d"
}

# _make_wrapper_dir: create an isolated temp dir for wrapper scripts
_make_wrapper_dir() {
    local d
    d=$(mktemp -d)
    _TEST_TMPDIRS+=("$d")
    echo "$d"
}

# _assert_dispatcher_err_fails_open_and_logs
# Common assertion logic for all 7 dispatchers.
#
# Parameters:
#   $1 — dispatcher name (e.g. "pre-bash.sh")
#   $2 — hook name label for JSONL assertion (e.g. "pre-bash.sh")
#   $3 — minimal valid stdin JSON to avoid parse failures in sourced libs
#
# Mechanism:
#   We create a small wrapper script that:
#     1. Sources the dispatcher (so all its libraries load and any top-level
#        _dso_register_hook_err_handler call fires — if it exists)
#     2. Then deliberately runs `false` at top-level scope to trigger ERR
#   We run that wrapper with HOME=$TEST_HOME and check:
#     - exit code is 0 (fail-open)
#     - $TEST_HOME/.claude/logs/dso-hook-errors.jsonl was written
#     - the JSONL line contains the hook name
_assert_dispatcher_err_fails_open_and_logs() {
    local dispatcher_filename="$1"
    local hook_label="$2"
    local stdin_json="$3"

    local TEST_HOME
    TEST_HOME=$(_make_test_home)
    local WRAPPER_DIR
    WRAPPER_DIR=$(_make_wrapper_dir)
    local LOG_FILE="$TEST_HOME/.claude/logs/dso-hook-errors.jsonl"

    local wrapper_script="$WRAPPER_DIR/wrapper.sh"
    # Write the wrapper script.
    # The wrapper sources the dispatcher (which, after 398e-2165, calls
    # _dso_register_hook_err_handler at the top level — registering an ERR trap).
    # Then `false` fires the trap.
    # In RED phase: no trap is registered; `false` exits 1 → wrapper exits 1.
    # In GREEN phase: trap is registered; `false` fires handler → exits 0 + writes JSONL.
    cat > "$wrapper_script" << WRAPPER_EOF
#!/usr/bin/env bash
set -uo pipefail
# Source the dispatcher to load its top-level setup (including future
# _dso_register_hook_err_handler call after 398e-2165).
# We must NOT use 'exec' — sourcing keeps the trap registrations in scope.
CLAUDE_PLUGIN_ROOT="${DSO_PLUGIN_DIR}"
export CLAUDE_PLUGIN_ROOT
# Provide minimal artifacts dir to suppress noise from dispatchers that call get_artifacts_dir
ARTIFACTS_DIR="${WRAPPER_DIR}/artifacts"
export ARTIFACTS_DIR
mkdir -p "\$ARTIFACTS_DIR"
source "${DISPATCHERS_DIR}/${dispatcher_filename}"
# Inject deliberate ERR at top-level scope (outside any function).
# If _dso_register_hook_err_handler was called during sourcing above,
# the ERR trap fires, writes JSONL, and exits 0.
# If not (RED phase), bash exits 1 (pipefail + `false`).
false
WRAPPER_EOF
    chmod +x "$wrapper_script"

    local exit_code=0
    printf '%s' "$stdin_json" \
        | HOME="$TEST_HOME" bash "$wrapper_script" 2>/dev/null \
        || exit_code=$?

    # Assertion 1: exit code must be 0 (fail-open)
    assert_eq \
        "test_${dispatcher_filename%.sh}_err_fails_open: exit 0" \
        "0" \
        "$exit_code"

    # Assertion 2: JSONL log file must have been created
    local jsonl_line=""
    if [[ -f "$LOG_FILE" ]]; then
        jsonl_line=$(tail -1 "$LOG_FILE")
    fi
    assert_ne \
        "test_${dispatcher_filename%.sh}_err_writes_jsonl: log file written" \
        "" \
        "$jsonl_line"

    # Assertion 3: the JSONL line must contain the hook name
    assert_contains \
        "test_${dispatcher_filename%.sh}_err_jsonl_has_hook_name: hook label in JSONL" \
        "$hook_label" \
        "$jsonl_line"
}

# ── Standard stdin JSON stubs ─────────────────────────────────────────────────
# These are minimal valid-ish JSON payloads that prevent sourced libs from
# crashing on stdin parse failures. None of them trigger a block (exit 2).
_BASH_JSON='{"tool_name":"Bash","tool_input":{"command":"echo ok"}}'
_EDIT_JSON='{"tool_name":"Edit","tool_input":{"file_path":"/tmp/x.txt","old_string":"a","new_string":"b"}}'
_WRITE_JSON='{"tool_name":"Write","tool_input":{"file_path":"/tmp/x.txt","content":"hello"}}'
_PLAN_JSON='{"tool_name":"EnterPlanMode","tool_input":{}}'
_EXIT_PLAN_JSON='{"tool_name":"ExitPlanMode","tool_input":{}}'
_TASKOUTPUT_JSON='{"tool_name":"TaskOutput","tool_input":{"task_id":"t1","block":true}}'
_ALL_JSON='{"tool_name":"Read","tool_input":{"file_path":"/tmp/x.txt"}}'

# ── Test 1: pre-bash.sh ───────────────────────────────────────────────────────
test_pre_bash_err_fails_open() {
    echo "--- test_pre_bash_err_fails_open ---"
    _assert_dispatcher_err_fails_open_and_logs \
        "pre-bash.sh" \
        "pre-bash.sh" \
        "$_BASH_JSON"
}

# ── Test 2: pre-edit.sh ───────────────────────────────────────────────────────
test_pre_edit_err_fails_open() {
    echo "--- test_pre_edit_err_fails_open ---"
    _assert_dispatcher_err_fails_open_and_logs \
        "pre-edit.sh" \
        "pre-edit.sh" \
        "$_EDIT_JSON"
}

# ── Test 3: pre-write.sh ──────────────────────────────────────────────────────
test_pre_write_err_fails_open() {
    echo "--- test_pre_write_err_fails_open ---"
    _assert_dispatcher_err_fails_open_and_logs \
        "pre-write.sh" \
        "pre-write.sh" \
        "$_WRITE_JSON"
}

# ── Test 4: pre-enterplanmode.sh ─────────────────────────────────────────────
test_pre_enterplanmode_err_fails_open() {
    echo "--- test_pre_enterplanmode_err_fails_open ---"
    _assert_dispatcher_err_fails_open_and_logs \
        "pre-enterplanmode.sh" \
        "pre-enterplanmode.sh" \
        "$_PLAN_JSON"
}

# ── Test 5: pre-exitplanmode.sh ──────────────────────────────────────────────
test_pre_exitplanmode_err_fails_open() {
    echo "--- test_pre_exitplanmode_err_fails_open ---"
    _assert_dispatcher_err_fails_open_and_logs \
        "pre-exitplanmode.sh" \
        "pre-exitplanmode.sh" \
        "$_EXIT_PLAN_JSON"
}

# ── Test 6: pre-taskoutput.sh ────────────────────────────────────────────────
test_pre_taskoutput_err_fails_open() {
    echo "--- test_pre_taskoutput_err_fails_open ---"
    _assert_dispatcher_err_fails_open_and_logs \
        "pre-taskoutput.sh" \
        "pre-taskoutput.sh" \
        "$_TASKOUTPUT_JSON"
}

# ── Test 7: pre-all.sh ───────────────────────────────────────────────────────
test_pre_all_err_fails_open() {
    echo "--- test_pre_all_err_fails_open ---"
    _assert_dispatcher_err_fails_open_and_logs \
        "pre-all.sh" \
        "pre-all.sh" \
        "$_ALL_JSON"
}

# ── Run all tests ─────────────────────────────────────────────────────────────
test_pre_bash_err_fails_open
test_pre_edit_err_fails_open
test_pre_write_err_fails_open
test_pre_enterplanmode_err_fails_open
test_pre_exitplanmode_err_fails_open
test_pre_taskoutput_err_fails_open
test_pre_all_err_fails_open

print_summary
