#!/usr/bin/env bash
# lockpick-workflow/tests/scripts/test-report-flaky-tests.sh
# Tests for lockpick-workflow/scripts/report-flaky-tests.sh — multi-framework JUnit XML flaky detection.
#
# Covers all 4 flaky detection patterns:
#   1. <rerun> element (existing pattern)
#   2. <flakyFailure> / <flakyError> elements (Maven Surefire)
#   3. flaky='true' attribute (Bazel)
#   4. Duplicate testcase entries with mixed pass/fail (generic retry frameworks)
#
# Plus negative case (clean.xml) and exit-0 contracts.
#
# Usage: bash lockpick-workflow/tests/scripts/test-report-flaky-tests.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR" && git rev-parse --show-toplevel)"
FIXTURES="$SCRIPT_DIR/fixtures"
SCRIPT="$PLUGIN_ROOT/scripts/report-flaky-tests.sh"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

echo "=== test-report-flaky-tests.sh ==="

# ── Guard: script must exist ──────────────────────────────────────────────────
if [[ ! -f "$SCRIPT" ]]; then
    echo "SKIP: $SCRIPT not found — RED phase confirmed (implementation not yet written)" >&2
    echo ""
    printf "PASSED: %d  FAILED: %d\n" "$PASS" "$FAIL"
    exit 1
fi

# ── Helper ────────────────────────────────────────────────────────────────────
# run_script <fixture_path>
# Runs the script against a fixture file; captures combined stdout+stderr.
run_script() {
    local fixture="$1"
    bash "$SCRIPT" "$fixture" 2>&1 || true
}

# run_script_exit <fixture_path>
# Returns the exit code of the script.
run_script_exit() {
    local fixture="$1"
    local exit_code=0
    bash "$SCRIPT" "$fixture" >/dev/null 2>&1 || exit_code=$?
    echo "$exit_code"
}

# ── test_rerun_pattern ────────────────────────────────────────────────────────
# Fixture flaky-rerun.xml has a testcase with <rerun> and no <failure>.
# Expected: output contains the test name.
test_rerun_pattern() {
    local output
    output=$(run_script "$FIXTURES/flaky-rerun.xml")
    assert_contains "test_rerun_pattern: output contains test name" \
        "testFlakeyMethod" "$output"
}

# ── test_surefire_pattern ─────────────────────────────────────────────────────
# Fixture flaky-surefire.xml has testcases with <flakyFailure> / <flakyError>.
# Expected: output contains the test name.
test_surefire_pattern() {
    local output
    output=$(run_script "$FIXTURES/flaky-surefire.xml")
    assert_contains "test_surefire_pattern: output contains flakyFailure test name" \
        "testFlakyMaven" "$output"
}

# ── test_bazel_pattern ────────────────────────────────────────────────────────
# Fixture flaky-bazel.xml has a testcase with flaky='true' attribute.
# Expected: output contains the test name.
test_bazel_pattern() {
    local output
    output=$(run_script "$FIXTURES/flaky-bazel.xml")
    assert_contains "test_bazel_pattern: output contains test name" \
        "testFlakyBazel" "$output"
}

# ── test_duplicate_pattern ────────────────────────────────────────────────────
# Fixture flaky-duplicate.xml has duplicate testcases: one with <failure>, one without.
# Expected: output contains the test name.
test_duplicate_pattern() {
    local output
    output=$(run_script "$FIXTURES/flaky-duplicate.xml")
    assert_contains "test_duplicate_pattern: output contains test name" \
        "testFlakyDuplicate" "$output"
}

# ── test_clean_no_output ──────────────────────────────────────────────────────
# Fixture clean.xml has no flaky tests.
# Expected: output is 'No flaky tests detected.'
test_clean_no_output() {
    local output
    output=$(run_script "$FIXTURES/clean.xml")
    assert_contains "test_clean_no_output: reports no flaky tests" \
        "No flaky tests detected." "$output"
}

# ── test_missing_file_exits_zero ──────────────────────────────────────────────
# A non-existent file path should cause the script to exit 0 (graceful degradation).
test_missing_file_exits_zero() {
    local exit_code
    exit_code=$(run_script_exit "/tmp/nonexistent-junit-fixture-xyz-$$-does-not-exist.xml")
    assert_eq "test_missing_file_exits_zero: exits 0 for missing file" "0" "$exit_code"
}

# ── test_always_exits_zero ────────────────────────────────────────────────────
# Script must always exit 0 regardless of flaky test findings (CI-safe contract).
test_always_exits_zero() {
    local exit_code
    exit_code=$(run_script_exit "$FIXTURES/flaky-rerun.xml")
    assert_eq "test_always_exits_zero: exits 0 even when flaky tests found" "0" "$exit_code"
}

# ── Run all tests ─────────────────────────────────────────────────────────────
test_rerun_pattern
test_surefire_pattern
test_bazel_pattern
test_duplicate_pattern
test_clean_no_output
test_missing_file_exits_zero
test_always_exits_zero

# ── Summary ───────────────────────────────────────────────────────────────────
print_summary
