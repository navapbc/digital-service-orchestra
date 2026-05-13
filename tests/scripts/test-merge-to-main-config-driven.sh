#!/usr/bin/env bash
# shellcheck disable=SC2030,SC2031,SC2164  # subshell variable scoping patterns in test setup
# tests/scripts/test-merge-to-main-config-driven.sh
# Behavioral tests verifying that merge-to-main reads commands.format_check and
# commands.lint from dso-config.conf instead of using hardcoded make targets.
#
# Tests (execution-based — no source-file inspection):
#   1. test_merge_validate_uses_custom_format_check_from_config
#      When commands.format_check is set to a custom command in dso-config.conf,
#      _phase_validate invokes the custom command, not make format-check.
#   2. test_merge_validate_uses_custom_lint_from_config
#      When commands.lint is set to a custom command in dso-config.conf,
#      _phase_validate invokes the custom command, not make lint.
#   3. test_merge_validate_does_not_invoke_hardcoded_make_format_check
#      When commands.format_check is set to a custom command, the hardcoded
#      'make format-check' binary is NOT called (custom command replaces it).
#   4. test_merge_validate_does_not_invoke_hardcoded_make_lint
#      When commands.lint is set to a custom command, 'make lint' is
#      NOT called (custom command replaces it).
#   5. test_merge_validate_default_format_check_is_make_format_check
#      When commands.format_check is absent from config, _phase_validate
#      invokes the default 'make format-check' command.
#   6. test_merge_validate_default_lint_is_make_lint
#      When commands.lint is absent from config, _phase_validate invokes
#      the default 'make lint' command.
#
# Test isolation: WORKFLOW_CONFIG_FILE env var overrides config file path,
# allowing tests to inject a custom dso-config.conf without touching the
# actual project config.
#
# Usage: bash tests/scripts/test-merge-to-main-config-driven.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DSO_PLUGIN_DIR="$PLUGIN_ROOT/plugins/dso"
MERGE_SCRIPT="$DSO_PLUGIN_DIR/scripts/merge-to-main-direct.sh"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

# =============================================================================
# Shared test infrastructure
# =============================================================================

# Helper: set up a minimal git repo and mock binary dir for _phase_validate
# Arguments:
#   $1 = test base dir
#   $2 = contents of dso-config.conf to inject (empty string = empty config)
# Sets globals: _MAIN_REPO, _MOCK_BIN, _FMT_CALL_LOG, _LINT_CALL_LOG, _CONFIG_FILE
_setup_validate_env() {
    local test_base="$1"
    local config_contents="${2:-}"

    _MAIN_REPO="$test_base/main"
    _MOCK_BIN="$test_base/mock-bin"
    _FMT_CALL_LOG="$test_base/fmt-calls.log"
    _LINT_CALL_LOG="$test_base/lint-calls.log"
    _CONFIG_FILE="$test_base/dso-config.conf"
    local app_dir="$_MAIN_REPO/app"

    mkdir -p "$app_dir" "$_MOCK_BIN"

    # Write injected config (may be empty to test defaults)
    printf '%s' "$config_contents" > "$_CONFIG_FILE"

    # Minimal git repo so _phase_validate git operations succeed
    (
        cd "$_MAIN_REPO"
        git init -b main --quiet
        git config user.email "test@test.com"
        git config user.name "Test"
        echo "init" > README.md
        git add README.md
        git commit -m "initial" --quiet
    ) 2>/dev/null

    # Mock 'make': records the target it was called with to the appropriate log
    cat > "$_MOCK_BIN/make" << MOCK_EOF
#!/usr/bin/env bash
case "\$1" in
    format-check) echo "format-check" >> "$_FMT_CALL_LOG" ; exit 0 ;;
    lint*)        echo "\$1" >> "$_LINT_CALL_LOG" ; exit 0 ;;
    *)            echo "make:\$*" >> "$_FMT_CALL_LOG" ; exit 0 ;;
esac
MOCK_EOF
    chmod +x "$_MOCK_BIN/make"

    # Mock 'custom-fmt-check': records invocation to fmt call log
    cat > "$_MOCK_BIN/custom-fmt-check" << MOCK_EOF
#!/usr/bin/env bash
echo "custom-fmt-check" >> "$_FMT_CALL_LOG"
exit 0
MOCK_EOF
    chmod +x "$_MOCK_BIN/custom-fmt-check"

    # Mock 'custom-lint': records invocation to lint call log
    cat > "$_MOCK_BIN/custom-lint" << MOCK_EOF
#!/usr/bin/env bash
echo "custom-lint" >> "$_LINT_CALL_LOG"
exit 0
MOCK_EOF
    chmod +x "$_MOCK_BIN/custom-lint"
}

# Helper: run _phase_validate in library mode via a wrapper script
# (BASH_SOURCE[0] must be set for merge-to-main-direct.sh; wrapper ensures this)
# Returns exit code of _phase_validate
_run_phase_validate_wrapper() {
    local wrapper
    wrapper=$(mktemp /tmp/run-validate.XXXXXX.sh)
    cat > "$wrapper" << WRAPPER_EOF
#!/usr/bin/env bash
export MERGE_TO_MAIN_DIRECT_LIB=1
export CLAUDE_PLUGIN_ROOT="$DSO_PLUGIN_DIR"
export WORKFLOW_CONFIG_FILE="$_CONFIG_FILE"
export BRANCH="test-config-driven-\$\$"
export MAIN_REPO="$_MAIN_REPO"
export PATHS_APP_DIR="app"
export PATH="$_MOCK_BIN:\$PATH"
# shellcheck source=/dev/null
source "$MERGE_SCRIPT"
_state_init 2>/dev/null || true
cd "\$MAIN_REPO"
_phase_validate 2>&1
WRAPPER_EOF
    bash "$wrapper"
    local rc=$?
    rm -f "$wrapper"
    return $rc
}

# =============================================================================
# Test 1: _phase_validate invokes custom format-check command from config
# Given: commands.format_check = custom-fmt-check in dso-config.conf
# When: _phase_validate runs
# Then: custom-fmt-check binary is called (recorded in call log)
# =============================================================================
echo ""
echo "--- test_merge_validate_uses_custom_format_check_from_config ---"
_snapshot_fail

_T1_BASE=$(mktemp -d)
_setup_validate_env "$_T1_BASE" "commands.format_check=custom-fmt-check
commands.lint=custom-lint"

_run_phase_validate_wrapper > /dev/null 2>&1 || true

_T1_FMT_CALLED="false"
if [[ -f "$_FMT_CALL_LOG" ]] && grep -q "custom-fmt-check" "$_FMT_CALL_LOG" 2>/dev/null; then
    _T1_FMT_CALLED="true"
fi
assert_eq "test_merge_validate_uses_custom_format_check_from_config" "true" "$_T1_FMT_CALLED"

assert_pass_if_clean "test_merge_validate_uses_custom_format_check_from_config"
rm -rf "$_T1_BASE"

# =============================================================================
# Test 2: _phase_validate invokes custom lint command from config
# Given: commands.lint = custom-lint in dso-config.conf
# When: _phase_validate runs
# Then: custom-lint binary is called (recorded in call log)
# =============================================================================
echo ""
echo "--- test_merge_validate_uses_custom_lint_from_config ---"
_snapshot_fail

_T2_BASE=$(mktemp -d)
_setup_validate_env "$_T2_BASE" "commands.format_check=custom-fmt-check
commands.lint=custom-lint"

_run_phase_validate_wrapper > /dev/null 2>&1 || true

_T2_LINT_CALLED="false"
if [[ -f "$_LINT_CALL_LOG" ]] && grep -q "custom-lint" "$_LINT_CALL_LOG" 2>/dev/null; then
    _T2_LINT_CALLED="true"
fi
assert_eq "test_merge_validate_uses_custom_lint_from_config" "true" "$_T2_LINT_CALLED"

assert_pass_if_clean "test_merge_validate_uses_custom_lint_from_config"
rm -rf "$_T2_BASE"

# =============================================================================
# Test 3: _phase_validate does NOT invoke 'make format-check' when config overrides it
# Given: commands.format_check = custom-fmt-check in dso-config.conf
# When: _phase_validate runs
# Then: mock 'make' is NOT called with 'format-check' target
# =============================================================================
echo ""
echo "--- test_merge_validate_does_not_invoke_hardcoded_make_format_check ---"
_snapshot_fail

_T3_BASE=$(mktemp -d)
_setup_validate_env "$_T3_BASE" "commands.format_check=custom-fmt-check
commands.lint=custom-lint"

_run_phase_validate_wrapper > /dev/null 2>&1 || true

# The mock 'make' records 'format-check' when called with that target.
# When custom-fmt-check is used instead, 'make format-check' must NOT appear.
_T3_MAKE_FMT_CALLED="false"
if [[ -f "$_FMT_CALL_LOG" ]] && grep -q "^format-check$" "$_FMT_CALL_LOG" 2>/dev/null; then
    _T3_MAKE_FMT_CALLED="true"
fi
assert_eq "test_merge_validate_does_not_invoke_hardcoded_make_format_check" "false" "$_T3_MAKE_FMT_CALLED"

assert_pass_if_clean "test_merge_validate_does_not_invoke_hardcoded_make_format_check"
rm -rf "$_T3_BASE"

# =============================================================================
# Test 4: _phase_validate does NOT invoke 'make lint' when config overrides it
# Given: commands.lint = custom-lint in dso-config.conf
# When: _phase_validate runs
# Then: mock 'make' is NOT called with a lint target
# =============================================================================
echo ""
echo "--- test_merge_validate_does_not_invoke_hardcoded_make_lint ---"
_snapshot_fail

_T4_BASE=$(mktemp -d)
_setup_validate_env "$_T4_BASE" "commands.format_check=custom-fmt-check
commands.lint=custom-lint"

_run_phase_validate_wrapper > /dev/null 2>&1 || true

_T4_MAKE_LINT_CALLED="false"
if [[ -f "$_LINT_CALL_LOG" ]] && grep -qE "^lint" "$_LINT_CALL_LOG" 2>/dev/null; then
    _T4_MAKE_LINT_CALLED="true"
fi
assert_eq "test_merge_validate_does_not_invoke_hardcoded_make_lint" "false" "$_T4_MAKE_LINT_CALLED"

assert_pass_if_clean "test_merge_validate_does_not_invoke_hardcoded_make_lint"
rm -rf "$_T4_BASE"

# =============================================================================
# Test 5: Default format-check command is 'make format-check' when config absent
# Given: commands.format_check is absent from dso-config.conf
# When: _phase_validate runs
# Then: mock 'make' is called with 'format-check' target
# =============================================================================
echo ""
echo "--- test_merge_validate_default_format_check_is_make_format_check ---"
_snapshot_fail

_T5_BASE=$(mktemp -d)
_setup_validate_env "$_T5_BASE" ""  # empty config — no commands overrides

_run_phase_validate_wrapper > /dev/null 2>&1 || true

_T5_MAKE_FMT_CALLED="false"
if [[ -f "$_FMT_CALL_LOG" ]] && grep -q "^format-check$" "$_FMT_CALL_LOG" 2>/dev/null; then
    _T5_MAKE_FMT_CALLED="true"
fi
assert_eq "test_merge_validate_default_format_check_is_make_format_check" "true" "$_T5_MAKE_FMT_CALLED"

assert_pass_if_clean "test_merge_validate_default_format_check_is_make_format_check"
rm -rf "$_T5_BASE"

# =============================================================================
# Test 6: Default lint command is 'make lint' when config absent
# Given: commands.lint is absent from dso-config.conf
# When: _phase_validate runs
# Then: mock 'make' is called with a lint target
# =============================================================================
echo ""
echo "--- test_merge_validate_default_lint_is_make_lint ---"
_snapshot_fail

_T6_BASE=$(mktemp -d)
_setup_validate_env "$_T6_BASE" ""  # empty config — no commands overrides

_run_phase_validate_wrapper > /dev/null 2>&1 || true

_T6_MAKE_LINT_CALLED="false"
if [[ -f "$_LINT_CALL_LOG" ]] && grep -qE "^lint" "$_LINT_CALL_LOG" 2>/dev/null; then
    _T6_MAKE_LINT_CALLED="true"
fi
assert_eq "test_merge_validate_default_lint_is_make_lint" "true" "$_T6_MAKE_LINT_CALLED"

assert_pass_if_clean "test_merge_validate_default_lint_is_make_lint"
rm -rf "$_T6_BASE"

# =============================================================================
print_summary
