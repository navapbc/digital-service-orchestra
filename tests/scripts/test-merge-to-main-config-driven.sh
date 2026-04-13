#!/usr/bin/env bash
# tests/scripts/test-merge-to-main-config-driven.sh
# Tests that merge-to-main.sh reads commands.format_check and commands.lint
# from dso-config.conf instead of using hardcoded make targets.
#
# TDD tests:
#   1. test_merge_to_main_reads_format_check_from_config — uses config read
#   2. test_merge_to_main_reads_lint_from_config — uses config read
#   3. test_merge_to_main_no_hardcoded_invocation_format_check — no direct make call
#   4. test_merge_to_main_no_hardcoded_invocation_lint_ruff — no direct make call
#   5. test_merge_to_main_default_format_check — fallback matches current value
#   6. test_merge_to_main_default_lint — fallback matches current value
#
# Usage: bash tests/scripts/test-merge-to-main-config-driven.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DSO_PLUGIN_DIR="$PLUGIN_ROOT/plugins/dso"
REPO_ROOT="$(git rev-parse --show-toplevel)"
MERGE_SCRIPT="$DSO_PLUGIN_DIR/scripts/merge-to-main.sh"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

# =============================================================================
# Test 1: Script reads commands.format_check from config
# The script should contain a read-config.sh call for commands.format_check.
# =============================================================================
READS_FORMAT_CHECK=$(grep -c 'commands.format_check' "$MERGE_SCRIPT" || true)
assert_ne "test_merge_to_main_reads_format_check_config" "0" "$READS_FORMAT_CHECK"

# =============================================================================
# Test 2: Script reads commands.lint from config
# The script uses --batch eval to load all config keys (including commands.lint)
# in a single read-config.sh call. Verify that commands.lint is referenced
# (in a comment or as the COMMANDS_LINT variable) and COMMANDS_LINT is consumed.
# =============================================================================
READS_LINT=$(grep -c 'commands\.lint\|COMMANDS_LINT' "$MERGE_SCRIPT" || true)
assert_ne "test_merge_to_main_reads_lint_config" "0" "$READS_LINT"

# =============================================================================
# Test 3: No hardcoded 'make format-check' in command invocations
# The post-merge validation section should invoke $CMD_FORMAT_CHECK, not
# a literal 'make format-check'. Variable assignments (defaults) are OK.
# We check that no line runs make format-check directly (via cd && make ...).
# =============================================================================
HARDCODED_FORMAT_INVOCATION=$(grep -v '^\s*#' "$MERGE_SCRIPT" \
    | grep -v 'CMD_FORMAT_CHECK' \
    | grep -v '_FMT_TARGET' \
    | grep -v 'read-config' \
    | grep -c 'make format-check' || true)
assert_eq "test_merge_to_main_no_hardcoded_invocation_format_check" "0" "$HARDCODED_FORMAT_INVOCATION"

# =============================================================================
# Test 4: No hardcoded 'make lint-ruff' in command invocations
# The post-merge validation section should invoke $CMD_LINT, not
# a literal 'make lint-ruff'. Excludes variable assignments and comments.
# =============================================================================
HARDCODED_LINT_INVOCATION=$(grep -v '^\s*#' "$MERGE_SCRIPT" \
    | grep -v 'CMD_LINT' \
    | grep -v 'read-config' \
    | grep -c 'make lint-ruff' || true)
assert_eq "test_merge_to_main_no_hardcoded_invocation_lint_ruff" "0" "$HARDCODED_LINT_INVOCATION"

# =============================================================================
# Test 5: Default fallback for format_check matches 'make format-check'
# When config is absent, the fallback should be the current value.
# =============================================================================
HAS_FORMAT_DEFAULT="false"
_tmp=$(grep 'CMD_FORMAT_CHECK\|_FMT_TARGET' "$MERGE_SCRIPT")
if grep -q 'format-check' <<< "$_tmp"; then
    HAS_FORMAT_DEFAULT="true"
fi
assert_eq "test_merge_to_main_default_format_check" "true" "$HAS_FORMAT_DEFAULT"

# =============================================================================
# Test 6: Default fallback for lint matches 'make lint'
# When config is absent, the fallback should be a reasonable lint default.
# =============================================================================
HAS_LINT_DEFAULT="false"
_tmp=$(grep 'CMD_LINT' "$MERGE_SCRIPT"); if grep -q 'make lint' <<< "$_tmp"; then
    HAS_LINT_DEFAULT="true"
fi
assert_eq "test_merge_to_main_default_lint" "true" "$HAS_LINT_DEFAULT"

# =============================================================================
# Test 7: Post-merge validation uses CMD_FORMAT_CHECK variable
# The actual command invocation should reference $CMD_FORMAT_CHECK.
# =============================================================================
USES_FORMAT_VAR=$(grep -c '\$CMD_FORMAT_CHECK' "$MERGE_SCRIPT" || true)
assert_ne "test_merge_to_main_uses_format_check_var" "0" "$USES_FORMAT_VAR"

# =============================================================================
# Test 8: Post-merge validation uses CMD_LINT variable
# The actual command invocation should reference $CMD_LINT.
# =============================================================================
USES_LINT_VAR=$(grep -c '\$CMD_LINT' "$MERGE_SCRIPT" || true)
assert_ne "test_merge_to_main_uses_lint_var" "0" "$USES_LINT_VAR"

# =============================================================================
print_summary
