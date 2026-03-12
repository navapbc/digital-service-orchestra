#!/usr/bin/env bash
# lockpick-workflow/tests/plugin/test-bench-tk-ready.sh
# Consolidated TDD test suite for lockpick-workflow/scripts/bench-tk-ready.sh
#
# TDD order: Written BEFORE creating bench-tk-ready.sh to confirm RED state.
# Run before the script exists to see failures; run after to confirm GREEN.
#
# Tests:
#   test_bench_file_exists                — script file exists on disk
#   test_bench_is_executable              — script has execute permission
#   test_bench_exits_zero_within_threshold — mock tk, generous threshold → exit 0
#   test_bench_exits_nonzero_when_slow    — mock tk, threshold=0 → non-zero exit
#   test_bench_exits_nonzero_when_tk_missing — tk not in PATH → non-zero exit
#   test_bench_outputs_timing_info        — stdout contains "tk ready retrieval time:"
#   test_bench_prints_warning_on_slow_tk  — stderr contains WARNING when threshold exceeded
#
# Usage:
#   bash lockpick-workflow/tests/plugin/test-bench-tk-ready.sh
#
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TARGET_SCRIPT="$PLUGIN_ROOT/scripts/bench-tk-ready.sh"

# Initialize pass/fail counters
PASS=0
FAIL=0

# Source shared assert helpers
# shellcheck source=../../tests/lib/assert.sh
source "$PLUGIN_ROOT/tests/lib/assert.sh"

echo "=== test-bench-tk-ready.sh ==="
echo ""

# ---------------------------------------------------------------------------
# Helper: make_mock_tk
# Creates a mock tk binary in a temp dir and returns the dir path.
# The mock exits immediately to simulate a fast tk invocation.
# ---------------------------------------------------------------------------
make_mock_tk() {
    local mock_dir
    mock_dir=$(mktemp -d)
    cat > "$mock_dir/tk" << 'MOCK'
#!/usr/bin/env bash
# Mock tk — fast, exits immediately
exit 0
MOCK
    chmod +x "$mock_dir/tk"
    echo "$mock_dir"
}

# ---------------------------------------------------------------------------
# Test group 1: File structure checks
# ---------------------------------------------------------------------------
echo "--- Structure ---"

# test_bench_file_exists
# Confirms the script exists on disk.
test_bench_file_exists() {
    assert_eq "test_bench_file_exists" "true" \
        "$(test -f "$TARGET_SCRIPT" && echo true || echo false)"
}

# test_bench_is_executable
# Confirms the script has execute permission.
test_bench_is_executable() {
    assert_eq "test_bench_is_executable" "true" \
        "$(test -x "$TARGET_SCRIPT" && echo true || echo false)"
}

test_bench_file_exists
test_bench_is_executable
echo ""

# ---------------------------------------------------------------------------
# Test group 2: Functional tests
# ---------------------------------------------------------------------------
echo "--- Functional ---"

# test_bench_exits_zero_within_threshold
# With a generous threshold (60s) and a mock tk that returns immediately,
# the script must exit 0.
test_bench_exits_zero_within_threshold() {
    if [ ! -f "$TARGET_SCRIPT" ]; then
        assert_eq "test_bench_exits_zero_within_threshold: file exists" "exists" "missing"
        return
    fi
    local mock_dir exit_code
    mock_dir=$(make_mock_tk)
    exit_code=0
    BENCH_THRESHOLD_SECONDS=60 PATH="$mock_dir:$PATH" \
        bash "$TARGET_SCRIPT" > /dev/null 2>&1 || exit_code=$?
    rm -rf "$mock_dir"
    assert_eq "test_bench_exits_zero_within_threshold: exit code is 0" "0" "$exit_code"
}

# test_bench_exits_nonzero_when_slow
# With threshold=0, any real invocation will exceed the threshold.
# Script must exit non-zero.
test_bench_exits_nonzero_when_slow() {
    if [ ! -f "$TARGET_SCRIPT" ]; then
        assert_eq "test_bench_exits_nonzero_when_slow: file exists" "exists" "missing"
        return
    fi
    local mock_dir exit_code
    mock_dir=$(make_mock_tk)
    exit_code=0
    BENCH_THRESHOLD_SECONDS=0 PATH="$mock_dir:$PATH" \
        bash "$TARGET_SCRIPT" > /dev/null 2>&1 || exit_code=$?
    rm -rf "$mock_dir"
    assert_ne "test_bench_exits_nonzero_when_slow: exit code is non-zero" "0" "$exit_code"
}

# test_bench_exits_nonzero_when_tk_missing
# When tk is not found in PATH, the script must exit non-zero immediately.
test_bench_exits_nonzero_when_tk_missing() {
    if [ ! -f "$TARGET_SCRIPT" ]; then
        assert_eq "test_bench_exits_nonzero_when_tk_missing: file exists" "exists" "missing"
        return
    fi
    local empty_dir exit_code
    empty_dir=$(mktemp -d)
    exit_code=0
    TK="$empty_dir/tk" PATH="$empty_dir" \
        bash "$TARGET_SCRIPT" > /dev/null 2>&1 || exit_code=$?
    rm -rf "$empty_dir"
    assert_ne "test_bench_exits_nonzero_when_tk_missing: exit code is non-zero" "0" "$exit_code"
}

# test_bench_outputs_timing_info
# The script must print "tk ready retrieval time:" to stdout so callers can
# observe the measured duration.
test_bench_outputs_timing_info() {
    if [ ! -f "$TARGET_SCRIPT" ]; then
        assert_eq "test_bench_outputs_timing_info: file exists" "exists" "missing"
        return
    fi
    local mock_dir stdout_output
    mock_dir=$(make_mock_tk)
    stdout_output=""
    stdout_output=$(BENCH_THRESHOLD_SECONDS=60 PATH="$mock_dir:$PATH" \
        bash "$TARGET_SCRIPT" 2>/dev/null) || true
    rm -rf "$mock_dir"
    assert_contains "test_bench_outputs_timing_info: timing line in stdout" \
        "tk ready retrieval time:" "$stdout_output"
}

# test_bench_prints_warning_on_slow_tk
# When threshold is exceeded, the script must print a WARNING to stderr.
test_bench_prints_warning_on_slow_tk() {
    if [ ! -f "$TARGET_SCRIPT" ]; then
        assert_eq "test_bench_prints_warning_on_slow_tk: file exists" "exists" "missing"
        return
    fi
    local mock_dir stderr_output
    mock_dir=$(make_mock_tk)
    stderr_output=""
    stderr_output=$(BENCH_THRESHOLD_SECONDS=0 PATH="$mock_dir:$PATH" \
        bash "$TARGET_SCRIPT" 2>&1 >/dev/null) || true
    rm -rf "$mock_dir"
    assert_contains "test_bench_prints_warning_on_slow_tk: WARNING in stderr" \
        "WARNING" "$stderr_output"
}

test_bench_exits_zero_within_threshold
test_bench_exits_nonzero_when_slow
test_bench_exits_nonzero_when_tk_missing
test_bench_outputs_timing_info
test_bench_prints_warning_on_slow_tk
echo ""

# ---------------------------------------------------------------------------
# Print summary and exit
# ---------------------------------------------------------------------------
print_summary
