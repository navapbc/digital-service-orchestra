#!/usr/bin/env bash
# lockpick-workflow/tests/scripts/test-workflow-config-keys.sh
# Tests that workflow-config.yaml contains scalar path and interpreter keys
# readable by read-config.sh.
#
# Usage: bash lockpick-workflow/tests/scripts/test-workflow-config-keys.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
SCRIPT="$REPO_ROOT/lockpick-workflow/scripts/read-config.sh"
CONFIG="$REPO_ROOT/workflow-config.yaml"

source "$REPO_ROOT/lockpick-workflow/tests/lib/assert.sh"

echo "=== test-workflow-config-keys.sh ==="

# ── test_config_paths_app_dir ────────────────────────────────────────────────
# paths.app_dir must return "app"
_snapshot_fail
paths_app_exit=0
paths_app_output=""
paths_app_output=$(bash "$SCRIPT" "$CONFIG" "paths.app_dir" 2>&1) || paths_app_exit=$?
assert_eq "test_config_paths_app_dir: exit 0" "0" "$paths_app_exit"
assert_eq "test_config_paths_app_dir: value is app" "app" "$paths_app_output"
assert_pass_if_clean "test_config_paths_app_dir"

# ── test_config_paths_src_dir ────────────────────────────────────────────────
# paths.src_dir must return "src"
_snapshot_fail
paths_src_exit=0
paths_src_output=""
paths_src_output=$(bash "$SCRIPT" "$CONFIG" "paths.src_dir" 2>&1) || paths_src_exit=$?
assert_eq "test_config_paths_src_dir: exit 0" "0" "$paths_src_exit"
assert_eq "test_config_paths_src_dir: value is src" "src" "$paths_src_output"
assert_pass_if_clean "test_config_paths_src_dir"

# ── test_config_paths_test_dir ───────────────────────────────────────────────
# paths.test_dir must return "tests"
_snapshot_fail
paths_test_exit=0
paths_test_output=""
paths_test_output=$(bash "$SCRIPT" "$CONFIG" "paths.test_dir" 2>&1) || paths_test_exit=$?
assert_eq "test_config_paths_test_dir: exit 0" "0" "$paths_test_exit"
assert_eq "test_config_paths_test_dir: value is tests" "tests" "$paths_test_output"
assert_pass_if_clean "test_config_paths_test_dir"

# ── test_config_paths_test_unit_dir ──────────────────────────────────────────
# paths.test_unit_dir must return "tests/unit"
_snapshot_fail
paths_unit_exit=0
paths_unit_output=""
paths_unit_output=$(bash "$SCRIPT" "$CONFIG" "paths.test_unit_dir" 2>&1) || paths_unit_exit=$?
assert_eq "test_config_paths_test_unit_dir: exit 0" "0" "$paths_unit_exit"
assert_eq "test_config_paths_test_unit_dir: value is tests/unit" "tests/unit" "$paths_unit_output"
assert_pass_if_clean "test_config_paths_test_unit_dir"

# ── test_config_interpreter_python_venv ──────────────────────────────────────
# interpreter.python_venv must return "app/.venv/bin/python3"
_snapshot_fail
interp_exit=0
interp_output=""
interp_output=$(bash "$SCRIPT" "$CONFIG" "interpreter.python_venv" 2>&1) || interp_exit=$?
assert_eq "test_config_interpreter_python_venv: exit 0" "0" "$interp_exit"
assert_eq "test_config_interpreter_python_venv: value is app/.venv/bin/python3" "app/.venv/bin/python3" "$interp_output"
assert_pass_if_clean "test_config_interpreter_python_venv"

# ── test_config_paths_keys_exist ─────────────────────────────────────────────
# All five keys must be non-empty (integration check)
_snapshot_fail
for key in paths.app_dir paths.src_dir paths.test_dir paths.test_unit_dir interpreter.python_venv; do
    key_output=$(bash "$SCRIPT" "$CONFIG" "$key" 2>&1)
    assert_ne "test_config_paths_keys_exist: $key is non-empty" "" "$key_output"
done
assert_pass_if_clean "test_config_paths_keys_exist"

# ── test_commands_test_changed_key_exists ────────────────────────────────────
# commands.test_changed must return "./scripts/run-changed-tests.sh"
_snapshot_fail
test_changed_exit=0
test_changed_output=""
test_changed_output=$(bash "$SCRIPT" "$CONFIG" "commands.test_changed" 2>&1) || test_changed_exit=$?
assert_eq "test_commands_test_changed_key_exists: exit 0" "0" "$test_changed_exit"
assert_eq "test_commands_test_changed_key_exists: value is ./scripts/run-changed-tests.sh" "./scripts/run-changed-tests.sh" "$test_changed_output"
assert_pass_if_clean "test_commands_test_changed_key_exists"

print_summary
