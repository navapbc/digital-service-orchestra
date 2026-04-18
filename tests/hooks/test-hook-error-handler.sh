#!/usr/bin/env bash
# shellcheck disable=SC2030,SC2031
# tests/hooks/test-hook-error-handler.sh
# Behavioral tests for plugins/dso/hooks/lib/hook-error-handler.sh
#
# RED phase: these tests FAIL before hook-error-handler.sh is created (T2).
# GREEN phase: tests PASS after T2 creates the handler with correct behavior.
#
# Isolation: all tests use TEST_HOME (mktemp -d) so no writes touch real $HOME/.claude/logs/.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "$SCRIPT_DIR/../lib/assert.sh"

HANDLER_PATH="$PLUGIN_ROOT/plugins/dso/hooks/lib/hook-error-handler.sh"

# Shared isolated HOME for all tests — overridden per-test below
_TEST_TMPDIRS=()
cleanup() {
    for d in "${_TEST_TMPDIRS[@]:-}"; do
        rm -rf "$d"
    done
}
trap cleanup EXIT

_make_test_home() {
    local d
    d=$(mktemp -d)
    _TEST_TMPDIRS+=("$d")
    echo "$d"
}

# ── Test 1: _dso_register_hook_err_handler sets ERR trap ─────────────────────
test_register_hook_err_handler_sets_trap() {
    local TEST_HOME
    TEST_HOME=$(_make_test_home)

    # Run in a subshell with isolated HOME so we don't pollute the real env
    local trap_output
    trap_output=$(
        export HOME="$TEST_HOME"
        source "$HANDLER_PATH"
        _dso_register_hook_err_handler "test-hook.sh"
        trap -p ERR
    ) || true

    assert_contains \
        "ERR trap references _dso_hook_err_handler" \
        "_dso_hook_err_handler" \
        "$trap_output"
}

# ── Test 2: ERR trigger writes enriched JSONL with all 7 required fields ──────
test_err_trigger_writes_enriched_jsonl() {
    local TEST_HOME
    TEST_HOME=$(_make_test_home)
    local LOG_FILE="$TEST_HOME/.claude/logs/dso-hook-errors.jsonl"

    # Trigger an ERR inside a subshell with the handler active; expect exit 0 (fail-open)
    (
        export HOME="$TEST_HOME"
        export _DSO_HOOK_NAME="test-hook.sh"
        source "$HANDLER_PATH"
        _dso_register_hook_err_handler "test-hook.sh"
        false   # triggers ERR
    ) || true   # fail-open: subshell should exit 0; we allow non-zero here just in case

    # JSONL file must exist
    local line
    if [[ ! -f "$LOG_FILE" ]]; then
        (( ++FAIL ))
        printf "FAIL: enriched_jsonl_file_exists\n  expected file: %s\n  not found\n" "$LOG_FILE" >&2
        return
    fi

    line=$(tail -1 "$LOG_FILE")

    assert_contains "jsonl_has_ts_field"           '"ts"'             "$line"
    assert_contains "jsonl_has_hook_field"         '"hook"'           "$line"
    assert_contains "jsonl_has_line_field"         '"line"'           "$line"
    assert_contains "jsonl_has_repo_root_field"    '"repo_root"'      "$line"
    assert_contains "jsonl_has_plugin_version"     '"plugin_version"' "$line"
    assert_contains "jsonl_has_bash_version"       '"bash_version"'   "$line"
    assert_contains "jsonl_has_os_field"           '"os"'             "$line"
    assert_contains "jsonl_hook_value_correct"     "test-hook.sh"     "$line"
}

# ── Test 3: Handler exits 0 on ERR (fail-open) ───────────────────────────────
test_handler_exits_0_on_err() {
    local TEST_HOME
    TEST_HOME=$(_make_test_home)

    local exit_code
    (
        export HOME="$TEST_HOME"
        export _DSO_HOOK_NAME="test-hook.sh"
        source "$HANDLER_PATH"
        _dso_register_hook_err_handler "test-hook.sh"
        false   # triggers ERR
    )
    exit_code=$?

    assert_eq "handler_exits_0_on_err" "0" "$exit_code"
}

# ── Test 4: Handler creates ~/.claude/logs/ directory lazily ─────────────────
test_mkdir_created_lazily() {
    local TEST_HOME
    TEST_HOME=$(_make_test_home)
    local LOG_DIR="$TEST_HOME/.claude/logs"

    # Confirm the directory does not exist before the handler runs
    if [[ -d "$LOG_DIR" ]]; then
        (( ++FAIL ))
        printf "FAIL: precondition_log_dir_absent\n  directory should not exist before test: %s\n" "$LOG_DIR" >&2
        return
    fi

    (
        export HOME="$TEST_HOME"
        export _DSO_HOOK_NAME="test-hook.sh"
        source "$HANDLER_PATH"
        _dso_register_hook_err_handler "test-hook.sh"
        false   # triggers ERR and should create the log dir
    ) || true

    if [[ -d "$LOG_DIR" ]]; then
        (( ++PASS ))
    else
        (( ++FAIL ))
        printf "FAIL: log_dir_created_lazily\n  expected directory to be created: %s\n" "$LOG_DIR" >&2
    fi
}

# ── Run all tests ─────────────────────────────────────────────────────────────
test_register_hook_err_handler_sets_trap
test_err_trigger_writes_enriched_jsonl
test_handler_exits_0_on_err
test_mkdir_created_lazily

print_summary
