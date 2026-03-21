#!/usr/bin/env bash
# tests/hooks/test-blocked-test-command-hook.sh
# Unit tests for hook_blocked_test_command in pre-bash-functions.sh.
#
# Tests:
#   test_bare_configured_command_blocked
#   test_cd_prefix_stripped_and_blocked
#   test_command_with_extra_args_passes
#   test_unconfigured_command_passes
#   test_validate_sh_passes
#   test_test_batched_sh_passes
#   test_telemetry_written_on_block
#   test_non_bash_tool_passes
#   test_empty_config_key_passes
#   test_operator_split_blocks
#   test_plugin_root_unset_fallback
#
# Usage: bash tests/hooks/test-blocked-test-command-hook.sh
# Exit code: 0 if all pass, 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DSO_PLUGIN_DIR="$PLUGIN_ROOT/plugins/dso"
REPO_ROOT="$(cd "$SCRIPT_DIR" && git rev-parse --show-toplevel)"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

# Source hook functions (gives us hook_blocked_test_command)
# Reset the guard so we can re-source
unset _PRE_BASH_FUNCTIONS_LOADED
unset _DEPS_LOADED
source "$DSO_PLUGIN_DIR/hooks/lib/pre-bash-functions.sh"

# Create isolated temp dirs
_TEST_TMPDIR=$(mktemp -d)
_TEST_ARTIFACTS=$(mktemp -d)
_TEST_CONFIG_DIR=$(mktemp -d)
trap 'rm -rf "$_TEST_TMPDIR" "$_TEST_ARTIFACTS" "$_TEST_CONFIG_DIR"' EXIT

# Write a test config with known commands.test_unit value
_TEST_CONFIG="$_TEST_CONFIG_DIR/dso-config.conf"
cat > "$_TEST_CONFIG" <<'EOF'
commands.test_unit=make test-unit-only
commands.test_e2e=make test-e2e
EOF

# ============================================================
# test_bare_configured_command_blocked
# Bare configured commands.test_unit command must be blocked (exit 2)
# ============================================================
echo "--- test_bare_configured_command_blocked ---"
_INPUT='{"tool_name":"Bash","tool_input":{"command":"make test-unit-only"}}'
_exit_code=0
_output=""
_output=$(WORKFLOW_CONFIG_FILE="$_TEST_CONFIG" ARTIFACTS_DIR="$_TEST_ARTIFACTS" CLAUDE_PLUGIN_ROOT="$DSO_PLUGIN_DIR" \
    hook_blocked_test_command "$_INPUT" 2>&1) || _exit_code=$?
assert_eq "bare_configured_command_blocked: exit 2" "2" "$_exit_code"
assert_contains "bare_configured_command_blocked: ACTION REQUIRED" "ACTION REQUIRED" "$_output"
assert_contains "bare_configured_command_blocked: RUN line" "validate.sh" "$_output"

# ============================================================
# test_cd_prefix_stripped_and_blocked
# Configured command with `cd app &&` prefix is blocked
# ============================================================
echo "--- test_cd_prefix_stripped_and_blocked ---"
_exit_code=0
_output=""
_INPUT='{"tool_name":"Bash","tool_input":{"command":"cd app && make test-unit-only"}}'
_output=$(WORKFLOW_CONFIG_FILE="$_TEST_CONFIG" ARTIFACTS_DIR="$_TEST_ARTIFACTS" CLAUDE_PLUGIN_ROOT="$DSO_PLUGIN_DIR" \
    hook_blocked_test_command "$_INPUT" 2>&1) || _exit_code=$?
assert_eq "cd_prefix_stripped: exit 2" "2" "$_exit_code"
assert_contains "cd_prefix_stripped: ACTION REQUIRED" "ACTION REQUIRED" "$_output"

# ============================================================
# test_command_with_extra_args_passes
# Configured command with additional arguments passes through
# ============================================================
echo "--- test_command_with_extra_args_passes ---"
_exit_code=0
_output=""
_INPUT='{"tool_name":"Bash","tool_input":{"command":"make test-unit-only --verbose"}}'
_output=$(WORKFLOW_CONFIG_FILE="$_TEST_CONFIG" ARTIFACTS_DIR="$_TEST_ARTIFACTS" CLAUDE_PLUGIN_ROOT="$DSO_PLUGIN_DIR" \
    hook_blocked_test_command "$_INPUT" 2>&1) || _exit_code=$?
assert_eq "extra_args_passes: exit 0" "0" "$_exit_code"

# ============================================================
# test_unconfigured_command_passes
# A command that doesn't match any configured test command passes
# ============================================================
echo "--- test_unconfigured_command_passes ---"
_exit_code=0
_output=""
_INPUT='{"tool_name":"Bash","tool_input":{"command":"pytest tests/unit/test_foo.py"}}'
_output=$(WORKFLOW_CONFIG_FILE="$_TEST_CONFIG" ARTIFACTS_DIR="$_TEST_ARTIFACTS" CLAUDE_PLUGIN_ROOT="$DSO_PLUGIN_DIR" \
    hook_blocked_test_command "$_INPUT" 2>&1) || _exit_code=$?
assert_eq "unconfigured_command_passes: exit 0" "0" "$_exit_code"

# ============================================================
# test_validate_sh_passes
# validate.sh invocation passes through (safety allowlist)
# ============================================================
echo "--- test_validate_sh_passes ---"
_exit_code=0
_output=""
_INPUT='{"tool_name":"Bash","tool_input":{"command":"bash plugins/dso/scripts/validate.sh --ci"}}'
_output=$(WORKFLOW_CONFIG_FILE="$_TEST_CONFIG" ARTIFACTS_DIR="$_TEST_ARTIFACTS" CLAUDE_PLUGIN_ROOT="$DSO_PLUGIN_DIR" \
    hook_blocked_test_command "$_INPUT" 2>&1) || _exit_code=$?
assert_eq "validate_sh_passes: exit 0" "0" "$_exit_code"

# ============================================================
# test_test_batched_sh_passes
# test-batched.sh invocation passes through (safety allowlist)
# ============================================================
echo "--- test_test_batched_sh_passes ---"
_exit_code=0
_output=""
_INPUT='{"tool_name":"Bash","tool_input":{"command":"plugins/dso/scripts/test-batched.sh --timeout=50 \"make test-unit-only\""}}'
_output=$(WORKFLOW_CONFIG_FILE="$_TEST_CONFIG" ARTIFACTS_DIR="$_TEST_ARTIFACTS" CLAUDE_PLUGIN_ROOT="$DSO_PLUGIN_DIR" \
    hook_blocked_test_command "$_INPUT" 2>&1) || _exit_code=$?
assert_eq "test_batched_sh_passes: exit 0" "0" "$_exit_code"

# ============================================================
# test_telemetry_written_on_block
# JSONL telemetry entry is written to $ARTIFACTS_DIR/hook-telemetry.jsonl
# ============================================================
echo "--- test_telemetry_written_on_block ---"
_tel_artifacts=$(mktemp -d)
_exit_code=0
_output=""
_INPUT='{"tool_name":"Bash","tool_input":{"command":"make test-unit-only"}}'
_output=$(WORKFLOW_CONFIG_FILE="$_TEST_CONFIG" ARTIFACTS_DIR="$_tel_artifacts" CLAUDE_PLUGIN_ROOT="$DSO_PLUGIN_DIR" \
    hook_blocked_test_command "$_INPUT" 2>&1) || _exit_code=$?
assert_eq "telemetry_written: exit 2" "2" "$_exit_code"
# Check telemetry file exists and contains blocked_test_command event
_tel_content=""
if [[ -f "$_tel_artifacts/hook-telemetry.jsonl" ]]; then
    _tel_content=$(cat "$_tel_artifacts/hook-telemetry.jsonl")
fi
assert_contains "telemetry_written: blocked_test_command event" "blocked_test_command" "$_tel_content"
assert_contains "telemetry_written: command in telemetry" "make test-unit-only" "$_tel_content"
rm -rf "$_tel_artifacts"

# ============================================================
# test_non_bash_tool_passes
# Non-Bash tool call (e.g., Read) passes through immediately
# ============================================================
echo "--- test_non_bash_tool_passes ---"
_exit_code=0
_output=""
_INPUT='{"tool_name":"Read","tool_input":{"file_path":"/tmp/foo.txt"}}'
_output=$(WORKFLOW_CONFIG_FILE="$_TEST_CONFIG" ARTIFACTS_DIR="$_TEST_ARTIFACTS" CLAUDE_PLUGIN_ROOT="$DSO_PLUGIN_DIR" \
    hook_blocked_test_command "$_INPUT" 2>&1) || _exit_code=$?
assert_eq "non_bash_tool_passes: exit 0" "0" "$_exit_code"

# ============================================================
# test_empty_config_key_passes
# Empty/missing commands.test_unit config key causes pass-through
# ============================================================
echo "--- test_empty_config_key_passes ---"
_empty_config_dir=$(mktemp -d)
_empty_config="$_empty_config_dir/dso-config.conf"
cat > "$_empty_config" <<'EOF'
version=1.0.0
EOF
_exit_code=0
_output=""
_INPUT='{"tool_name":"Bash","tool_input":{"command":"make test-unit-only"}}'
_output=$(WORKFLOW_CONFIG_FILE="$_empty_config" ARTIFACTS_DIR="$_TEST_ARTIFACTS" CLAUDE_PLUGIN_ROOT="$DSO_PLUGIN_DIR" \
    hook_blocked_test_command "$_INPUT" 2>&1) || _exit_code=$?
assert_eq "empty_config_passes: exit 0" "0" "$_exit_code"
rm -rf "$_empty_config_dir"

# ============================================================
# test_operator_split_blocks
# Commands with shell operators where blocked value appears after splitting
# ============================================================
echo "--- test_operator_split_blocks ---"
_exit_code=0
_output=""
_INPUT='{"tool_name":"Bash","tool_input":{"command":"echo hello && make test-unit-only"}}'
_output=$(WORKFLOW_CONFIG_FILE="$_TEST_CONFIG" ARTIFACTS_DIR="$_TEST_ARTIFACTS" CLAUDE_PLUGIN_ROOT="$DSO_PLUGIN_DIR" \
    hook_blocked_test_command "$_INPUT" 2>&1) || _exit_code=$?
assert_eq "operator_split_blocks: exit 2" "2" "$_exit_code"
assert_contains "operator_split_blocks: ACTION REQUIRED" "ACTION REQUIRED" "$_output"

# ============================================================
# test_plugin_root_unset_fallback
# When CLAUDE_PLUGIN_ROOT is unset, hook falls back to BASH_SOURCE-relative path
# and RUN: line contains an absolute path
# ============================================================
echo "--- test_plugin_root_unset_fallback ---"
_exit_code=0
_output=""
_INPUT='{"tool_name":"Bash","tool_input":{"command":"make test-unit-only"}}'
_output=$(WORKFLOW_CONFIG_FILE="$_TEST_CONFIG" ARTIFACTS_DIR="$_TEST_ARTIFACTS" CLAUDE_PLUGIN_ROOT="" \
    hook_blocked_test_command "$_INPUT" 2>&1) || _exit_code=$?
assert_eq "plugin_root_unset: exit 2" "2" "$_exit_code"
assert_contains "plugin_root_unset: ACTION REQUIRED" "ACTION REQUIRED" "$_output"
# RUN: line must contain an absolute path (starts with /)
_run_line=$(echo "$_output" | grep "^RUN:" || echo "")
assert_contains "plugin_root_unset: RUN line has absolute path" "/" "$_run_line"
# Must contain validate.sh
assert_contains "plugin_root_unset: RUN line has validate.sh" "validate.sh" "$_run_line"

# Also test e2e command is blocked
echo "--- test_bare_e2e_command_blocked ---"
_exit_code=0
_output=""
_INPUT='{"tool_name":"Bash","tool_input":{"command":"make test-e2e"}}'
_output=$(WORKFLOW_CONFIG_FILE="$_TEST_CONFIG" ARTIFACTS_DIR="$_TEST_ARTIFACTS" CLAUDE_PLUGIN_ROOT="$DSO_PLUGIN_DIR" \
    hook_blocked_test_command "$_INPUT" 2>&1) || _exit_code=$?
assert_eq "bare_e2e_command_blocked: exit 2" "2" "$_exit_code"
assert_contains "bare_e2e_command_blocked: ACTION REQUIRED" "ACTION REQUIRED" "$_output"

# ============================================================
# Summary
# ============================================================
echo ""
echo "ALL TESTS PASSED"
print_summary
