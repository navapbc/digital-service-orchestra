#!/usr/bin/env bash
# Test that validate.sh's report_check treats missing .rc files as failures
# when the check was actually launched (not just skipped).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/assert.sh"

CHECK_DIR=$(mktemp -d)
LOGFILE=$(mktemp)
RESULT_FILE=$(mktemp)

trap "rm -rf '$CHECK_DIR' '$LOGFILE' '$RESULT_FILE'" EXIT

# The function under test — mirrors the new validate.sh behavior
_report_check() {
    local label="$1" name="$2" launched="$3"
    local rc_file="$CHECK_DIR/${name}.rc"
    local _failed=0
    local _failed_checks=""
    local _output=""

    if [ ! -f "$rc_file" ]; then
        if [[ " $launched " == *" $name "* ]]; then
            _output="CRASH (check process did not report)"
            _failed=1
            _failed_checks="$label"
        fi
    else
        local rc
        rc=$(cat "$rc_file")
        if [ "$rc" = "0" ]; then
            _output="PASS"
        else
            _output="FAIL"
            _failed=1
            _failed_checks="$label"
        fi
    fi

    echo "output=$_output" > "$RESULT_FILE"
    echo "failed=$_failed" >> "$RESULT_FILE"
    echo "failed_checks=$_failed_checks" >> "$RESULT_FILE"
}

_read_result() {
    local key="$1"
    grep "^${key}=" "$RESULT_FILE" | cut -d= -f2-
}

# ── Test 1: Missing rc file for a LAUNCHED check → CRASH ──
rm -f "$CHECK_DIR"/*.rc
echo "0" > "$CHECK_DIR/syntax.rc"
echo "0" > "$CHECK_DIR/ruff.rc"
# format.rc deliberately missing

_report_check "format" "format" "syntax format ruff"
assert_contains "crash_detected" "CRASH" "$(_read_result output)"
assert_eq "crash_sets_failed" "1" "$(_read_result failed)"
assert_eq "crash_in_failed_checks" "format" "$(_read_result failed_checks)"

# ── Test 2: Missing rc file for UNLAUNCHED check → silent ──
_report_check "format" "format" "syntax ruff"
assert_eq "unlaunched_missing_is_silent" "" "$(_read_result output)"
assert_eq "unlaunched_not_failed" "0" "$(_read_result failed)"

# ── Test 3: Present rc file with 0 → PASS ──
_report_check "syntax" "syntax" "syntax"
assert_contains "present_rc_pass" "PASS" "$(_read_result output)"
assert_eq "present_rc_not_failed" "0" "$(_read_result failed)"

# ── Test 4: Present rc file with non-zero → FAIL ──
echo "1" > "$CHECK_DIR/mypy.rc"
_report_check "mypy" "mypy" "mypy"
assert_contains "present_rc_fail" "FAIL" "$(_read_result output)"
assert_eq "present_rc_failed" "1" "$(_read_result failed)"

# ── Test 5: rc file with exit code 124 (timeout) → FAIL ──
echo "124" > "$CHECK_DIR/tests.rc"
_report_check "tests" "tests" "tests"
assert_contains "timeout_is_fail" "FAIL" "$(_read_result output)"
assert_eq "timeout_sets_failed" "1" "$(_read_result failed)"

print_summary
