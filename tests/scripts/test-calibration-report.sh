#!/usr/bin/env bash
# tests/scripts/test-calibration-report.sh
# Fixture-driven behavioral tests for plugins/dso/scripts/calibration-report.sh
#
# Testing Mode: RED → GREEN — write failing test first, then implement.
#
# Task coverage: 92fd-f373-f963-4d52
# Story coverage: calibration-program monthly aggregation
#
# Behavioral pattern: every test follows Given / When / Then. Tests invoke
# calibration-report.sh as a subprocess with --fixture and --dry-run flags.
#
# Usage: bash tests/scripts/test-calibration-report.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

# NOTE: -e intentionally omitted — test functions may return non-zero by design.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"
CALIBRATION_SCRIPT="$REPO_ROOT/plugins/dso/scripts/calibration-report.sh"
FIXTURE_DIR="$REPO_ROOT/tests/fixtures/a34c-sprint-bugs"

source "$REPO_ROOT/tests/lib/assert.sh"

echo "=== test-calibration-report.sh ==="

# ── Suite-level prereq guard ────────────────────────────────────────────────
# We do NOT use a _RUN_ALL_ACTIVE skip guard — this test is not a deferred RED.
# The script MUST exist for these tests to pass (GREEN phase).

# ═══════════════════════════════════════════════════════════════════════════════
# Test 1: Script exists and is executable
# ═══════════════════════════════════════════════════════════════════════════════
echo "Test 1: calibration-report.sh exists and is executable"
test_script_exists_and_executable() {
    _snapshot_fail

    if [ -f "$CALIBRATION_SCRIPT" ]; then
        assert_eq "calibration-report.sh exists" "exists" "exists"
    else
        assert_eq "calibration-report.sh exists" "exists" "missing"
    fi

    if [ -x "$CALIBRATION_SCRIPT" ]; then
        assert_eq "calibration-report.sh is executable" "executable" "executable"
    else
        assert_eq "calibration-report.sh is executable" "executable" "not-executable"
    fi

    assert_pass_if_clean "test_script_exists_and_executable"
}
test_script_exists_and_executable

# ═══════════════════════════════════════════════════════════════════════════════
# Test 2: CALIBRATION_TZ='UTC' declared exactly once
#
# Given: calibration-report.sh source file
# When:  we grep for the readonly CALIBRATION_TZ='UTC' declaration
# Then:  exactly 1 occurrence exists
# ═══════════════════════════════════════════════════════════════════════════════
echo "Test 2: CALIBRATION_TZ='UTC' declared exactly once"
test_calibration_tz_declared_once() {
    _snapshot_fail

    if [ ! -f "$CALIBRATION_SCRIPT" ]; then
        assert_eq "calibration-report.sh exists (prereq)" "exists" "missing"
        assert_pass_if_clean "test_calibration_tz_declared_once"
        return
    fi

    local count
    count=$(grep -c "^readonly CALIBRATION_TZ='UTC'" "$CALIBRATION_SCRIPT" || true)
    assert_eq "CALIBRATION_TZ='UTC' declared exactly once" "1" "$count"

    assert_pass_if_clean "test_calibration_tz_declared_once"
}
test_calibration_tz_declared_once

# ═══════════════════════════════════════════════════════════════════════════════
# Test 3: Unknown subcommand exits non-zero and prints to stderr
#
# Given: calibration-report.sh is invoked with an unknown subcommand
# When:  "badsubcmd" is passed
# Then:  exit code is non-zero (stderr is allowed to receive usage text)
# ═══════════════════════════════════════════════════════════════════════════════
echo "Test 3: unknown subcommand exits non-zero"
test_unknown_subcommand_exits_nonzero() {
    _snapshot_fail

    if [ ! -x "$CALIBRATION_SCRIPT" ]; then
        assert_eq "calibration-report.sh executable (prereq)" "executable" "missing"
        assert_pass_if_clean "test_unknown_subcommand_exits_nonzero"
        return
    fi

    local exit_code=0
    "$CALIBRATION_SCRIPT" badsubcmd 2>/dev/null || exit_code=$?
    assert_ne "badsubcmd exits non-zero" "0" "$exit_code"

    assert_pass_if_clean "test_unknown_subcommand_exits_nonzero"
}
test_unknown_subcommand_exits_nonzero

# ═══════════════════════════════════════════════════════════════════════════════
# Test 4: Fixture directory exists with at least one JSON file
#
# Given: tests/fixtures/a34c-sprint-bugs/ directory
# When:  we check its contents
# Then:  directory exists and contains at least 1 .json file
# ═══════════════════════════════════════════════════════════════════════════════
echo "Test 4: fixture directory exists with JSON files"
test_fixture_directory_exists() {
    _snapshot_fail

    if [ -d "$FIXTURE_DIR" ]; then
        assert_eq "fixture directory exists" "exists" "exists"
    else
        assert_eq "fixture directory exists" "exists" "missing"
    fi

    local json_count
    json_count=$(find "$FIXTURE_DIR" -name '*.json' 2>/dev/null | wc -l | tr -d ' ')
    assert_ne "fixture directory has at least 1 JSON file" "0" "$json_count"

    assert_pass_if_clean "test_fixture_directory_exists"
}
test_fixture_directory_exists

# ═══════════════════════════════════════════════════════════════════════════════
# Test 5: monthly --dry-run output contains the rollup HTML comment marker
#
# Given: fixture with 6 bugs across 3 channels (tests:3, review-llm:2, user-report:1)
# When:  monthly --fixture --dry-run --period 2026-04
# Then:  stdout contains <!-- calibration-rollup: period=2026-04 kind=monthly -->
# ═══════════════════════════════════════════════════════════════════════════════
echo "Test 5: monthly dry-run output contains calibration-rollup HTML marker"
test_monthly_dry_run_contains_marker() {
    _snapshot_fail

    if [ ! -x "$CALIBRATION_SCRIPT" ]; then
        assert_eq "calibration-report.sh executable (prereq)" "executable" "missing"
        assert_pass_if_clean "test_monthly_dry_run_contains_marker"
        return
    fi

    if [ ! -d "$FIXTURE_DIR" ]; then
        assert_eq "fixture directory exists (prereq)" "exists" "missing"
        assert_pass_if_clean "test_monthly_dry_run_contains_marker"
        return
    fi

    local out exit_code=0
    out=$("$CALIBRATION_SCRIPT" monthly --fixture "$FIXTURE_DIR" --dry-run --period 2026-04 2>/dev/null) || exit_code=$?

    assert_eq "monthly --dry-run exits 0" "0" "$exit_code"
    assert_contains "stdout contains calibration-rollup marker" \
        "<!-- calibration-rollup: period=2026-04 kind=monthly -->" \
        "$out"

    assert_pass_if_clean "test_monthly_dry_run_contains_marker"
}
test_monthly_dry_run_contains_marker

# ═══════════════════════════════════════════════════════════════════════════════
# Test 6: monthly aggregation produces correct per-channel counts
#
# Given: fixture with tests:3, review-llm:2, user-report:1
# When:  monthly --fixture --dry-run --period 2026-04
# Then:  stdout shows correct counts for each channel
# ═══════════════════════════════════════════════════════════════════════════════
echo "Test 6: monthly aggregation shows correct per-channel counts"
test_monthly_channel_counts() {
    _snapshot_fail

    if [ ! -x "$CALIBRATION_SCRIPT" ]; then
        assert_eq "calibration-report.sh executable (prereq)" "executable" "missing"
        assert_pass_if_clean "test_monthly_channel_counts"
        return
    fi

    if [ ! -d "$FIXTURE_DIR" ]; then
        assert_eq "fixture directory exists (prereq)" "exists" "missing"
        assert_pass_if_clean "test_monthly_channel_counts"
        return
    fi

    local out exit_code=0
    out=$("$CALIBRATION_SCRIPT" monthly --fixture "$FIXTURE_DIR" --dry-run --period 2026-04 2>/dev/null) || exit_code=$?

    assert_eq "monthly --dry-run exits 0" "0" "$exit_code"

    # Check that each channel and its count appear in the output.
    # Flexible matching: "tests: 3" or "tests:3" or "tests | 3" etc.
    assert_contains "stdout contains tests channel count" "tests" "$out"
    assert_contains "stdout contains review-llm channel count" "review-llm" "$out"
    assert_contains "stdout contains user-report channel count" "user-report" "$out"

    # Assert exact count values appear near their channel names.
    # We match "3" appearing somewhere after "tests" in the output.
    if echo "$out" | grep -q "tests.*3\|3.*tests"; then
        assert_eq "tests channel count is 3" "found" "found"
    else
        assert_eq "tests channel count is 3" "found" "not-found"
    fi

    if echo "$out" | grep -q "review-llm.*2\|2.*review-llm"; then
        assert_eq "review-llm channel count is 2" "found" "found"
    else
        assert_eq "review-llm channel count is 2" "found" "not-found"
    fi

    if echo "$out" | grep -q "user-report.*1\|1.*user-report"; then
        assert_eq "user-report channel count is 1" "found" "found"
    else
        assert_eq "user-report channel count is 1" "found" "not-found"
    fi

    assert_pass_if_clean "test_monthly_channel_counts"
}
test_monthly_channel_counts

# ═══════════════════════════════════════════════════════════════════════════════
# Test 7: nonexistent fixture path exits non-zero
#
# Given: --fixture path that does not exist
# When:  monthly --fixture /nonexistent/path --dry-run --period 2026-04
# Then:  exit code is non-zero
# ═══════════════════════════════════════════════════════════════════════════════
echo "Test 7: nonexistent fixture path exits non-zero"
test_nonexistent_fixture_exits_nonzero() {
    _snapshot_fail

    if [ ! -x "$CALIBRATION_SCRIPT" ]; then
        assert_eq "calibration-report.sh executable (prereq)" "executable" "missing"
        assert_pass_if_clean "test_nonexistent_fixture_exits_nonzero"
        return
    fi

    local exit_code=0
    "$CALIBRATION_SCRIPT" monthly --fixture /nonexistent/path --dry-run --period 2026-04 2>/dev/null \
        || exit_code=$?
    assert_ne "nonexistent fixture exits non-zero" "0" "$exit_code"

    assert_pass_if_clean "test_nonexistent_fixture_exits_nonzero"
}
test_nonexistent_fixture_exits_nonzero

# ═══════════════════════════════════════════════════════════════════════════════
print_summary
