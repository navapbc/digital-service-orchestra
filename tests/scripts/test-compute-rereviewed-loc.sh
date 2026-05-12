#!/usr/bin/env bash
# tests/scripts/test-compute-rereviewed-loc.sh
# Behavioral tests for plugins/dso/scripts/sprint/compute-rereviewed-loc.sh
#
# Computes what percentage of LOC in a given epic sprint was "re-reviewed"
# (reviewed more than once due to changes). Takes epic ID and review log dir.
#
# All 5 tests FAIL RED because the script does not exist yet.
#
# Usage: bash tests/scripts/test-compute-rereviewed-loc.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SCRIPT="$PLUGIN_ROOT/plugins/dso/scripts/sprint/compute-rereviewed-loc.sh"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

echo "=== test-compute-rereviewed-loc.sh ==="

# ── Setup ────────────────────────────────────────────────────────────────────
TMPDIR_TEST="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_TEST"' EXIT

EPIC_ID="test-epic-001"
REVIEW_LOG_DIR="$TMPDIR_TEST/review-logs"
mkdir -p "$REVIEW_LOG_DIR"

# ─────────────────────────────────────────────────────────────────────────────
# test_script_exists
# Script must exist at plugins/dso/scripts/sprint/compute-rereviewed-loc.sh
# FAIL RED: script is absent
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "--- test_script_exists ---"
_snapshot_fail

if [[ -f "$SCRIPT" ]]; then
    (( ++PASS ))
    echo "test_script_exists ... PASS"
else
    (( ++FAIL ))
    printf "FAIL: test_script_exists\n  expected: file exists at %s\n  actual:   file not found\n" "$SCRIPT" >&2
fi

assert_pass_if_clean "test_script_exists"

# ─────────────────────────────────────────────────────────────────────────────
# test_exit_0_with_valid_args
# Script exits 0 when called with valid epic ID and review log directory
# FAIL RED: script is absent
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "--- test_exit_0_with_valid_args ---"
_snapshot_fail

if [[ -f "$SCRIPT" ]]; then
    rc=0
    bash "$SCRIPT" "$EPIC_ID" "$REVIEW_LOG_DIR" >/dev/null 2>&1 || rc=$?
    assert_eq "test_exit_0_with_valid_args exit code" "0" "$rc"
else
    (( ++FAIL ))
    printf "FAIL: test_exit_0_with_valid_args\n  script not found at %s\n" "$SCRIPT" >&2
fi

assert_pass_if_clean "test_exit_0_with_valid_args"

# ─────────────────────────────────────────────────────────────────────────────
# test_outputs_ratio_line
# Output must contain a line matching "re-review ratio: [0-9]" pattern
# FAIL RED: script is absent
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "--- test_outputs_ratio_line ---"
_snapshot_fail

if [[ -f "$SCRIPT" ]]; then
    output=""
    output=$(bash "$SCRIPT" "$EPIC_ID" "$REVIEW_LOG_DIR" 2>&1) || true
    if echo "$output" | grep -qE "re-review ratio: [0-9]"; then
        (( ++PASS ))
        echo "test_outputs_ratio_line ... PASS"
    else
        (( ++FAIL ))
        printf "FAIL: test_outputs_ratio_line\n  expected output matching 're-review ratio: [0-9]'\n  actual: %s\n" "$output" >&2
    fi
else
    (( ++FAIL ))
    printf "FAIL: test_outputs_ratio_line\n  script not found at %s\n" "$SCRIPT" >&2
fi

assert_pass_if_clean "test_outputs_ratio_line"

# ─────────────────────────────────────────────────────────────────────────────
# test_ratio_below_threshold_exits_0
# When re-review ratio < 50, script exits 0 (acceptable)
# FAIL RED: script is absent
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "--- test_ratio_below_threshold_exits_0 ---"
_snapshot_fail

if [[ -f "$SCRIPT" ]]; then
    # Write a review log representing low re-review ratio (< 50%)
    LOW_RATIO_DIR="$TMPDIR_TEST/review-logs-low"
    mkdir -p "$LOW_RATIO_DIR"
    # 10 LOC total reviewed, 4 LOC re-reviewed = 40% ratio (below 50 threshold)
    printf '{"epic_id":"%s","total_loc_reviewed":10,"rereviewed_loc":4}\n' "$EPIC_ID" \
        > "$LOW_RATIO_DIR/review-summary.json"

    rc=0
    bash "$SCRIPT" "$EPIC_ID" "$LOW_RATIO_DIR" >/dev/null 2>&1 || rc=$?
    assert_eq "test_ratio_below_threshold_exits_0 exit code" "0" "$rc"
else
    (( ++FAIL ))
    printf "FAIL: test_ratio_below_threshold_exits_0\n  script not found at %s\n" "$SCRIPT" >&2
fi

assert_pass_if_clean "test_ratio_below_threshold_exits_0"

# ─────────────────────────────────────────────────────────────────────────────
# test_ratio_above_threshold_exits_1
# When re-review ratio >= 50, script exits 1 (threshold exceeded)
# FAIL RED: script is absent
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "--- test_ratio_above_threshold_exits_1 ---"
_snapshot_fail

if [[ -f "$SCRIPT" ]]; then
    # Write a review log representing high re-review ratio (>= 50%)
    HIGH_RATIO_DIR="$TMPDIR_TEST/review-logs-high"
    mkdir -p "$HIGH_RATIO_DIR"
    # 10 LOC total reviewed, 6 LOC re-reviewed = 60% ratio (above 50 threshold)
    printf '{"epic_id":"%s","total_loc_reviewed":10,"rereviewed_loc":6}\n' "$EPIC_ID" \
        > "$HIGH_RATIO_DIR/review-summary.json"

    rc=0
    bash "$SCRIPT" "$EPIC_ID" "$HIGH_RATIO_DIR" >/dev/null 2>&1 || rc=$?
    assert_eq "test_ratio_above_threshold_exits_1 exit code" "1" "$rc"
else
    (( ++FAIL ))
    printf "FAIL: test_ratio_above_threshold_exits_1\n  script not found at %s\n" "$SCRIPT" >&2
fi

assert_pass_if_clean "test_ratio_above_threshold_exits_1"

# ─────────────────────────────────────────────────────────────────────────────
# Summary
# ─────────────────────────────────────────────────────────────────────────────
print_summary
