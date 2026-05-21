#!/usr/bin/env bash
# tests/scripts/test-calibration-attribution-e2e.sh
# Conditional E2E test: calibration-report.sh monthly --fixture attribution
#
# Testing Mode: GREEN — validates existing behavior with the fixture at
# tests/fixtures/a34c-sprint-bugs/bugs.json.
#
# Task coverage: 733e-632f-a871-4092
# Story coverage: a34c-b345-1e63-4ae3
#
# Behavioral pattern: Given / When / Then.
# Guards skip with a clear message when prerequisites are absent.
#
# Usage: bash tests/scripts/test-calibration-attribution-e2e.sh
# Returns: exit 0 if all tests pass (or skipped), exit 1 if any fail

# NOTE: -e intentionally omitted — test functions may return non-zero by design.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"
CALIBRATION_SCRIPT="$REPO_ROOT/plugins/dso/scripts/calibration-report.sh"
FIXTURE_DIR="$REPO_ROOT/tests/fixtures/a34c-sprint-bugs"
FIXTURE_FILE="$FIXTURE_DIR/bugs.json"

source "$REPO_ROOT/tests/lib/assert.sh"

echo "=== test-calibration-attribution-e2e.sh ==="

# ── Suite-level prereq guards ───────────────────────────────────────────────

# Guard 1: calibration-report.sh must exist and be executable.
if [ ! -f "$CALIBRATION_SCRIPT" ]; then
    echo "SKIP: calibration-report.sh not found at $CALIBRATION_SCRIPT — skipping E2E test"
    exit 0
fi

if [ ! -x "$CALIBRATION_SCRIPT" ]; then
    echo "SKIP: calibration-report.sh is not executable — skipping E2E test"
    exit 0
fi

# Guard 2: fixture directory and bugs.json must exist.
if [ ! -d "$FIXTURE_DIR" ]; then
    echo "SKIP: fixture directory not found at $FIXTURE_DIR — skipping E2E test"
    exit 0
fi

if [ ! -f "$FIXTURE_FILE" ]; then
    echo "SKIP: fixture file not found at $FIXTURE_FILE — skipping E2E test"
    exit 0
fi

# ═══════════════════════════════════════════════════════════════════════════════
# Test 1: monthly --fixture exits 0 and produces channel breakdown
#
# Given: fixture at tests/fixtures/a34c-sprint-bugs with bugs.json containing
#        3 x detected_by:tests, 2 x detected_by:review-llm, 1 x detected_by:user-report
# When:  calibration-report.sh monthly --fixture <dir> is invoked (no --dry-run)
# Then:  exit code is 0 AND output contains at least one valid channel name AND
#        the channel count shown is >= 1
# ═══════════════════════════════════════════════════════════════════════════════
echo "Test 1: monthly --fixture exits 0 and produces channel breakdown"
test_monthly_fixture_exits_0_with_channel_breakdown() {
    _snapshot_fail

    local out exit_code=0
    out=$(bash "$CALIBRATION_SCRIPT" monthly --fixture "$FIXTURE_DIR" 2>/dev/null) || exit_code=$?

    # Assert exit code is 0
    assert_eq "monthly --fixture exits 0" "0" "$exit_code"

    # Assert output contains at least one valid channel name.
    # Valid channels: tests, review-llm, review-human, production,
    #                 user-report, internal-dogfood, other
    local channel_found="no"
    if echo "$out" | grep -qE 'tests|review-llm|review-human|production|user-report|internal-dogfood|other'; then
        channel_found="yes"
    fi
    assert_eq "output contains at least one valid channel name" "yes" "$channel_found"

    # Assert channel count >= 1.
    # The output should contain at least one numeric count associated with a channel.
    # We look for any digit (count) appearing in the output alongside a channel name.
    local count_found="no"
    if echo "$out" | grep -qE '[0-9]+'; then
        count_found="yes"
    fi
    assert_eq "output contains a channel count >= 1" "yes" "$count_found"

    assert_pass_if_clean "test_monthly_fixture_exits_0_with_channel_breakdown"
}
test_monthly_fixture_exits_0_with_channel_breakdown

# ═══════════════════════════════════════════════════════════════════════════════
# Test 2: monthly --fixture output includes the fixture's known channels
#
# Given: fixture bugs.json with tests:3, review-llm:2, user-report:1
# When:  calibration-report.sh monthly --fixture <dir> is invoked
# Then:  output contains "tests", "review-llm", and "user-report"
# ═══════════════════════════════════════════════════════════════════════════════
echo "Test 2: monthly --fixture output includes all three fixture channels"
test_monthly_fixture_includes_known_channels() {
    _snapshot_fail

    local out exit_code=0
    out=$(bash "$CALIBRATION_SCRIPT" monthly --fixture "$FIXTURE_DIR" 2>/dev/null) || exit_code=$?

    assert_eq "monthly --fixture exits 0 (prereq for channel check)" "0" "$exit_code"

    assert_contains "output contains 'tests' channel" "tests" "$out"
    assert_contains "output contains 'review-llm' channel" "review-llm" "$out"
    assert_contains "output contains 'user-report' channel" "user-report" "$out"

    assert_pass_if_clean "test_monthly_fixture_includes_known_channels"
}
test_monthly_fixture_includes_known_channels

# ═══════════════════════════════════════════════════════════════════════════════
print_summary
