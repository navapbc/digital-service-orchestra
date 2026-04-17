#!/usr/bin/env bash
# tests/unit/scripts/test-review-sample-files.sh
# TDD RED tests for plugins/dso/scripts/review-sample-files.sh
#
# Tests verify the review-sample-files script:
#   1. Selects exactly 7 files when given >7 eligible files (exit 0)
#   2. Selects exactly 7 files when given exactly 7 eligible files (exit 0)
#   3. Exits 1 with INSUFFICIENT_FILES when <7 eligible files exist
#   4. Excludes .test-index from the output
#   5. Excludes binary files (BINARY_MOCK_<basename>=1) from the output
#   6. Spreads selection across directories (≥3 distinct dirs)
#   7. Prioritizes highest line count files over low line count files
#
# Injection contract:
#   GIT_DIFF_MOCK          — newline-separated list of file paths (replaces git diff)
#   BINARY_MOCK_<basename> — set to 1 to mark a file as binary
#   LINE_COUNT_MOCK_<basename> — set to N to override the line count for a file
#
# Usage: bash tests/unit/scripts/test-review-sample-files.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"
SCRIPT="$REPO_ROOT/plugins/dso/scripts/review-sample-files.sh"

source "$REPO_ROOT/tests/lib/assert.sh"

echo "=== test-review-sample-files.sh ==="

# ── Test 1: Selects exactly 7 files from 10 eligible ─────────────────────────

test_sample_7_from_above_threshold() {
    _snapshot_fail

    local mock_list
    mock_list="$(printf '%s\n' \
        src/alpha/file1.sh \
        src/alpha/file2.sh \
        src/beta/file3.sh \
        src/beta/file4.sh \
        src/gamma/file5.sh \
        src/gamma/file6.sh \
        src/delta/file7.sh \
        src/delta/file8.sh \
        src/epsilon/file9.sh \
        src/epsilon/file10.sh \
    )"

    local output exit_code
    output=$(env GIT_DIFF_MOCK="$mock_list" bash "$SCRIPT" 2>/dev/null) && exit_code=$? || exit_code=$?

    assert_eq "test_sample_7_from_above_threshold: exits 0" "0" "$exit_code"

    local line_count
    line_count=$(printf '%s\n' "$output" | grep -c .) || line_count=0
    assert_eq "test_sample_7_from_above_threshold: exactly 7 lines on stdout" "7" "$line_count"

    assert_pass_if_clean "test_sample_7_from_above_threshold"
}

# ── Test 2: Selects exactly 7 files when exactly 7 eligible ──────────────────

test_sample_exactly_7_threshold() {
    _snapshot_fail

    local mock_list
    mock_list="$(printf '%s\n' \
        src/a/fileA.sh \
        src/b/fileB.sh \
        src/c/fileC.sh \
        src/d/fileD.sh \
        src/e/fileE.sh \
        src/f/fileF.sh \
        src/g/fileG.sh \
    )"

    local output exit_code
    output=$(env GIT_DIFF_MOCK="$mock_list" bash "$SCRIPT" 2>/dev/null) && exit_code=$? || exit_code=$?

    assert_eq "test_sample_exactly_7_threshold: exits 0" "0" "$exit_code"

    local line_count
    line_count=$(printf '%s\n' "$output" | grep -c .) || line_count=0
    assert_eq "test_sample_exactly_7_threshold: exactly 7 lines on stdout" "7" "$line_count"

    assert_pass_if_clean "test_sample_exactly_7_threshold"
}

# ── Test 3: Exits 1 with INSUFFICIENT_FILES when <7 eligible files ───────────

test_sample_below_threshold_exits_1() {
    _snapshot_fail

    local mock_list
    mock_list="$(printf '%s\n' \
        src/a/file1.sh \
        src/b/file2.sh \
        src/c/file3.sh \
        src/d/file4.sh \
        src/e/file5.sh \
        src/f/file6.sh \
    )"

    local output exit_code
    output=$(env GIT_DIFF_MOCK="$mock_list" bash "$SCRIPT" 2>&1) && exit_code=$? || exit_code=$?

    assert_eq "test_sample_below_threshold_exits_1: exits 1" "1" "$exit_code"
    assert_contains "test_sample_below_threshold_exits_1: INSUFFICIENT_FILES in output" \
        "INSUFFICIENT_FILES" "$output"

    assert_pass_if_clean "test_sample_below_threshold_exits_1"
}

# ── Test 4: Excludes .test-index from output ──────────────────────────────────

test_sample_excludes_test_index() {
    _snapshot_fail

    local mock_list
    mock_list="$(printf '%s\n' \
        .test-index \
        src/a/file1.sh \
        src/b/file2.sh \
        src/c/file3.sh \
        src/d/file4.sh \
        src/e/file5.sh \
        src/f/file6.sh \
        src/g/file7.sh \
    )"

    local output exit_code
    output=$(env GIT_DIFF_MOCK="$mock_list" bash "$SCRIPT" 2>/dev/null) && exit_code=$? || exit_code=$?

    # With 7 eligible files (excluding .test-index), should still succeed
    assert_eq "test_sample_excludes_test_index: exits 0" "0" "$exit_code"
    assert_ne "test_sample_excludes_test_index: .test-index absent from stdout" \
        "1" "$(printf '%s\n' "$output" | grep -c '.test-index' || echo 0)"

    assert_pass_if_clean "test_sample_excludes_test_index"
}

# ── Test 5: Excludes binary files from output ─────────────────────────────────

test_sample_excludes_binary() {
    _snapshot_fail

    local mock_list
    mock_list="$(printf '%s\n' \
        src/images/logo.png \
        src/a/file1.sh \
        src/b/file2.sh \
        src/c/file3.sh \
        src/d/file4.sh \
        src/e/file5.sh \
        src/f/file6.sh \
        src/g/file7.sh \
    )"

    local output exit_code
    output=$(env GIT_DIFF_MOCK="$mock_list" BINARY_MOCK_logo.png=1 bash "$SCRIPT" 2>/dev/null) && exit_code=$? || exit_code=$?

    assert_eq "test_sample_excludes_binary: exits 0" "0" "$exit_code"
    assert_ne "test_sample_excludes_binary: logo.png absent from stdout" \
        "1" "$(printf '%s\n' "$output" | grep -c 'logo.png' || echo 0)"

    assert_pass_if_clean "test_sample_excludes_binary"
}

# ── Test 6: Spreads selection across directories ──────────────────────────────

test_sample_directory_spread() {
    _snapshot_fail

    # 10 files across 5 dirs, 2 per dir
    local mock_list
    mock_list="$(printf '%s\n' \
        src/dir1/fileA.sh \
        src/dir1/fileB.sh \
        src/dir2/fileC.sh \
        src/dir2/fileD.sh \
        src/dir3/fileE.sh \
        src/dir3/fileF.sh \
        src/dir4/fileG.sh \
        src/dir4/fileH.sh \
        src/dir5/fileI.sh \
        src/dir5/fileJ.sh \
    )"

    local output exit_code
    output=$(env GIT_DIFF_MOCK="$mock_list" bash "$SCRIPT" 2>/dev/null) && exit_code=$? || exit_code=$?

    assert_eq "test_sample_directory_spread: exits 0" "0" "$exit_code"

    # Count distinct parent directories in output
    local distinct_dirs
    distinct_dirs=$(printf '%s\n' "$output" | awk -F/ 'NF>=3{print $(NF-1)}' | sort -u | wc -l | tr -d ' ')
    # At least 3 distinct directories represented
    local spread_ok
    spread_ok=0
    [[ "$distinct_dirs" -ge 3 ]] && spread_ok=1
    assert_eq "test_sample_directory_spread: output spans ≥3 dirs (got $distinct_dirs)" "1" "$spread_ok"

    assert_pass_if_clean "test_sample_directory_spread"
}

# ── Test 7: Prioritizes highest line count files ──────────────────────────────

test_sample_highest_line_count_priority() {
    _snapshot_fail

    # 10 files: 7 with LINE_COUNT_MOCK=100, 3 with LINE_COUNT_MOCK=5
    # The 3 low-count files should be excluded when selecting top 7
    local mock_list
    mock_list="$(printf '%s\n' \
        src/a/high1.sh \
        src/b/high2.sh \
        src/c/high3.sh \
        src/d/high4.sh \
        src/e/high5.sh \
        src/f/high6.sh \
        src/g/high7.sh \
        src/h/low1.sh \
        src/i/low2.sh \
        src/j/low3.sh \
    )"

    local output exit_code
    output=$(env GIT_DIFF_MOCK="$mock_list" \
        LINE_COUNT_MOCK_high1.sh=100 \
        LINE_COUNT_MOCK_high2.sh=100 \
        LINE_COUNT_MOCK_high3.sh=100 \
        LINE_COUNT_MOCK_high4.sh=100 \
        LINE_COUNT_MOCK_high5.sh=100 \
        LINE_COUNT_MOCK_high6.sh=100 \
        LINE_COUNT_MOCK_high7.sh=100 \
        LINE_COUNT_MOCK_low1.sh=5 \
        LINE_COUNT_MOCK_low2.sh=5 \
        LINE_COUNT_MOCK_low3.sh=5 \
        bash "$SCRIPT" 2>/dev/null) && exit_code=$? || exit_code=$?

    assert_eq "test_sample_highest_line_count_priority: exits 0" "0" "$exit_code"

    # All 3 low-count files must be absent from the 7-file output
    # Note: grep -c outputs the match count on stdout even when exit=1 (no matches).
    # Capture via subshell; the || true prevents pipefail from aborting.
    local low1_present low2_present low3_present
    low1_present=$(printf '%s\n' "$output" | grep -c 'low1.sh' || true)
    low2_present=$(printf '%s\n' "$output" | grep -c 'low2.sh' || true)
    low3_present=$(printf '%s\n' "$output" | grep -c 'low3.sh' || true)

    assert_eq "test_sample_highest_line_count_priority: low1.sh absent" "0" "$low1_present"
    assert_eq "test_sample_highest_line_count_priority: low2.sh absent" "0" "$low2_present"
    assert_eq "test_sample_highest_line_count_priority: low3.sh absent" "0" "$low3_present"

    assert_pass_if_clean "test_sample_highest_line_count_priority"
}

# ── Run all tests ─────────────────────────────────────────────────────────────

test_sample_7_from_above_threshold
test_sample_exactly_7_threshold
test_sample_below_threshold_exits_1
test_sample_excludes_test_index
test_sample_excludes_binary
test_sample_directory_spread
test_sample_highest_line_count_priority

print_summary
