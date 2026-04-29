#!/usr/bin/env bash
# tests/lib/assert.sh
# Shared bash assertion helpers for plugin/hook test files.
#
# Usage (source into test scripts):
#   source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/assert.sh"
#
# Usage (self-test):
#   RUN_SELF_TESTS=1 bash tests/lib/assert.sh
#
# Provides:
#   assert_eq(label, expected, actual)   — PASS/FAIL with message
#   assert_ne(label, not_expected, actual) — PASS/FAIL with message
#   assert_contains(label, substring, string) — PASS/FAIL with message
#   print_summary()                      — prints 'PASSED: N  FAILED: N' and exits with FAIL count
#
# Global counters (initialized on source, reset by print_summary):
#   PASS — number of passing assertions
#   FAIL — number of failing assertions

# Initialize counters (only if not already set — allows callers to accumulate)
: "${PASS:=0}"
: "${FAIL:=0}"

# assert_eq label expected actual
# Increments PASS if expected == actual, FAIL otherwise.
assert_eq() {
    local label="$1" expected="$2" actual="$3"
    if [[ "$expected" == "$actual" ]]; then
        (( ++PASS ))
    else
        (( ++FAIL ))
        printf "FAIL: %s\n  expected: %s\n  actual:   %s\n" "$label" "$expected" "$actual" >&2
    fi
}

# assert_ne label not_expected actual
# Increments PASS if not_expected != actual, FAIL otherwise.
assert_ne() {
    local label="$1" not_expected="$2" actual="$3"
    if [[ "$not_expected" != "$actual" ]]; then
        (( ++PASS ))
    else
        (( ++FAIL ))
        printf "FAIL: %s\n  should NOT be: %s\n  actual:        %s\n" "$label" "$not_expected" "$actual" >&2
    fi
}

# assert_contains label substring string
# Increments PASS if substring appears in string, FAIL otherwise.
assert_contains() {
    local label="$1" substring="$2" string="$3"
    if [[ "$string" == *"$substring"* ]]; then
        (( ++PASS ))
    else
        (( ++FAIL ))
        printf "FAIL: %s\n  expected to contain: %s\n  actual:              %s\n" "$label" "$substring" "$string" >&2
    fi
}

# assert_not_contains label substring string
# Increments PASS if substring does NOT appear in string, FAIL otherwise.
assert_not_contains() {
    local label="$1" substring="$2" string="$3"
    if [[ "$string" != *"$substring"* ]]; then
        (( ++PASS ))
    else
        (( ++FAIL ))
        printf "FAIL: %s\n  expected NOT to contain: %s\n  actual:                  %s\n" "$label" "$substring" "$string" >&2
    fi
}

# _snapshot_fail
# Captures current FAIL count for later comparison by assert_pass_if_clean.
_snapshot_fail() { _fail_snapshot=$FAIL; }

# assert_pass_if_clean label
# Prints "label ... PASS" if no new failures occurred since last _snapshot_fail.
assert_pass_if_clean() {
    local label="$1"
    if [[ -z "${_fail_snapshot+x}" ]]; then
        echo "ERROR: assert_pass_if_clean called without _snapshot_fail for: $label" >&2
        (( ++FAIL ))
        return
    fi
    if [[ "$FAIL" -eq "$_fail_snapshot" ]]; then
        echo "$label ... PASS"
    else
        echo "FAIL: $label" >&2
    fi
}

# print_summary
# Prints 'PASSED: N  FAILED: N' and exits with 1 if FAIL > 0, else 0.
print_summary() {
    echo ""
    printf "PASSED: %d  FAILED: %d\n" "$PASS" "$FAIL"
    if [[ "$FAIL" -gt 0 ]]; then
        exit 1
    fi
    exit 0
}

# ============================================================
# Self-tests (only run when RUN_SELF_TESTS=1)
# ============================================================
if [[ "${RUN_SELF_TESTS:-0}" == "1" ]]; then
    # Use isolated counters for self-tests so sourcing callers are not affected
    PASS=0
    FAIL=0

    echo "=== assert.sh self-tests ==="

    # --- assert_eq ---
    echo ""
    echo "--- assert_eq ---"

    # test_assert_eq_passes_on_match: matching values should increment PASS
    _pass_before=$PASS
    assert_eq "match: equal strings" "hello" "hello"
    if [[ $PASS -eq $(( _pass_before + 1 )) ]]; then
        echo "PASS: test_assert_eq_passes_on_match"
    else
        echo "FAIL: test_assert_eq_passes_on_match — PASS counter not incremented"
        (( FAIL++ ))
    fi

    # test_assert_eq_fails_on_mismatch: mismatched values should increment FAIL
    _fail_before=$FAIL
    _pass_before=$PASS
    # Temporarily capture stderr to avoid polluting self-test output
    assert_eq "mismatch: different strings" "expected_value" "actual_value" 2>/dev/null
    if [[ $FAIL -eq $(( _fail_before + 1 )) && $PASS -eq $_pass_before ]]; then
        echo "PASS: test_assert_eq_fails_on_mismatch"
        # Correct the FAIL counter — we expected the failure and already counted it above
        (( FAIL-- ))
    else
        echo "FAIL: test_assert_eq_fails_on_mismatch — FAIL counter not incremented"
        (( FAIL++ ))
    fi

    # Additional assert_eq cases
    assert_eq "empty strings equal" "" ""
    assert_eq "numeric strings equal" "42" "42"

    # --- assert_ne ---
    echo ""
    echo "--- assert_ne ---"

    _pass_before=$PASS
    assert_ne "ne: different strings" "foo" "bar"
    if [[ $PASS -eq $(( _pass_before + 1 )) ]]; then
        echo "PASS: assert_ne passes when values differ"
    else
        echo "FAIL: assert_ne should pass when values differ"
        (( FAIL++ ))
    fi

    _fail_before=$FAIL
    _pass_before=$PASS
    assert_ne "ne: same strings" "same" "same" 2>/dev/null
    if [[ $FAIL -eq $(( _fail_before + 1 )) && $PASS -eq $_pass_before ]]; then
        echo "PASS: assert_ne fails when values are equal"
        (( FAIL-- ))  # correct — we expected this failure
    else
        echo "FAIL: assert_ne should fail when values are equal"
        (( FAIL++ ))
    fi

    assert_ne "ne: empty vs non-empty" "" "non-empty"

    # --- assert_contains ---
    echo ""
    echo "--- assert_contains ---"

    _pass_before=$PASS
    assert_contains "contains: substring present" "world" "hello world"
    if [[ $PASS -eq $(( _pass_before + 1 )) ]]; then
        echo "PASS: assert_contains passes when substring present"
    else
        echo "FAIL: assert_contains should pass when substring is present"
        (( FAIL++ ))
    fi

    _fail_before=$FAIL
    _pass_before=$PASS
    assert_contains "contains: substring absent" "missing" "hello world" 2>/dev/null
    if [[ $FAIL -eq $(( _fail_before + 1 )) && $PASS -eq $_pass_before ]]; then
        echo "PASS: assert_contains fails when substring absent"
        (( FAIL-- ))  # correct — we expected this failure
    else
        echo "FAIL: assert_contains should fail when substring is absent"
        (( FAIL++ ))
    fi

    assert_contains "contains: exact match" "hello" "hello"
    assert_contains "contains: multi-word substring" "foo bar" "prefix foo bar suffix"

    # --- print_summary exits; call only at end ---
    echo ""
    echo "=== Self-test results ==="
    print_summary
fi
