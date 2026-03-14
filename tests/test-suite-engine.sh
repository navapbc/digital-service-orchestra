#!/usr/bin/env bash
# lockpick-workflow/tests/test-suite-engine.sh
# TDD tests for the suite-engine shared library (parallel runner, timeouts,
# fail-fast, progress reporting).
#
# Tests:
#   1. test_timeout_kills_slow_test
#   2. test_parallel_faster_than_serial
#   3. test_fail_fast_aborts_after_threshold
#   4. test_progress_shows_counter
#   5. test_pass_fail_counts_aggregated
#   6. test_timeout_exit_reported_distinctly
#   7. test_max_parallel_env_respected
#   8. test_consecutive_fail_resets_on_pass

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null)"

source "$SCRIPT_DIR/lib/assert.sh"

MOCK_DIR=$(mktemp -d)
trap 'rm -rf "$MOCK_DIR"' EXIT

# --- Helper: create a mock test script ---
# Usage: make_mock_test <name> <exit_code> <pass_count> <fail_count> [sleep_seconds]
make_mock_test() {
    local name="$1" exit_code="$2" pass_count="$3" fail_count="$4" sleep_secs="${5:-0}"
    local path="$MOCK_DIR/$name"
    cat > "$path" <<TESTEOF
#!/usr/bin/env bash
if [ "$sleep_secs" -gt 0 ]; then sleep $sleep_secs; fi
echo "PASSED: $pass_count  FAILED: $fail_count"
exit $exit_code
TESTEOF
    chmod +x "$path"
    echo "$path"
}

# Helper: create a mock test using Results: format
make_mock_test_results_fmt() {
    local name="$1" exit_code="$2" pass_count="$3" fail_count="$4" sleep_secs="${5:-0}"
    local path="$MOCK_DIR/$name"
    cat > "$path" <<TESTEOF
#!/usr/bin/env bash
if [ "$sleep_secs" -gt 0 ]; then sleep $sleep_secs; fi
echo "Results: $pass_count passed, $fail_count failed"
exit $exit_code
TESTEOF
    chmod +x "$path"
    echo "$path"
}

# --- Test 1: timeout kills slow test ---
test_timeout_kills_slow_test() {
    _snapshot_fail
    local slow_test
    slow_test=$(make_mock_test "test-slow.sh" 0 1 0 60)

    local results_dir
    results_dir=$(mktemp -d)

    # Run suite-engine with 2-second timeout on the single slow test
    local output exit_code=0
    output=$(TEST_TIMEOUT=2 MAX_PARALLEL=1 MAX_CONSECUTIVE_FAILS=999 \
        bash "$SCRIPT_DIR/lib/suite-engine.sh" "$slow_test" 2>&1) || exit_code=$?

    assert_ne "timeout: exit code is non-zero" "0" "$exit_code"
    assert_contains "timeout: output mentions TIMEOUT" "TIMEOUT" "$output"

    rm -rf "$results_dir"
    assert_pass_if_clean "test_timeout_kills_slow_test"
}

# --- Test 2: parallel execution faster than serial ---
test_parallel_faster_than_serial() {
    _snapshot_fail
    # Create 4 tests that each sleep 2 seconds
    local tests=()
    for i in 1 2 3 4; do
        tests+=("$(make_mock_test "test-sleep-$i.sh" 0 1 0 2)")
    done

    local start_time end_time elapsed
    start_time=$(date +%s)

    local output exit_code=0
    output=$(TEST_TIMEOUT=10 MAX_PARALLEL=4 MAX_CONSECUTIVE_FAILS=999 \
        bash "$SCRIPT_DIR/lib/suite-engine.sh" "${tests[@]}" 2>&1) || exit_code=$?

    end_time=$(date +%s)
    elapsed=$(( end_time - start_time ))

    # Serial would be 8s. Parallel with 4 workers should be ~2-3s.
    # Allow up to 5s for overhead.
    if [ "$elapsed" -le 5 ]; then
        (( ++PASS ))
    else
        (( ++FAIL ))
        printf "FAIL: parallel: took %ds, expected ≤5s (serial would be 8s)\n" "$elapsed" >&2
    fi

    assert_eq "parallel: exit code 0" "0" "$exit_code"
    assert_pass_if_clean "test_parallel_faster_than_serial"
}

# --- Test 3: fail-fast aborts after threshold ---
test_fail_fast_aborts_after_threshold() {
    _snapshot_fail
    # Create 10 tests: first 5 fail, rest pass
    local tests=()
    for i in $(seq 1 5); do
        tests+=("$(make_mock_test "test-fail-$i.sh" 1 0 1 0)")
    done
    for i in $(seq 6 10); do
        tests+=("$(make_mock_test "test-pass-$i.sh" 0 1 0 0)")
    done

    local output exit_code=0
    # MAX_PARALLEL=1 to ensure sequential order for deterministic fail-fast
    output=$(TEST_TIMEOUT=5 MAX_PARALLEL=1 MAX_CONSECUTIVE_FAILS=3 \
        bash "$SCRIPT_DIR/lib/suite-engine.sh" "${tests[@]}" 2>&1) || exit_code=$?

    assert_ne "fail-fast: exit code non-zero" "0" "$exit_code"
    assert_contains "fail-fast: output mentions ABORT" "ABORT" "$output"

    # Should NOT have run all 10 tests — check that test-pass-10 is absent
    if echo "$output" | grep -q "test-pass-10.sh"; then
        (( ++FAIL ))
        echo "FAIL: fail-fast: test-pass-10.sh should not have run" >&2
    else
        (( ++PASS ))
    fi

    assert_pass_if_clean "test_fail_fast_aborts_after_threshold"
}

# --- Test 4: progress counter shown ---
test_progress_shows_counter() {
    _snapshot_fail
    local tests=()
    for i in 1 2 3; do
        tests+=("$(make_mock_test "test-prog-$i.sh" 0 1 0 0)")
    done

    local output
    output=$(TEST_TIMEOUT=5 MAX_PARALLEL=1 MAX_CONSECUTIVE_FAILS=999 \
        bash "$SCRIPT_DIR/lib/suite-engine.sh" "${tests[@]}" 2>&1) || true

    assert_contains "progress: shows [1/3]" "[1/3]" "$output"
    assert_contains "progress: shows [2/3]" "[2/3]" "$output"
    assert_contains "progress: shows [3/3]" "[3/3]" "$output"
    assert_pass_if_clean "test_progress_shows_counter"
}

# --- Test 5: PASS/FAIL counts aggregated correctly ---
test_pass_fail_counts_aggregated() {
    _snapshot_fail
    # Test 1: 3 pass, 0 fail. Test 2: 2 pass, 1 fail. Total: 5 pass, 1 fail
    local test1 test2
    test1=$(make_mock_test "test-agg1.sh" 0 3 0 0)
    test2=$(make_mock_test "test-agg2.sh" 1 2 1 0)

    local output
    output=$(TEST_TIMEOUT=5 MAX_PARALLEL=1 MAX_CONSECUTIVE_FAILS=999 \
        bash "$SCRIPT_DIR/lib/suite-engine.sh" "$test1" "$test2" 2>&1) || true

    assert_contains "aggregated: total pass 5" "PASSED: 5" "$output"
    assert_contains "aggregated: total fail 1" "FAILED: 1" "$output"
    assert_pass_if_clean "test_pass_fail_counts_aggregated"
}

# --- Test 6: timeout exit code reported distinctly ---
test_timeout_exit_reported_distinctly() {
    _snapshot_fail
    local slow_test
    slow_test=$(make_mock_test "test-timeout-report.sh" 0 1 0 60)

    local output
    output=$(TEST_TIMEOUT=2 MAX_PARALLEL=1 MAX_CONSECUTIVE_FAILS=999 \
        bash "$SCRIPT_DIR/lib/suite-engine.sh" "$slow_test" 2>&1) || true

    # Output should show the test name with TIMEOUT label
    assert_contains "timeout-report: names the test" "test-timeout-report.sh" "$output"
    assert_contains "timeout-report: says TIMEOUT" "TIMEOUT" "$output"
    assert_pass_if_clean "test_timeout_exit_reported_distinctly"
}

# --- Test 7: MAX_PARALLEL respected ---
test_max_parallel_env_respected() {
    _snapshot_fail
    # 4 tests that sleep 2s each, MAX_PARALLEL=2
    # Should take ~4s (2 batches of 2), not 2s (1 batch of 4)
    local tests=()
    for i in 1 2 3 4; do
        tests+=("$(make_mock_test "test-par-$i.sh" 0 1 0 2)")
    done

    local start_time end_time elapsed
    start_time=$(date +%s)

    local output
    output=$(TEST_TIMEOUT=10 MAX_PARALLEL=2 MAX_CONSECUTIVE_FAILS=999 \
        bash "$SCRIPT_DIR/lib/suite-engine.sh" "${tests[@]}" 2>&1) || true

    end_time=$(date +%s)
    elapsed=$(( end_time - start_time ))

    # With MAX_PARALLEL=2 and 4 tests sleeping 2s: ~4s. Must be >3s.
    if [ "$elapsed" -ge 3 ]; then
        (( ++PASS ))
    else
        (( ++FAIL ))
        printf "FAIL: max_parallel: took %ds, expected ≥3s with MAX_PARALLEL=2\n" "$elapsed" >&2
    fi
    assert_pass_if_clean "test_max_parallel_env_respected"
}

# --- Test 8: consecutive fail counter resets on pass ---
test_consecutive_fail_resets_on_pass() {
    _snapshot_fail
    # Pattern: fail, fail, PASS, fail, fail, pass, pass, pass, pass, pass
    # With MAX_CONSECUTIVE_FAILS=3, this should NOT abort (max consecutive is 2)
    local tests=()
    tests+=("$(make_mock_test "test-cf-f1.sh" 1 0 1 0)")
    tests+=("$(make_mock_test "test-cf-f2.sh" 1 0 1 0)")
    tests+=("$(make_mock_test "test-cf-p1.sh" 0 1 0 0)")
    tests+=("$(make_mock_test "test-cf-f3.sh" 1 0 1 0)")
    tests+=("$(make_mock_test "test-cf-f4.sh" 1 0 1 0)")
    tests+=("$(make_mock_test "test-cf-p2.sh" 0 1 0 0)")
    tests+=("$(make_mock_test "test-cf-p3.sh" 0 1 0 0)")
    tests+=("$(make_mock_test "test-cf-p4.sh" 0 1 0 0)")
    tests+=("$(make_mock_test "test-cf-p5.sh" 0 1 0 0)")
    tests+=("$(make_mock_test "test-cf-p6.sh" 0 1 0 0)")

    local output exit_code=0
    # MAX_PARALLEL=1 for deterministic order
    output=$(TEST_TIMEOUT=5 MAX_PARALLEL=1 MAX_CONSECUTIVE_FAILS=3 \
        bash "$SCRIPT_DIR/lib/suite-engine.sh" "${tests[@]}" 2>&1) || exit_code=$?

    # Should NOT contain ABORT — consecutive never reaches 3
    if echo "$output" | grep -q "ABORT"; then
        (( ++FAIL ))
        echo "FAIL: consecutive-reset: should not have aborted" >&2
    else
        (( ++PASS ))
    fi

    # All 10 tests should have run
    assert_contains "consecutive-reset: ran last test" "test-cf-p6.sh" "$output"
    assert_pass_if_clean "test_consecutive_fail_resets_on_pass"
}

# --- Test 9: bare "N passed, N failed" format parsed correctly ---
test_bare_passed_failed_format() {
    _snapshot_fail
    # test-deps.sh style: "22 passed, 0 failed (of 22)" on its own line
    local test_path="$MOCK_DIR/test-bare-fmt.sh"
    cat > "$test_path" <<'TESTEOF'
#!/usr/bin/env bash
echo "=== Results ==="
echo "5 passed, 2 failed (of 7)"
exit 1
TESTEOF
    chmod +x "$test_path"

    local output
    output=$(TEST_TIMEOUT=5 MAX_PARALLEL=1 MAX_CONSECUTIVE_FAILS=999 \
        bash "$SCRIPT_DIR/lib/suite-engine.sh" "$test_path" 2>&1) || true

    assert_contains "bare-fmt: 5 pass parsed" "5 pass" "$output"
    assert_contains "bare-fmt: 2 fail parsed" "2 fail" "$output"
    assert_pass_if_clean "test_bare_passed_failed_format"
}

# --- Test 10: "Results: N passed, N failed" format parsed correctly ---
test_results_colon_format() {
    _snapshot_fail
    local test_path
    test_path=$(make_mock_test_results_fmt "test-results-fmt.sh" 0 4 0 0)

    local output
    output=$(TEST_TIMEOUT=5 MAX_PARALLEL=1 MAX_CONSECUTIVE_FAILS=999 \
        bash "$SCRIPT_DIR/lib/suite-engine.sh" "$test_path" 2>&1) || true

    assert_contains "results-fmt: 4 pass parsed" "4 pass" "$output"
    assert_pass_if_clean "test_results_colon_format"
}

# --- Run all tests ---
test_timeout_kills_slow_test
test_parallel_faster_than_serial
test_fail_fast_aborts_after_threshold
test_progress_shows_counter
test_pass_fail_counts_aggregated
test_timeout_exit_reported_distinctly
test_max_parallel_env_respected
test_consecutive_fail_resets_on_pass
test_bare_passed_failed_format
test_results_colon_format

print_summary
