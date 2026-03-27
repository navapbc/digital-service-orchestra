#!/usr/bin/env bash
# tests/hooks/test-suite-engine.sh
# Unit tests for the suite-engine's failed test output dump feature.
#
# Tests:
#   test_suite_engine_dumps_failed_test_output
#   test_suite_engine_no_dump_when_all_pass
#   test_suite_engine_dumps_only_failing_tests
#
# Usage: bash tests/hooks/test-suite-engine.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null)"
LIB_DIR="$SCRIPT_DIR/../lib"

source "$LIB_DIR/assert.sh"

MOCK_DIR=$(mktemp -d)
trap 'rm -rf "$MOCK_DIR"' EXIT

# Helper: create a mock test script
make_mock_test() {
    local name="$1"
    local exit_code="$2"
    local pass_count="${3:-1}"
    local fail_count="${4:-0}"
    local extra_output="${5:-}"
    local path="$MOCK_DIR/$name"
    cat > "$path" <<EOF
#!/usr/bin/env bash
${extra_output}
echo "PASSED: $pass_count  FAILED: $fail_count"
exit $exit_code
EOF
    chmod +x "$path"
    echo "$path"
}

# --- test_suite_engine_dumps_failed_test_output ---
# When a test fails, the suite-engine should dump its output between
# "=== Failed test output ===" markers.
mock_fail=$(make_mock_test "test-mock-fail.sh" 1 0 1 'echo "FAIL [my_test]: expected='\''2'\'' actual='\''0'\''"')
mock_pass=$(make_mock_test "test-mock-pass.sh" 0 1 0)

suite_output=$(
    MAX_PARALLEL=1 TEST_TIMEOUT=10 MAX_CONSECUTIVE_FAILS=10 \
    bash "$LIB_DIR/suite-engine.sh" "$mock_fail" "$mock_pass" 2>&1
) || true

assert_contains "dump_header_present" "=== Failed test output ===" "$suite_output"
assert_contains "dump_footer_present" "=== End failed test output ===" "$suite_output"
assert_contains "dump_contains_test_name" "--- test-mock-fail.sh ---" "$suite_output"
assert_contains "dump_contains_failure_detail" "FAIL [my_test]" "$suite_output"

# --- test_suite_engine_no_dump_when_all_pass ---
# When all tests pass, no dump section should appear.
mock_pass1=$(make_mock_test "test-mock-pass1.sh" 0 2 0)
mock_pass2=$(make_mock_test "test-mock-pass2.sh" 0 3 0)

suite_output_pass=$(
    MAX_PARALLEL=1 TEST_TIMEOUT=10 MAX_CONSECUTIVE_FAILS=10 \
    bash "$LIB_DIR/suite-engine.sh" "$mock_pass1" "$mock_pass2" 2>&1
) || true

# Should NOT contain the dump markers
_has_dump=0
echo "$suite_output_pass" | grep -q "=== Failed test output ===" && _has_dump=1
assert_eq "no_dump_when_all_pass" "0" "$_has_dump"

# --- test_suite_engine_dumps_only_failing_tests ---
# When one test fails and another passes, only the failing test's output
# should appear in the dump section.
mock_fail2=$(make_mock_test "test-mock-fail2.sh" 1 0 1 'echo "specific failure marker xyz123"')
mock_pass3=$(make_mock_test "test-mock-pass3.sh" 0 5 0 'echo "passing test unique marker abc789"')

suite_output_mixed=$(
    MAX_PARALLEL=1 TEST_TIMEOUT=10 MAX_CONSECUTIVE_FAILS=10 \
    bash "$LIB_DIR/suite-engine.sh" "$mock_fail2" "$mock_pass3" 2>&1
) || true

assert_contains "dump_has_failing_test_output" "specific failure marker xyz123" "$suite_output_mixed"
# The passing test's output should NOT appear in the dump section
_has_pass_output=0
# Extract only the dump section and check for the passing test's marker
_dump_section=$(echo "$suite_output_mixed" | sed -n '/=== Failed test output ===/,/=== End failed test output ===/p')
echo "$_dump_section" | grep -q "passing test unique marker abc789" && _has_pass_output=1
assert_eq "dump_excludes_passing_test" "0" "$_has_pass_output"

print_summary
