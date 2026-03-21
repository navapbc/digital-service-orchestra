#!/usr/bin/env bash
# tests/scripts/test-retry-with-backoff.sh
# Tests for retry_with_backoff() in hooks/lib/deps.sh
#
# Tests:
#   1. test_function_exists_in_deps_sh           — retry_with_backoff is defined in deps.sh
#   2. test_success_on_first_try                 — command that succeeds immediately returns 0
#   3. test_success_on_retry                     — command that fails twice then succeeds returns 0
#   4. test_failure_after_max_retries            — command that always fails returns non-zero
#   5. test_delay_doubling                       — delays double between retries
#   6. test_merge_to_main_uses_retry             — merge-to-main.sh wraps git push with retry_with_backoff
#   7. test_worktree_create_uses_retry           — worktree-create.sh wraps git worktree add with retry_with_backoff
#   8. test_attempt_count                        — retries exactly max_retries times before giving up
#
# Usage: bash tests/scripts/test-retry-with-backoff.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DSO_PLUGIN_DIR="$PLUGIN_ROOT/plugins/dso"
REPO_ROOT="$(cd "$SCRIPT_DIR" && git rev-parse --show-toplevel)"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

DEPS_SH="$DSO_PLUGIN_DIR/hooks/lib/deps.sh"
MERGE_SCRIPT="$DSO_PLUGIN_DIR/scripts/merge-to-main.sh"
WORKTREE_CREATE_SCRIPT="$DSO_PLUGIN_DIR/scripts/worktree-create.sh"

echo "=== test-retry-with-backoff.sh ==="

# =============================================================================
# Test 1: retry_with_backoff is defined in deps.sh
# =============================================================================
echo ""
echo "--- function existence in deps.sh ---"
_snapshot_fail

HAS_FUNCTION=$(grep -c "retry_with_backoff" "$DEPS_SH" || true)
assert_ne "test_function_exists_in_deps_sh" "0" "$HAS_FUNCTION"

assert_pass_if_clean "retry_with_backoff defined in deps.sh"

# =============================================================================
# Test 2: success on first try
# A command that succeeds immediately should return 0 with no retries.
# =============================================================================
echo ""
echo "--- success on first try ---"
_snapshot_fail

_OUTER_TMP=$(mktemp -d)
trap 'rm -rf "$_OUTER_TMP"' EXIT

_CALL_COUNT_FILE="$_OUTER_TMP/call_count_success.txt"
echo "0" > "$_CALL_COUNT_FILE"

# Use RETRY_SLEEP_CMD override to avoid real sleep delays in tests
bash -c "
RETRY_SLEEP_CMD=':' # no-op sleep for tests
source '$DEPS_SH'

# Override sleep to be a no-op inside retry_with_backoff for fast tests
sleep() { : ; }

_count=0
_mock_cmd() {
    _count=\$(( _count + 1 ))
    echo \"\$_count\" > '$_CALL_COUNT_FILE'
    return 0  # Always succeeds
}

retry_with_backoff 3 0 _mock_cmd
echo \$? > '$_OUTER_TMP/exit_code_success.txt'
"

_exit_code=$(cat "$_OUTER_TMP/exit_code_success.txt" 2>/dev/null || echo "missing")
_call_count=$(cat "$_CALL_COUNT_FILE" 2>/dev/null || echo "0")

assert_eq "success on first try returns 0" "0" "$_exit_code"
assert_eq "success on first try calls command exactly once" "1" "$_call_count"

assert_pass_if_clean "success on first try"

# =============================================================================
# Test 3: success on retry
# A command that fails twice then succeeds should return 0 on the 3rd attempt.
# =============================================================================
echo ""
echo "--- success on retry ---"
_snapshot_fail

_CALL_COUNT_FILE3="$_OUTER_TMP/call_count_retry.txt"
echo "0" > "$_CALL_COUNT_FILE3"

bash -c "
source '$DEPS_SH'

# Override sleep to be a no-op for fast tests
sleep() { : ; }

_count=0
_mock_flaky() {
    _count=\$(( _count + 1 ))
    echo \"\$_count\" > '$_CALL_COUNT_FILE3'
    if [ \"\$_count\" -lt 3 ]; then
        return 1  # Fail first two calls
    fi
    return 0  # Succeed on 3rd call
}

retry_with_backoff 3 0 _mock_flaky
echo \$? > '$_OUTER_TMP/exit_code_retry.txt'
"

_exit_code3=$(cat "$_OUTER_TMP/exit_code_retry.txt" 2>/dev/null || echo "missing")
_call_count3=$(cat "$_CALL_COUNT_FILE3" 2>/dev/null || echo "0")

assert_eq "success on retry returns 0" "0" "$_exit_code3"
assert_eq "success on retry calls command 3 times" "3" "$_call_count3"

assert_pass_if_clean "success on retry"

# =============================================================================
# Test 4: failure after max retries
# A command that always fails should return non-zero after max_retries attempts.
# =============================================================================
echo ""
echo "--- failure after max retries ---"
_snapshot_fail

_CALL_COUNT_FILE4="$_OUTER_TMP/call_count_fail.txt"
echo "0" > "$_CALL_COUNT_FILE4"

bash -c "
source '$DEPS_SH'

# Override sleep to be a no-op for fast tests
sleep() { : ; }

_count=0
_mock_always_fail() {
    _count=\$(( _count + 1 ))
    echo \"\$_count\" > '$_CALL_COUNT_FILE4'
    return 42  # Always fails with code 42
}

retry_with_backoff 3 0 _mock_always_fail
echo \$? > '$_OUTER_TMP/exit_code_fail.txt'
" || true  # Subprocess may exit non-zero

_exit_code4=$(cat "$_OUTER_TMP/exit_code_fail.txt" 2>/dev/null || echo "missing")
_call_count4=$(cat "$_CALL_COUNT_FILE4" 2>/dev/null || echo "0")

assert_ne "failure after max retries returns non-zero" "0" "$_exit_code4"
# 1 initial attempt + 3 retries = 4 total calls
assert_eq "failure after max retries calls command 4 times (1 initial + 3 retries)" "4" "$_call_count4"

assert_pass_if_clean "failure after max retries"

# =============================================================================
# Test 5: delay doubling
# Verify that the delays logged to stderr double: 1s, 2s, 4s
# =============================================================================
echo ""
echo "--- delay doubling ---"
_snapshot_fail

bash -c "
source '$DEPS_SH'

# Override sleep to capture the delay values instead of sleeping
_delays=()
sleep() {
    _delays+=(\"\$1\")
    echo \"\$1\" >> '$_OUTER_TMP/delays.txt'
}

_mock_always_fail() { return 1; }

retry_with_backoff 3 1 _mock_always_fail 2>/dev/null
" || true

if [[ -f "$_OUTER_TMP/delays.txt" ]]; then
    _delay_1=$(sed -n '1p' "$_OUTER_TMP/delays.txt")
    _delay_2=$(sed -n '2p' "$_OUTER_TMP/delays.txt")
    _delay_3=$(sed -n '3p' "$_OUTER_TMP/delays.txt")

    # First delay should be 1 (the initial_delay)
    assert_eq "first retry delay is 1" "1" "$_delay_1"

    # Second delay should be 2 (doubled from 1)
    # Accept "2" or "2.00" due to awk float formatting
    _delay_2_int="${_delay_2%%.*}"
    assert_eq "second retry delay doubles to 2" "2" "$_delay_2_int"

    # Third delay should be 4 (doubled from 2)
    _delay_3_int="${_delay_3%%.*}"
    assert_eq "third retry delay doubles to 4" "4" "$_delay_3_int"
else
    (( ++FAIL ))
    echo "FAIL: delay doubling — delays.txt not written (sleep override may not have fired)" >&2
fi

assert_pass_if_clean "delay doubling"

# =============================================================================
# Test 6: merge-to-main.sh wraps git push with retry_with_backoff
# =============================================================================
echo ""
echo "--- merge-to-main.sh uses retry_with_backoff for git push ---"
_snapshot_fail

HAS_RETRY_IN_MERGE=$(grep -c "retry_with_backoff" "$MERGE_SCRIPT" || true)
assert_ne "test_merge_to_main_uses_retry" "0" "$HAS_RETRY_IN_MERGE"

# Verify the retry wraps git push specifically
HAS_RETRY_GIT_PUSH=$(grep -cE "retry_with_backoff.*git push|retry_with_backoff.*push" "$MERGE_SCRIPT" || true)
assert_ne "test_merge_to_main_retry_wraps_git_push" "0" "$HAS_RETRY_GIT_PUSH"

assert_pass_if_clean "merge-to-main.sh uses retry_with_backoff for git push"

# =============================================================================
# Test 7: worktree-create.sh wraps git worktree add with retry_with_backoff
# =============================================================================
echo ""
echo "--- worktree-create.sh uses retry_with_backoff for git worktree add ---"
_snapshot_fail

HAS_RETRY_IN_WORKTREE=$(grep -c "retry_with_backoff" "$WORKTREE_CREATE_SCRIPT" || true)
assert_ne "test_worktree_create_uses_retry" "0" "$HAS_RETRY_IN_WORKTREE"

assert_pass_if_clean "worktree-create.sh uses retry_with_backoff for git worktree add"

# =============================================================================
# Test 8: attempt count correctness with max_retries=0
# With max_retries=0, should try exactly once and fail immediately.
# =============================================================================
echo ""
echo "--- zero retries: try once only ---"
_snapshot_fail

_CALL_COUNT_FILE8="$_OUTER_TMP/call_count_zero_retry.txt"
echo "0" > "$_CALL_COUNT_FILE8"

bash -c "
source '$DEPS_SH'
sleep() { : ; }

_count=0
_mock_always_fail() {
    _count=\$(( _count + 1 ))
    echo \"\$_count\" > '$_CALL_COUNT_FILE8'
    return 1
}

retry_with_backoff 0 1 _mock_always_fail
echo \$? > '$_OUTER_TMP/exit_code_zero_retry.txt'
" || true

_exit_code8=$(cat "$_OUTER_TMP/exit_code_zero_retry.txt" 2>/dev/null || echo "missing")
_call_count8=$(cat "$_CALL_COUNT_FILE8" 2>/dev/null || echo "0")

assert_ne "zero retries returns non-zero" "0" "$_exit_code8"
assert_eq "zero retries calls command exactly once" "1" "$_call_count8"

assert_pass_if_clean "zero retries: try once only"

# =============================================================================
# Test 9: retry_with_backoff is callable from merge-to-main.sh without deps.sh
# Regression test for dso-kv4p: the function must be defined inline in
# merge-to-main.sh as a fallback so _phase_push works even when deps.sh is absent.
# =============================================================================
echo ""
echo "--- retry_with_backoff defined inline in merge-to-main.sh as fallback ---"
_snapshot_fail

# Check that merge-to-main.sh defines retry_with_backoff directly (not only via source).
# The function may be indented (inside an 'if' guard block), so match with optional leading whitespace.
HAS_INLINE_DEFINITION=$(grep -cE "^[[:space:]]*retry_with_backoff\(\)" "$MERGE_SCRIPT" || true)
assert_ne "test_retry_with_backoff_defined_inline_in_merge_script" "0" "$HAS_INLINE_DEFINITION"

# Verify that the inline definition is guarded (only defined if not already set by deps.sh)
# This avoids redefining it when deps.sh is sourced successfully.
HAS_GUARD=$(grep -cE "type retry_with_backoff|command -v retry_with_backoff|declare.*retry_with_backoff" "$MERGE_SCRIPT" || true)
assert_ne "test_retry_with_backoff_inline_is_guarded" "0" "$HAS_GUARD"

assert_pass_if_clean "retry_with_backoff defined inline in merge-to-main.sh as fallback"

# =============================================================================
# Summary
# =============================================================================
print_summary
