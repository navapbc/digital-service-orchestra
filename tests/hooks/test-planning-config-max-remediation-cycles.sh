#!/usr/bin/env bash
# tests/hooks/test-planning-config-max-remediation-cycles.sh
# Behavioral tests for get_max_remediation_cycles() in planning-config.sh.
#
# Tests verify:
#   1. Value < 2 (e.g., 1) → non-zero exit AND stderr contains rejected value and minimum (2)
#   2. Key absent → prints "3", exits 0
#   3. Key set to valid value (5) → prints "5", exits 0
#   4. Key present but empty string → treats as absent → prints "3", exits 0 (do NOT reject)
#
# Stderr error format: "planning.max_remediation_cycles must be >= 2 (got: <value>)"
#
# Usage: bash tests/hooks/test-planning-config-max-remediation-cycles.sh
# Exit code: 0 if all pass, 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"
PLANNING_CONFIG_LIB="$REPO_ROOT/plugins/dso/hooks/lib/planning-config.sh"

source "$REPO_ROOT/tests/lib/assert.sh"

echo "=== test-planning-config-max-remediation-cycles.sh ==="

# ---------------------------------------------------------------------------
# test_rejects_value_below_minimum
# Given dso-config.conf with planning.max_remediation_cycles=1
# When get_max_remediation_cycles is sourced and invoked
# Then exits non-zero AND stderr contains rejected value and minimum (2)
# ---------------------------------------------------------------------------
test_rejects_value_below_minimum() {
    _snapshot_fail

    local tmp_conf exit_code stderr_out
    tmp_conf=$(mktemp "${TMPDIR:-/tmp}/test-planning-config.XXXXXX")
    printf 'planning.max_remediation_cycles=1\n' > "$tmp_conf"

    exit_code=0
    stderr_out=$(
        WORKFLOW_CONFIG_FILE="$tmp_conf"
        # shellcheck source=/dev/null
        source "$PLANNING_CONFIG_LIB"
        get_max_remediation_cycles 2>&1
    ) || exit_code=$?

    # Must exit non-zero
    if [[ "$exit_code" -eq 0 ]]; then
        (( ++FAIL ))
        printf "FAIL: test_rejects_value_below_minimum — expected non-zero exit, got 0\n" >&2
    else
        (( ++PASS ))
    fi

    # stderr must contain the rejected value
    assert_contains "test_rejects_value_below_minimum: stderr contains rejected value" "got: 1" "$stderr_out"

    # stderr must contain the minimum
    assert_contains "test_rejects_value_below_minimum: stderr contains minimum" ">= 2" "$stderr_out"

    # stderr must mention the key name
    assert_contains "test_rejects_value_below_minimum: stderr contains key name" "planning.max_remediation_cycles" "$stderr_out"

    rm -f "$tmp_conf"
    assert_pass_if_clean "test_rejects_value_below_minimum"
}

# ---------------------------------------------------------------------------
# test_defaults_to_3_when_absent
# Given key absent from config
# When get_max_remediation_cycles is invoked
# Then prints "3" and exits 0
# ---------------------------------------------------------------------------
test_defaults_to_3_when_absent() {
    _snapshot_fail

    local tmp_conf result exit_code
    tmp_conf=$(mktemp "${TMPDIR:-/tmp}/test-planning-config.XXXXXX")
    printf 'paths.app_dir=app\n' > "$tmp_conf"

    exit_code=0
    result=$(
        WORKFLOW_CONFIG_FILE="$tmp_conf"
        # shellcheck source=/dev/null
        source "$PLANNING_CONFIG_LIB"
        get_max_remediation_cycles
    ) || exit_code=$?

    assert_eq "test_defaults_to_3_when_absent: exit 0" "0" "$exit_code"
    assert_eq "test_defaults_to_3_when_absent: output is 3" "3" "$result"

    rm -f "$tmp_conf"
    assert_pass_if_clean "test_defaults_to_3_when_absent"
}

# ---------------------------------------------------------------------------
# test_returns_valid_value_5
# Given key set to 5
# When get_max_remediation_cycles is invoked
# Then prints "5" and exits 0
# ---------------------------------------------------------------------------
test_returns_valid_value_5() {
    _snapshot_fail

    local tmp_conf result exit_code
    tmp_conf=$(mktemp "${TMPDIR:-/tmp}/test-planning-config.XXXXXX")
    printf 'planning.max_remediation_cycles=5\n' > "$tmp_conf"

    exit_code=0
    result=$(
        WORKFLOW_CONFIG_FILE="$tmp_conf"
        # shellcheck source=/dev/null
        source "$PLANNING_CONFIG_LIB"
        get_max_remediation_cycles
    ) || exit_code=$?

    assert_eq "test_returns_valid_value_5: exit 0" "0" "$exit_code"
    assert_eq "test_returns_valid_value_5: output is 5" "5" "$result"

    rm -f "$tmp_conf"
    assert_pass_if_clean "test_returns_valid_value_5"
}

# ---------------------------------------------------------------------------
# test_empty_value_treated_as_absent
# Given key present but value is empty string
# When get_max_remediation_cycles is invoked
# Then returns "3" and exits 0 (do NOT reject as < 2)
# ---------------------------------------------------------------------------
test_empty_value_treated_as_absent() {
    _snapshot_fail

    local tmp_conf result exit_code
    tmp_conf=$(mktemp "${TMPDIR:-/tmp}/test-planning-config.XXXXXX")
    printf 'planning.max_remediation_cycles=\n' > "$tmp_conf"

    exit_code=0
    result=$(
        WORKFLOW_CONFIG_FILE="$tmp_conf"
        # shellcheck source=/dev/null
        source "$PLANNING_CONFIG_LIB"
        get_max_remediation_cycles
    ) || exit_code=$?

    assert_eq "test_empty_value_treated_as_absent: exit 0" "0" "$exit_code"
    assert_eq "test_empty_value_treated_as_absent: output is 3" "3" "$result"

    rm -f "$tmp_conf"
    assert_pass_if_clean "test_empty_value_treated_as_absent"
}

# ---------------------------------------------------------------------------
# test_rejects_value_zero
# Given planning.max_remediation_cycles=0
# When get_max_remediation_cycles is invoked
# Then exits non-zero AND stderr names the rejected value and minimum
# ---------------------------------------------------------------------------
test_rejects_value_zero() {
    _snapshot_fail

    local tmp_conf exit_code stderr_out
    tmp_conf=$(mktemp "${TMPDIR:-/tmp}/test-planning-config.XXXXXX")
    printf 'planning.max_remediation_cycles=0\n' > "$tmp_conf"

    exit_code=0
    stderr_out=$(
        WORKFLOW_CONFIG_FILE="$tmp_conf"
        # shellcheck source=/dev/null
        source "$PLANNING_CONFIG_LIB"
        get_max_remediation_cycles 2>&1
    ) || exit_code=$?

    if [[ "$exit_code" -eq 0 ]]; then
        (( ++FAIL ))
        printf "FAIL: test_rejects_value_zero — expected non-zero exit, got 0\n" >&2
    else
        (( ++PASS ))
    fi

    assert_contains "test_rejects_value_zero: stderr contains rejected value" "got: 0" "$stderr_out"
    assert_contains "test_rejects_value_zero: stderr contains minimum" ">= 2" "$stderr_out"

    rm -f "$tmp_conf"
    assert_pass_if_clean "test_rejects_value_zero"
}

# ---------------------------------------------------------------------------
# test_minimum_value_2_accepted
# Given planning.max_remediation_cycles=2 (minimum valid value)
# When get_max_remediation_cycles is invoked
# Then prints "2" and exits 0
# ---------------------------------------------------------------------------
test_minimum_value_2_accepted() {
    _snapshot_fail

    local tmp_conf result exit_code
    tmp_conf=$(mktemp "${TMPDIR:-/tmp}/test-planning-config.XXXXXX")
    printf 'planning.max_remediation_cycles=2\n' > "$tmp_conf"

    exit_code=0
    result=$(
        WORKFLOW_CONFIG_FILE="$tmp_conf"
        # shellcheck source=/dev/null
        source "$PLANNING_CONFIG_LIB"
        get_max_remediation_cycles
    ) || exit_code=$?

    assert_eq "test_minimum_value_2_accepted: exit 0" "0" "$exit_code"
    assert_eq "test_minimum_value_2_accepted: output is 2" "2" "$result"

    rm -f "$tmp_conf"
    assert_pass_if_clean "test_minimum_value_2_accepted"
}

# ---------------------------------------------------------------------------
# Run all tests
# ---------------------------------------------------------------------------

test_rejects_value_below_minimum
test_defaults_to_3_when_absent
test_returns_valid_value_5
test_empty_value_treated_as_absent
test_rejects_value_zero
test_minimum_value_2_accepted

print_summary
