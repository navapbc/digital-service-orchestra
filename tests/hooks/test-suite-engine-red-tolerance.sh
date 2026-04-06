#!/usr/bin/env bash
# tests/hooks/test-suite-engine-red-tolerance.sh
# RED tests for suite-engine.sh RED-zone tolerance feature.
#
# These are TDD RED tests — they WILL FAIL until the implementation is added
# by subsequent tasks (cf53-d465 implements the tolerance logic in suite-engine.sh,
# 285a-6dbf extracts helper functions into tests/lib/red-zone.sh).
#
# Tests:
#   test_red_zone_only_failures_show_tolerated_status
#   test_red_zone_only_failures_exit_zero
#   test_no_suite_test_index_no_behavior_change
#   test_pre_marker_failure_blocks
#   test_unparseable_output_fail_safe
#
# Epic context: when SUITE_TEST_INDEX env var points to a .test-index file,
# suite-engine checks if ALL failures in a test file are in the RED zone
# (after the marker). If ALL failures are RED-zone → TOLERATED (exit 0,
# counted in TOLERATED column). If any failure is before the marker → FAIL.
# If SUITE_TEST_INDEX is unset → no behavior change.
# Summary line becomes: PASSED: N  FAILED: N  TOLERATED: N
#
# Usage: bash tests/hooks/test-suite-engine-red-tolerance.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null)"
LIB_DIR="$SCRIPT_DIR/../lib"

source "$LIB_DIR/assert.sh"

# ── Test fixture helpers ──────────────────────────────────────────────────────

FIXTURE_DIR=$(mktemp -d)
trap 'rm -rf "$FIXTURE_DIR"' EXIT

# make_passing_test: creates a test file that always passes (exit 0)
# Usage: make_passing_test <filename>
# Returns: full path to the created file
make_passing_test() {
    local name="$1"
    local path="$FIXTURE_DIR/$name"
    cat > "$path" <<'TESTEOF'
#!/usr/bin/env bash
echo "test_always_passes ... PASS"
echo ""
echo "PASSED: 1  FAILED: 0"
exit 0
TESTEOF
    chmod +x "$path"
    echo "$path"
}

# make_red_zone_toleratable_test: creates a test file with failures ONLY after
# the RED marker. Has a passing test and a failing "not yet implemented" test.
# The failing test name is: test_red_not_yet_implemented
# Usage: make_red_zone_toleratable_test <filename>
# Returns: full path to the created file
make_red_zone_toleratable_test() {
    local name="$1"
    local path="$FIXTURE_DIR/$name"
    cat > "$path" <<'TESTEOF'
#!/usr/bin/env bash
# Tests above this point are GREEN (passing)
test_green_feature_works() {
    echo "test_green_feature_works ... PASS"
}

# ── RED zone starts here (test_red_not_yet_implemented is the marker) ──

# test_red_not_yet_implemented: this feature does not exist yet
test_red_not_yet_implemented() {
    echo "test_red_not_yet_implemented: FAIL"
    echo "  expected: feature_works"
    echo "  actual:   feature_not_implemented"
}

test_green_feature_works
test_red_not_yet_implemented

echo ""
echo "PASSED: 1  FAILED: 1"
exit 1
TESTEOF
    chmod +x "$path"
    echo "$path"
}

# make_real_failure_test: creates a test file with a failure BEFORE any RED
# marker. This simulates a regression that must block the suite.
# The pre-marker failing test: test_regression_broke_existing_feature
# Usage: make_real_failure_test <filename>
# Returns: full path to the created file
make_real_failure_test() {
    local name="$1"
    local path="$FIXTURE_DIR/$name"
    cat > "$path" <<'TESTEOF'
#!/usr/bin/env bash
# This test fails BEFORE the RED marker — it's a real regression, not tolerable

test_regression_broke_existing_feature() {
    echo "test_regression_broke_existing_feature: FAIL"
    echo "  expected: existing_feature_still_works"
    echo "  actual:   regression_introduced"
}

# ── RED zone starts here (test_red_not_yet_implemented is the marker) ──

test_red_not_yet_implemented() {
    echo "test_red_not_yet_implemented: FAIL"
}

test_regression_broke_existing_feature
test_red_not_yet_implemented

echo ""
echo "PASSED: 0  FAILED: 2"
exit 1
TESTEOF
    chmod +x "$path"
    echo "$path"
}

# make_unparseable_output_test: creates a test file that exits non-zero but
# produces output that cannot be parsed to identify failing test names.
# The fail-safe behavior must treat this as a real failure (not TOLERATED).
# Usage: make_unparseable_output_test <filename>
# Returns: full path to the created file
make_unparseable_output_test() {
    local name="$1"
    local path="$FIXTURE_DIR/$name"
    cat > "$path" <<'TESTEOF'
#!/usr/bin/env bash
# This test produces non-standard output on failure — simulates a test runner
# crash, segfault, or unexpected output format that cannot be parsed.
echo "something went wrong but not in any recognizable format"
echo "ERROR: unexpected crash in test runner"
# No PASSED:/FAILED: summary line and no "test_name: FAIL" format
exit 1
TESTEOF
    chmod +x "$path"
    echo "$path"
}

# make_test_index: creates a .test-index file mapping test files to RED markers
# Usage: make_test_index <source_file> <test_file_path> <marker_name>
# The source_file is a placeholder (e.g., "src/placeholder.sh") since
# suite-engine reads the index by test file path, not source file
# Returns: full path to the created .test-index
make_test_index() {
    local index_path="$FIXTURE_DIR/.test-index"
    # Format: source/path.ext: test/path.ext [marker_name]
    printf '%s: %s [%s]\n' "$1" "$2" "$3" > "$index_path"
    echo "$index_path"
}

# ── Tests ─────────────────────────────────────────────────────────────────────

# --- test_red_zone_only_failures_show_tolerated_status ---
# When SUITE_TEST_INDEX is set and ALL failures in a test file are after the
# RED marker, the suite-engine MUST include a TOLERATED count in the summary.
# Expected summary line: "PASSED: N  FAILED: 0  TOLERATED: N"

_passing=$(make_passing_test "test-pass-always.sh")
_red_toleratable=$(make_red_zone_toleratable_test "test-red-toleratable.sh")

# Create .test-index: maps test-red-toleratable.sh to RED marker test_red_not_yet_implemented
_test_index=$(make_test_index \
    "src/placeholder.sh" \
    "$_red_toleratable" \
    "test_red_not_yet_implemented")

_suite_output_tolerated=$(
    MAX_PARALLEL=1 TEST_TIMEOUT=10 MAX_CONSECUTIVE_FAILS=10 \
    SUITE_TEST_INDEX="$_test_index" \
    bash "$LIB_DIR/suite-engine.sh" "$_passing" "$_red_toleratable" 2>&1
) || true

assert_contains "tolerated_summary_present" \
    "TOLERATED:" \
    "$_suite_output_tolerated"

# --- test_red_zone_only_failures_exit_zero ---
# When ALL failures are tolerated (RED-zone only), the suite-engine MUST exit 0.
# This is the core contract: RED-zone failures do not block the build.

_exit_code_tolerated=0
(
    MAX_PARALLEL=1 TEST_TIMEOUT=10 MAX_CONSECUTIVE_FAILS=10 \
    SUITE_TEST_INDEX="$_test_index" \
    bash "$LIB_DIR/suite-engine.sh" "$_passing" "$_red_toleratable" >/dev/null 2>&1
) || _exit_code_tolerated=$?

assert_eq "red_zone_only_exits_zero" \
    "0" \
    "$_exit_code_tolerated"

# --- test_no_suite_test_index_no_behavior_change ---
# When SUITE_TEST_INDEX is NOT set, existing behavior must be unchanged.
# A failing test file still causes the suite to fail (exit non-zero).
# The summary must NOT contain "TOLERATED:" when SUITE_TEST_INDEX is unset.

_exit_code_no_index=0
_suite_output_no_index=$(
    MAX_PARALLEL=1 TEST_TIMEOUT=10 MAX_CONSECUTIVE_FAILS=10 \
    bash "$LIB_DIR/suite-engine.sh" "$_passing" "$_red_toleratable" 2>&1
) || _exit_code_no_index=$?

assert_ne "no_index_exit_nonzero" \
    "0" \
    "$_exit_code_no_index"

_has_tolerated=0
_tmp="$_suite_output_no_index"; [[ "$_tmp" =~ TOLERATED: ]] && _has_tolerated=1
assert_eq "no_index_no_tolerated_in_summary" \
    "0" \
    "$_has_tolerated"

# --- test_pre_marker_failure_blocks ---
# When a test file has failures BEFORE the RED marker, the suite MUST fail
# (exit non-zero) even when SUITE_TEST_INDEX is set. Pre-marker failures are
# regressions and must not be tolerated.

_real_fail=$(make_real_failure_test "test-real-failure.sh")

# Create a new .test-index for real-fail test file (marker = test_red_not_yet_implemented)
_test_index_real=$(make_test_index \
    "src/placeholder2.sh" \
    "$_real_fail" \
    "test_red_not_yet_implemented")

_exit_code_real=0
(
    MAX_PARALLEL=1 TEST_TIMEOUT=10 MAX_CONSECUTIVE_FAILS=10 \
    SUITE_TEST_INDEX="$_test_index_real" \
    bash "$LIB_DIR/suite-engine.sh" "$_passing" "$_real_fail" >/dev/null 2>&1
) || _exit_code_real=$?

assert_ne "pre_marker_failure_blocks" \
    "0" \
    "$_exit_code_real"

# --- test_unparseable_output_fail_safe ---
# When a test file exits non-zero but its output cannot be parsed to identify
# which tests failed, the suite MUST treat it as a real failure (exit non-zero).
# This is the conservative fail-safe: unknown failures are never tolerated.

_unparseable=$(make_unparseable_output_test "test-unparseable.sh")

# Create .test-index for unparseable test with a marker (should not matter —
# since output is unparseable, tolerance logic cannot verify RED-zone)
_test_index_unparse=$(make_test_index \
    "src/placeholder3.sh" \
    "$_unparseable" \
    "some_red_marker")

_exit_code_unparse=0
(
    MAX_PARALLEL=1 TEST_TIMEOUT=10 MAX_CONSECUTIVE_FAILS=10 \
    SUITE_TEST_INDEX="$_test_index_unparse" \
    bash "$LIB_DIR/suite-engine.sh" "$_passing" "$_unparseable" >/dev/null 2>&1
) || _exit_code_unparse=$?

assert_ne "unparseable_output_fails_conservatively" \
    "0" \
    "$_exit_code_unparse"

# ── Summary ───────────────────────────────────────────────────────────────────

print_summary
