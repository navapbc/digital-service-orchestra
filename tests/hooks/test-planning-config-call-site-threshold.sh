#!/usr/bin/env bash
# tests/hooks/test-planning-config-call-site-threshold.sh
# Behavioral tests for get_call_site_threshold() in planning-config.sh.
#
# Tests verify:
#   1. Value < 1 (e.g., 0) → non-zero exit AND stderr contains rejected value and minimum (1)
#   2. Key absent → prints "3" (documented default), exits 0
#   3. Key set to valid value (25) → prints "25", exits 0
#   4. Key present but empty string → treats as absent → prints "3", exits 0 (do NOT reject)
#
# Stderr error format: "migration.call_site_threshold must be >= 1 (got: <value>)"
#
# Usage: bash tests/hooks/test-planning-config-call-site-threshold.sh
# Exit code: 0 if all pass, 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"
PLANNING_CONFIG_LIB="$REPO_ROOT/plugins/dso/hooks/lib/planning-config.sh"

source "$REPO_ROOT/tests/lib/assert.sh"

echo "=== test-planning-config-call-site-threshold.sh ==="

# ---------------------------------------------------------------------------
# test_rejects_value_below_minimum
# Given dso-config.conf with migration.call_site_threshold=0
# When get_call_site_threshold is sourced and invoked
# Then exits non-zero AND stderr contains rejected value and minimum (1)
# ---------------------------------------------------------------------------
test_rejects_value_below_minimum() {
    _snapshot_fail

    local tmp_conf exit_code stderr_out
    tmp_conf=$(mktemp "${TMPDIR:-/tmp}/test-planning-config-cst.XXXXXX")
    printf 'migration.call_site_threshold=0\n' > "$tmp_conf"

    exit_code=0
    stderr_out=$(
        WORKFLOW_CONFIG_FILE="$tmp_conf"
        # shellcheck source=/dev/null
        source "$PLANNING_CONFIG_LIB"
        get_call_site_threshold 2>&1
    ) || exit_code=$?

    # Must exit non-zero
    if [[ "$exit_code" -eq 0 ]]; then
        (( ++FAIL ))
        printf "FAIL: test_rejects_value_below_minimum — expected non-zero exit, got 0\n" >&2
    else
        (( ++PASS ))
    fi

    # stderr must contain the rejected value
    assert_contains "test_rejects_value_below_minimum: stderr contains rejected value" "got: 0" "$stderr_out"

    # stderr must contain the minimum
    assert_contains "test_rejects_value_below_minimum: stderr contains minimum" ">= 1" "$stderr_out"

    # stderr must mention the key name
    assert_contains "test_rejects_value_below_minimum: stderr contains key name" "migration.call_site_threshold" "$stderr_out"

    rm -f "$tmp_conf"
    assert_pass_if_clean "test_rejects_value_below_minimum"
}

# ---------------------------------------------------------------------------
# test_defaults_when_absent
# Given key absent from config
# When get_call_site_threshold is invoked
# Then prints "3" and exits 0
# ---------------------------------------------------------------------------
test_defaults_when_absent() {
    _snapshot_fail

    local tmp_conf result exit_code
    tmp_conf=$(mktemp "${TMPDIR:-/tmp}/test-planning-config-cst.XXXXXX")
    printf 'paths.app_dir=app\n' > "$tmp_conf"

    exit_code=0
    result=$(
        WORKFLOW_CONFIG_FILE="$tmp_conf"
        # shellcheck source=/dev/null
        source "$PLANNING_CONFIG_LIB"
        get_call_site_threshold
    ) || exit_code=$?

    assert_eq "test_defaults_when_absent: exit 0" "0" "$exit_code"
    assert_eq "test_defaults_when_absent: output is documented default" "3" "$result"

    rm -f "$tmp_conf"
    assert_pass_if_clean "test_defaults_when_absent"
}

# ---------------------------------------------------------------------------
# test_returns_valid_value_25
# Given key set to 25
# When get_call_site_threshold is invoked
# Then prints "25" and exits 0
# ---------------------------------------------------------------------------
test_returns_valid_value_25() {
    _snapshot_fail

    local tmp_conf result exit_code
    tmp_conf=$(mktemp "${TMPDIR:-/tmp}/test-planning-config-cst.XXXXXX")
    printf 'migration.call_site_threshold=25\n' > "$tmp_conf"

    exit_code=0
    result=$(
        WORKFLOW_CONFIG_FILE="$tmp_conf"
        # shellcheck source=/dev/null
        source "$PLANNING_CONFIG_LIB"
        get_call_site_threshold
    ) || exit_code=$?

    assert_eq "test_returns_valid_value_25: exit 0" "0" "$exit_code"
    assert_eq "test_returns_valid_value_25: output is 25" "25" "$result"

    rm -f "$tmp_conf"
    assert_pass_if_clean "test_returns_valid_value_25"
}

# ---------------------------------------------------------------------------
# test_empty_value_treated_as_absent
# Given key present but value is empty string
# When get_call_site_threshold is invoked
# Then returns "3" and exits 0 (do NOT reject as < 1)
# ---------------------------------------------------------------------------
test_empty_value_treated_as_absent() {
    _snapshot_fail

    local tmp_conf result exit_code
    tmp_conf=$(mktemp "${TMPDIR:-/tmp}/test-planning-config-cst.XXXXXX")
    printf 'migration.call_site_threshold=\n' > "$tmp_conf"

    exit_code=0
    result=$(
        WORKFLOW_CONFIG_FILE="$tmp_conf"
        # shellcheck source=/dev/null
        source "$PLANNING_CONFIG_LIB"
        get_call_site_threshold
    ) || exit_code=$?

    assert_eq "test_empty_value_treated_as_absent: exit 0" "0" "$exit_code"
    assert_eq "test_empty_value_treated_as_absent: output is 3" "3" "$result"

    rm -f "$tmp_conf"
    assert_pass_if_clean "test_empty_value_treated_as_absent"
}

# ---------------------------------------------------------------------------
# test_minimum_value_1_accepted
# Given migration.call_site_threshold=1 (minimum valid value)
# When get_call_site_threshold is invoked
# Then prints "1" and exits 0
# ---------------------------------------------------------------------------
test_minimum_value_1_accepted() {
    _snapshot_fail

    local tmp_conf result exit_code
    tmp_conf=$(mktemp "${TMPDIR:-/tmp}/test-planning-config-cst.XXXXXX")
    printf 'migration.call_site_threshold=1\n' > "$tmp_conf"

    exit_code=0
    result=$(
        WORKFLOW_CONFIG_FILE="$tmp_conf"
        # shellcheck source=/dev/null
        source "$PLANNING_CONFIG_LIB"
        get_call_site_threshold
    ) || exit_code=$?

    assert_eq "test_minimum_value_1_accepted: exit 0" "0" "$exit_code"
    assert_eq "test_minimum_value_1_accepted: output is 1" "1" "$result"

    rm -f "$tmp_conf"
    assert_pass_if_clean "test_minimum_value_1_accepted"
}

# ---------------------------------------------------------------------------
# Run all tests
# ---------------------------------------------------------------------------

test_rejects_value_below_minimum
test_defaults_when_absent
test_returns_valid_value_25
test_empty_value_treated_as_absent
test_minimum_value_1_accepted

print_summary
