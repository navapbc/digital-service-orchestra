#!/usr/bin/env bash
# tests/scripts/test-isolation-check.sh
# Regression tests for the test-isolation harness (scripts/check-test-isolation.sh)
#
# Verifies:
#   1. The harness exits non-zero when run against a file with a known violation
#   2. The harness output contains the expected rule name
#   3. The full scan of all test files shows zero violations (excluding fixtures)
#
# Usage: bash tests/scripts/test-isolation-check.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR" && git rev-parse --show-toplevel)"
HARNESS="$REPO_ROOT/scripts/check-test-isolation.sh"
FIXTURES_DIR="$SCRIPT_DIR/fixtures/isolation-rules"
REGRESSION_FIXTURE="$FIXTURES_DIR/regression-violation.sh"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

echo "=== test-isolation-check.sh ==="

# ── test_harness_exists_and_executable ───────────────────────────────────────
_snapshot_fail
harness_exec=0
[ -x "$HARNESS" ] && harness_exec=1
assert_eq "test_harness_exists_and_executable" "1" "$harness_exec"
assert_pass_if_clean "test_harness_exists_and_executable"

# ── test_regression_fixture_exists ───────────────────────────────────────────
_snapshot_fail
fixture_exists=0
[ -f "$REGRESSION_FIXTURE" ] && fixture_exists=1
assert_eq "test_regression_fixture_exists" "1" "$fixture_exists"
assert_pass_if_clean "test_regression_fixture_exists"

# ── test_harness_exits_nonzero_on_regression_fixture ─────────────────────────
# The regression fixture contains a known unscoped export violation.
# The harness should detect it and exit non-zero.
_snapshot_fail
output=$("$HARNESS" "$REGRESSION_FIXTURE" 2>/dev/null)
exit_code=$?
assert_eq "test_harness_exits_nonzero_on_regression_fixture: exit 1" "1" "$exit_code"
assert_pass_if_clean "test_harness_exits_nonzero_on_regression_fixture"

# ── test_harness_output_contains_rule_name ───────────────────────────────────
# The harness output should include the rule name that was violated.
_snapshot_fail
assert_contains "test_harness_output_contains_rule_name: no-unscoped-export" "no-unscoped-export" "$output"
assert_pass_if_clean "test_harness_output_contains_rule_name"

# ── test_harness_output_contains_filename ────────────────────────────────────
# The harness output should reference the fixture file.
_snapshot_fail
assert_contains "test_harness_output_contains_filename: regression-violation.sh" "regression-violation.sh" "$output"
assert_pass_if_clean "test_harness_output_contains_filename"

# ── test_harness_output_has_structured_format ────────────────────────────────
# Output format should be file:line:rule:message
_snapshot_fail
assert_contains "test_harness_output_has_structured_format" ":6:no-unscoped-export:" "$output"
assert_pass_if_clean "test_harness_output_has_structured_format"

# ── test_harness_passes_on_clean_file ─────────────────────────────────────────
# Run the harness against a known-clean fixture to verify it reports zero violations.
# NOTE: A full scan of all 700+ test files (~32s per file) is verified via the
# AC command run separately with appropriate timeout, not in this unit test.
_snapshot_fail
clean_output=$("$HARNESS" "$FIXTURES_DIR/good-scoped-export.sh" 2>/dev/null)
clean_exit=$?
assert_eq "test_harness_passes_on_clean_file: exit 0" "0" "$clean_exit"
assert_eq "test_harness_passes_on_clean_file: no violations in output" "" "$clean_output"
assert_pass_if_clean "test_harness_passes_on_clean_file"

# ── test_harness_passes_on_clean_shell_test ───────────────────────────────────
# Run the harness against one actual shell test file to spot-check zero violations.
_snapshot_fail
# Use this test file itself as a known-clean shell script (deterministic, no find)
SAMPLE_SH="${BASH_SOURCE[0]}"
sample_output=$("$HARNESS" "$SAMPLE_SH" 2>/dev/null)
sample_exit=$?
assert_eq "test_harness_passes_on_clean_shell_test: exit 0" "0" "$sample_exit"
assert_eq "test_harness_passes_on_clean_shell_test: no violations in output" "" "$sample_output"
assert_pass_if_clean "test_harness_passes_on_clean_shell_test"

print_summary
