#!/usr/bin/env bash
# tests/hooks/test-suite-engine-eagain.sh
# Behavioral tests for EAGAIN detection and retry in suite-engine.sh.
#
# Tests exercise run_test_suite with mock test scripts that simulate EAGAIN
# failures (exit code 254 + stderr containing an EAGAIN pattern). The suite
# engine is expected to detect these conditions and retry the test with
# MAX_PARALLEL=1.
#
# All tests are RED before EAGAIN retry logic is implemented in suite-engine.sh.
#
# Tests:
#   test_eagain_retry_on_exit254_with_pattern
#   test_no_retry_exit254_without_pattern
#   test_no_retry_with_pattern_wrong_exit
#   test_retry_result_is_authoritative
#   test_retry_failure_falls_through
#   test_eagain_blocking_io_pattern
#
# Usage: bash tests/hooks/test-suite-engine-eagain.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$SCRIPT_DIR/../lib"

source "$LIB_DIR/assert.sh"

_TEST_TMPDIRS=()
_cleanup_all() {
    for d in "${_TEST_TMPDIRS[@]}"; do
        rm -rf "$d"
    done
}
trap '_cleanup_all' EXIT

_make_tmpdir() {
    local d
    d=$(mktemp -d)
    _TEST_TMPDIRS+=("$d")
    echo "$d"
}

# ---------------------------------------------------------------------------
# test_eagain_retry_on_exit254_with_pattern
#
# A mock test exits 254 on first call (with EAGAIN pattern in output) and
# exits 0 on the second call. The suite engine should retry it, and the final
# result for that test file should be PASS, not FAIL.
#
# MAX_PARALLEL must be 1 during the retry. We capture the value the mock sees
# by writing it to a state file on each invocation.
# ---------------------------------------------------------------------------
test_eagain_retry_on_exit254_with_pattern() {
    local mock_dir
    mock_dir=$(_make_tmpdir)
    local state_file="$mock_dir/call_count"
    local parallel_log="$mock_dir/parallel_values"
    echo "0" > "$state_file"

    # Mock test: first call exits 254 + prints EAGAIN pattern;
    # second call records MAX_PARALLEL and exits 0.
    cat > "$mock_dir/test-eagain-mock.sh" <<'MOCK'
#!/usr/bin/env bash
STATE_FILE="__STATE_FILE__"
PARALLEL_LOG="__PARALLEL_LOG__"
count=$(cat "$STATE_FILE")
count=$(( count + 1 ))
echo "$count" > "$STATE_FILE"
echo "${MAX_PARALLEL:-unset}" >> "$PARALLEL_LOG"
if [ "$count" -eq 1 ]; then
    echo "fork: Resource temporarily unavailable" >&2
    echo "PASSED: 0  FAILED: 1"
    exit 254
fi
echo "PASSED: 1  FAILED: 0"
exit 0
MOCK
    # Substitute the actual state-file paths into the mock
    sed -i.bak "s|__STATE_FILE__|$state_file|g" "$mock_dir/test-eagain-mock.sh"
    sed -i.bak "s|__PARALLEL_LOG__|$parallel_log|g" "$mock_dir/test-eagain-mock.sh"
    chmod +x "$mock_dir/test-eagain-mock.sh"

    local suite_output
    suite_output=$(
        MAX_PARALLEL=4 TEST_TIMEOUT=15 MAX_CONSECUTIVE_FAILS=10 \
        bash "$LIB_DIR/suite-engine.sh" "$mock_dir/test-eagain-mock.sh" 2>&1
    ) || true

    # The test should have been called twice (retry occurred)
    local final_count
    final_count=$(cat "$state_file")
    assert_eq "eagain_retry: mock called twice" "2" "$final_count"

    # Suite output should report PASS, not FAIL, for the test file
    assert_contains "eagain_retry: suite reports PASS" "test-eagain-mock.sh ... PASS" "$suite_output"

    # MAX_PARALLEL during the retry call (second invocation) should be 1
    local parallel_on_retry
    parallel_on_retry=$(sed -n '2p' "$parallel_log")
    assert_eq "eagain_retry: MAX_PARALLEL=1 during retry" "1" "$parallel_on_retry"

    # Overall suite exit should be 0 (no failures)
    local suite_exit=0
    MAX_PARALLEL=4 TEST_TIMEOUT=15 MAX_CONSECUTIVE_FAILS=10 \
        bash "$LIB_DIR/suite-engine.sh" "$mock_dir/test-eagain-mock.sh" > /dev/null 2>&1 || suite_exit=$?
    # Reset state for the re-run
    echo "0" > "$state_file"
    > "$parallel_log"
    suite_exit=0
    MAX_PARALLEL=4 TEST_TIMEOUT=15 MAX_CONSECUTIVE_FAILS=10 \
        bash "$LIB_DIR/suite-engine.sh" "$mock_dir/test-eagain-mock.sh" > /dev/null 2>&1 || suite_exit=$?
    assert_eq "eagain_retry: suite exits 0" "0" "$suite_exit"
}

# ---------------------------------------------------------------------------
# test_no_retry_exit254_without_pattern
#
# A mock exits 254 but does NOT include the EAGAIN pattern in its output.
# The suite engine must NOT retry it — the mock should be called exactly once
# and the suite should report FAIL.
# ---------------------------------------------------------------------------
test_no_retry_exit254_without_pattern() {
    local mock_dir
    mock_dir=$(_make_tmpdir)
    local state_file="$mock_dir/call_count"
    echo "0" > "$state_file"

    cat > "$mock_dir/test-no-eagain-mock.sh" <<'MOCK'
#!/usr/bin/env bash
STATE_FILE="__STATE_FILE__"
count=$(cat "$STATE_FILE")
count=$(( count + 1 ))
echo "$count" > "$STATE_FILE"
# Exit 254 but NO EAGAIN message — should NOT trigger retry
echo "some other error, not resource-related" >&2
echo "PASSED: 0  FAILED: 1"
exit 254
MOCK
    sed -i.bak "s|__STATE_FILE__|$state_file|g" "$mock_dir/test-no-eagain-mock.sh"
    chmod +x "$mock_dir/test-no-eagain-mock.sh"

    local suite_output
    suite_output=$(
        MAX_PARALLEL=4 TEST_TIMEOUT=15 MAX_CONSECUTIVE_FAILS=10 \
        bash "$LIB_DIR/suite-engine.sh" "$mock_dir/test-no-eagain-mock.sh" 2>&1
    ) || true

    # Mock should have been called exactly once (no retry)
    local final_count
    final_count=$(cat "$state_file")
    assert_eq "no_retry_no_pattern: mock called once" "1" "$final_count"

    # Suite should report FAIL for the test
    assert_contains "no_retry_no_pattern: suite reports FAIL" "test-no-eagain-mock.sh ... FAIL" "$suite_output"
}

# ---------------------------------------------------------------------------
# test_no_retry_with_pattern_wrong_exit
#
# A mock exits 1 (not 254) but outputs the EAGAIN pattern.
# Retry must NOT trigger — exit code 254 is required.
# ---------------------------------------------------------------------------
test_no_retry_with_pattern_wrong_exit() {
    local mock_dir
    mock_dir=$(_make_tmpdir)
    local state_file="$mock_dir/call_count"
    echo "0" > "$state_file"

    cat > "$mock_dir/test-wrong-exit-mock.sh" <<'MOCK'
#!/usr/bin/env bash
STATE_FILE="__STATE_FILE__"
count=$(cat "$STATE_FILE")
count=$(( count + 1 ))
echo "$count" > "$STATE_FILE"
# EAGAIN pattern present but exit code is 1, not 254
echo "fork: Resource temporarily unavailable" >&2
echo "PASSED: 0  FAILED: 1"
exit 1
MOCK
    sed -i.bak "s|__STATE_FILE__|$state_file|g" "$mock_dir/test-wrong-exit-mock.sh"
    chmod +x "$mock_dir/test-wrong-exit-mock.sh"

    local suite_output
    suite_output=$(
        MAX_PARALLEL=4 TEST_TIMEOUT=15 MAX_CONSECUTIVE_FAILS=10 \
        bash "$LIB_DIR/suite-engine.sh" "$mock_dir/test-wrong-exit-mock.sh" 2>&1
    ) || true

    # Mock called exactly once (no retry triggered)
    local final_count
    final_count=$(cat "$state_file")
    assert_eq "no_retry_wrong_exit: mock called once" "1" "$final_count"

    # Suite should report FAIL
    assert_contains "no_retry_wrong_exit: suite reports FAIL" "test-wrong-exit-mock.sh ... FAIL" "$suite_output"
}

# ---------------------------------------------------------------------------
# test_retry_result_is_authoritative
#
# Mock exits 254+EAGAIN on first call, then exits 0 with 3 passing assertions
# on the second call. The suite must report the PASS counts from the retry run,
# not from the first (failed) run.
# ---------------------------------------------------------------------------
test_retry_result_is_authoritative() {
    local mock_dir
    mock_dir=$(_make_tmpdir)
    local state_file="$mock_dir/call_count"
    echo "0" > "$state_file"

    cat > "$mock_dir/test-retry-auth-mock.sh" <<'MOCK'
#!/usr/bin/env bash
STATE_FILE="__STATE_FILE__"
count=$(cat "$STATE_FILE")
count=$(( count + 1 ))
echo "$count" > "$STATE_FILE"
if [ "$count" -eq 1 ]; then
    echo "fork: Resource temporarily unavailable" >&2
    echo "PASSED: 0  FAILED: 1"
    exit 254
fi
# Second call: clean run with 3 assertions passing
echo "PASSED: 3  FAILED: 0"
exit 0
MOCK
    sed -i.bak "s|__STATE_FILE__|$state_file|g" "$mock_dir/test-retry-auth-mock.sh"
    chmod +x "$mock_dir/test-retry-auth-mock.sh"

    local suite_output
    suite_output=$(
        MAX_PARALLEL=4 TEST_TIMEOUT=15 MAX_CONSECUTIVE_FAILS=10 \
        bash "$LIB_DIR/suite-engine.sh" "$mock_dir/test-retry-auth-mock.sh" 2>&1
    ) || true

    # The suite line for this test must show PASS, not FAIL or TOLERATED
    assert_contains "retry_authoritative: suite line shows PASS" "test-retry-auth-mock.sh ... PASS" "$suite_output"

    # The summary must reflect the retry's pass count (3), not the first run's fail count
    assert_contains "retry_authoritative: summary shows 3 passed" "PASSED: 3" "$suite_output"

    # FAILED count in summary must be 0
    assert_contains "retry_authoritative: summary shows 0 failed" "FAILED: 0" "$suite_output"
}

# ---------------------------------------------------------------------------
# test_retry_failure_falls_through
#
# Mock exits 254+EAGAIN on every call. Even after retry, the test fails.
# The suite must report FAIL and exit non-zero.
# ---------------------------------------------------------------------------
test_retry_failure_falls_through() {
    local mock_dir
    mock_dir=$(_make_tmpdir)
    local state_file="$mock_dir/call_count"
    echo "0" > "$state_file"

    cat > "$mock_dir/test-retry-fail-mock.sh" <<'MOCK'
#!/usr/bin/env bash
STATE_FILE="__STATE_FILE__"
count=$(cat "$STATE_FILE")
count=$(( count + 1 ))
echo "$count" > "$STATE_FILE"
# Always exit 254 + EAGAIN pattern — retry should not help
echo "fork: Resource temporarily unavailable" >&2
echo "PASSED: 0  FAILED: 1"
exit 254
MOCK
    sed -i.bak "s|__STATE_FILE__|$state_file|g" "$mock_dir/test-retry-fail-mock.sh"
    chmod +x "$mock_dir/test-retry-fail-mock.sh"

    local suite_output
    suite_output=$(
        MAX_PARALLEL=4 TEST_TIMEOUT=15 MAX_CONSECUTIVE_FAILS=10 \
        bash "$LIB_DIR/suite-engine.sh" "$mock_dir/test-retry-fail-mock.sh" 2>&1
    ) || true

    # Suite must report FAIL for this test (not PASS, not TOLERATED)
    assert_contains "retry_falls_through: suite reports FAIL" "test-retry-fail-mock.sh ... FAIL" "$suite_output"

    # Suite must exit non-zero
    local suite_exit=0
    MAX_PARALLEL=4 TEST_TIMEOUT=15 MAX_CONSECUTIVE_FAILS=10 \
        bash "$LIB_DIR/suite-engine.sh" "$mock_dir/test-retry-fail-mock.sh" > /dev/null 2>&1 \
        || suite_exit=$?
    # Reset state so this second run also starts from count=0 and triggers retry
    echo "0" > "$state_file"
    suite_exit=0
    MAX_PARALLEL=4 TEST_TIMEOUT=15 MAX_CONSECUTIVE_FAILS=10 \
        bash "$LIB_DIR/suite-engine.sh" "$mock_dir/test-retry-fail-mock.sh" > /dev/null 2>&1 \
        || suite_exit=$?
    assert_ne "retry_falls_through: suite exits non-zero" "0" "$suite_exit"
}

# ---------------------------------------------------------------------------
# test_eagain_blocking_io_pattern
#
# Same retry flow but triggered by the alternate EAGAIN pattern:
# "BlockingIOError: [Errno 35] Resource temporarily unavailable"
# ---------------------------------------------------------------------------
test_eagain_blocking_io_pattern() {
    local mock_dir
    mock_dir=$(_make_tmpdir)
    local state_file="$mock_dir/call_count"
    echo "0" > "$state_file"

    cat > "$mock_dir/test-blocking-io-mock.sh" <<'MOCK'
#!/usr/bin/env bash
STATE_FILE="__STATE_FILE__"
count=$(cat "$STATE_FILE")
count=$(( count + 1 ))
echo "$count" > "$STATE_FILE"
if [ "$count" -eq 1 ]; then
    echo "BlockingIOError: [Errno 35] Resource temporarily unavailable" >&2
    echo "PASSED: 0  FAILED: 1"
    exit 254
fi
echo "PASSED: 1  FAILED: 0"
exit 0
MOCK
    sed -i.bak "s|__STATE_FILE__|$state_file|g" "$mock_dir/test-blocking-io-mock.sh"
    chmod +x "$mock_dir/test-blocking-io-mock.sh"

    local suite_output
    suite_output=$(
        MAX_PARALLEL=4 TEST_TIMEOUT=15 MAX_CONSECUTIVE_FAILS=10 \
        bash "$LIB_DIR/suite-engine.sh" "$mock_dir/test-blocking-io-mock.sh" 2>&1
    ) || true

    # Mock should have been called twice (retry occurred for BlockingIOError pattern)
    local final_count
    final_count=$(cat "$state_file")
    assert_eq "blocking_io_retry: mock called twice" "2" "$final_count"

    # Suite output should report PASS
    assert_contains "blocking_io_retry: suite reports PASS" "test-blocking-io-mock.sh ... PASS" "$suite_output"
}

# Run all test functions
test_eagain_retry_on_exit254_with_pattern
test_no_retry_exit254_without_pattern
test_no_retry_with_pattern_wrong_exit
test_retry_result_is_authoritative
test_retry_failure_falls_through
test_eagain_blocking_io_pattern

print_summary
