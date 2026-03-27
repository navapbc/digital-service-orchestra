#!/usr/bin/env bash
# tests/test-run-all.sh
# TDD tests for tests/run-all.sh
#
# Tests:
#   1. test_run_all_exits_zero_when_all_suites_pass
#   2. test_run_all_exits_one_when_hooks_fails
#   3. test_run_all_exits_one_when_scripts_fails
#   4. test_run_all_exits_one_when_evals_fails
#   5. test_run_all_produces_combined_summary

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null)"
RUN_ALL="$SCRIPT_DIR/run-all.sh"

PASS=0
FAIL=0

# --- Helpers ---
pass() { echo "PASS: $1"; (( PASS++ )); }
fail() { echo "FAIL: $1 — $2"; (( FAIL++ )); }

# Create a temporary directory for mock suite runners
MOCK_DIR=$(mktemp -d)
trap 'rm -rf "$MOCK_DIR"' EXIT

# Helper: create a mock suite runner that exits with given code
make_mock() {
    local name="$1"
    local exit_code="$2"
    local pass_count="${3:-3}"
    local fail_count="${4:-0}"
    local path="$MOCK_DIR/$name"
    cat > "$path" <<EOF
#!/usr/bin/env bash
echo "=== Mock Suite: $name ==="
echo "Results: $pass_count passed, $fail_count failed"
exit $exit_code
EOF
    chmod +x "$path"
    echo "$path"
}

# --- Test 1: exits 0 when all suites pass ---
test_run_all_exits_zero_when_all_suites_pass() {
    local mock_hooks mock_scripts mock_evals mock_python
    mock_hooks=$(make_mock "mock-hooks.sh" 0 3 0)
    mock_scripts=$(make_mock "mock-scripts.sh" 0 2 0)
    mock_evals=$(make_mock "mock-evals.sh" 0 5 0)
    mock_python=$(make_mock "mock-python.sh" 0 4 0)

    actual_exit=0
    bash "$RUN_ALL" \
        --hooks-runner "$mock_hooks" \
        --scripts-runner "$mock_scripts" \
        --evals-runner "$mock_evals" \
        --python-runner "$mock_python" \
        > /dev/null 2>&1 || actual_exit=$?

    if [ "$actual_exit" -eq 0 ]; then
        pass "test_run_all_exits_zero_when_all_suites_pass"
    else
        fail "test_run_all_exits_zero_when_all_suites_pass" "expected exit 0, got $actual_exit"
    fi
}

# --- Test 2: exits 1 when hooks suite fails ---
test_run_all_exits_one_when_hooks_fails() {
    local mock_hooks mock_scripts mock_evals mock_python
    mock_hooks=$(make_mock "mock-hooks-fail.sh" 1 2 1)
    mock_scripts=$(make_mock "mock-scripts-ok.sh" 0 2 0)
    mock_evals=$(make_mock "mock-evals-ok.sh" 0 5 0)
    mock_python=$(make_mock "mock-python-ok.sh" 0 4 0)

    actual_exit=0
    bash "$RUN_ALL" \
        --hooks-runner "$mock_hooks" \
        --scripts-runner "$mock_scripts" \
        --evals-runner "$mock_evals" \
        --python-runner "$mock_python" \
        > /dev/null 2>&1 || actual_exit=$?

    if [ "$actual_exit" -eq 1 ]; then
        pass "test_run_all_exits_one_when_hooks_fails"
    else
        fail "test_run_all_exits_one_when_hooks_fails" "expected exit 1, got $actual_exit"
    fi
}

# --- Test 3: exits 1 when scripts suite fails ---
test_run_all_exits_one_when_scripts_fails() {
    local mock_hooks mock_scripts mock_evals mock_python
    mock_hooks=$(make_mock "mock-hooks-ok2.sh" 0 3 0)
    mock_scripts=$(make_mock "mock-scripts-fail.sh" 1 1 2)
    mock_evals=$(make_mock "mock-evals-ok2.sh" 0 4 0)
    mock_python=$(make_mock "mock-python-ok2.sh" 0 4 0)

    actual_exit=0
    bash "$RUN_ALL" \
        --hooks-runner "$mock_hooks" \
        --scripts-runner "$mock_scripts" \
        --evals-runner "$mock_evals" \
        --python-runner "$mock_python" \
        > /dev/null 2>&1 || actual_exit=$?

    if [ "$actual_exit" -eq 1 ]; then
        pass "test_run_all_exits_one_when_scripts_fails"
    else
        fail "test_run_all_exits_one_when_scripts_fails" "expected exit 1, got $actual_exit"
    fi
}

# --- Test 4: exits 1 when evals suite fails ---
test_run_all_exits_one_when_evals_fails() {
    local mock_hooks mock_scripts mock_evals mock_python
    mock_hooks=$(make_mock "mock-hooks-ok3.sh" 0 3 0)
    mock_scripts=$(make_mock "mock-scripts-ok3.sh" 0 2 0)
    mock_evals=$(make_mock "mock-evals-fail.sh" 1 3 2)
    mock_python=$(make_mock "mock-python-ok3.sh" 0 4 0)

    actual_exit=0
    bash "$RUN_ALL" \
        --hooks-runner "$mock_hooks" \
        --scripts-runner "$mock_scripts" \
        --evals-runner "$mock_evals" \
        --python-runner "$mock_python" \
        > /dev/null 2>&1 || actual_exit=$?

    if [ "$actual_exit" -eq 1 ]; then
        pass "test_run_all_exits_one_when_evals_fails"
    else
        fail "test_run_all_exits_one_when_evals_fails" "expected exit 1, got $actual_exit"
    fi
}

# --- Test 5: produces combined summary output ---
test_run_all_produces_combined_summary() {
    local mock_hooks mock_scripts mock_evals mock_python
    mock_hooks=$(make_mock "mock-hooks-sum.sh" 0 3 0)
    mock_scripts=$(make_mock "mock-scripts-sum.sh" 0 2 0)
    mock_evals=$(make_mock "mock-evals-sum.sh" 0 5 0)
    mock_python=$(make_mock "mock-python-sum.sh" 0 4 0)

    output=$(bash "$RUN_ALL" \
        --hooks-runner "$mock_hooks" \
        --scripts-runner "$mock_scripts" \
        --evals-runner "$mock_evals" \
        --python-runner "$mock_python" 2>&1)

    # Check that summary section is present
    if echo "$output" | grep -qiE "(summary|PASS|FAIL)"; then
        pass "test_run_all_produces_combined_summary"
    else
        fail "test_run_all_produces_combined_summary" "no summary found in output"
    fi
}

# --- Test 6: nested invocation doesn't kill parent (fratricide bug) ---
# When test-run-all.sh spawns child run-all.sh instances, the child's
# process-cleanup must NOT kill the parent. The _RUN_ALL_ACTIVE env var
# guards against this.
test_nested_invocation_no_fratricide() {
    local mock_hooks mock_scripts mock_evals mock_python
    mock_hooks=$(make_mock "mock-hooks-nest.sh" 0 1 0)
    mock_scripts=$(make_mock "mock-scripts-nest.sh" 0 1 0)
    mock_evals=$(make_mock "mock-evals-nest.sh" 0 1 0)
    mock_python=$(make_mock "mock-python-nest.sh" 0 1 0)

    # Simulate a parent run-all.sh by setting _RUN_ALL_ACTIVE (as the real
    # parent does after its own cleanup section).
    # The child should skip process cleanup entirely.
    actual_exit=0
    _RUN_ALL_ACTIVE=1 bash "$RUN_ALL" \
        --hooks-runner "$mock_hooks" \
        --scripts-runner "$mock_scripts" \
        --evals-runner "$mock_evals" \
        --python-runner "$mock_python" \
        > /dev/null 2>&1 || actual_exit=$?

    if [ "$actual_exit" -eq 0 ]; then
        pass "test_nested_invocation_no_fratricide"
    else
        fail "test_nested_invocation_no_fratricide" "expected exit 0, got $actual_exit"
    fi
}

# --- Run all tests ---
test_run_all_exits_zero_when_all_suites_pass
test_run_all_exits_one_when_hooks_fails
test_run_all_exits_one_when_scripts_fails
test_run_all_exits_one_when_evals_fails
test_run_all_produces_combined_summary
test_nested_invocation_no_fratricide

# --- Report ---
echo ""
echo "Results: $PASS passed, $FAIL failed"

if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
exit 0
