#!/usr/bin/env bash
# tests/scripts/test-render-closure-narrative.sh
# TDD tests for plugins/dso/scripts/render-closure-narrative.sh
#
# Tests cover: P1=PASS all-criteria-met rendering, P1=FAIL partial rendering,
# determinism across 3 runs with same input, and missing criteria_results error path.
#
# Usage: bash tests/scripts/test-render-closure-narrative.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail
#
# RED STATE: All tests currently fail because render-closure-narrative.sh does not
# yet exist. They will pass (GREEN) after the script is implemented.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SCRIPT="$PLUGIN_ROOT/plugins/dso/scripts/render-closure-narrative.sh"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

echo "=== test-render-closure-narrative.sh ==="

# ── test_p1_pass_all_criteria_met ─────────────────────────────────────────────
# JSON with P1=PASS and 3 criteria all PASS must render the expected narrative.
# Template: "P1={P1} criteria_met={N}/{total} blocked_by={B}"
test_p1_pass_all_criteria_met() {
    _snapshot_fail
    local json
    json='{"P1":"PASS","criteria_results":[{"status":"PASS"},{"status":"PASS"},{"status":"PASS"}]}'
    local output
    output=$(echo "$json" | bash "$SCRIPT" 2>/dev/null)
    assert_eq "test_p1_pass_all_criteria_met: narrative string" \
        "P1=PASS criteria_met=3/3 blocked_by=0" "$output"
    assert_pass_if_clean "test_p1_pass_all_criteria_met"
}

# ── test_p1_fail_partial_criteria ─────────────────────────────────────────────
# JSON with P1=FAIL and 2 criteria (1 PASS, 1 FAIL) must render correct counts.
test_p1_fail_partial_criteria() {
    _snapshot_fail
    local json
    json='{"P1":"FAIL","criteria_results":[{"status":"PASS"},{"status":"FAIL"}]}'
    local output
    output=$(echo "$json" | bash "$SCRIPT" 2>/dev/null)
    assert_eq "test_p1_fail_partial_criteria: narrative string" \
        "P1=FAIL criteria_met=1/2 blocked_by=1" "$output"
    assert_pass_if_clean "test_p1_fail_partial_criteria"
}

# ── test_determinism_three_runs ───────────────────────────────────────────────
# Same valid JSON input run 3 times must produce identical output on every run.
test_determinism_three_runs() {
    _snapshot_fail
    local json
    json='{"P1":"PASS","criteria_results":[{"status":"PASS"},{"status":"FAIL"},{"status":"PASS"}]}'
    local out1 out2 out3
    out1=$(echo "$json" | bash "$SCRIPT" 2>/dev/null)
    out2=$(echo "$json" | bash "$SCRIPT" 2>/dev/null)
    out3=$(echo "$json" | bash "$SCRIPT" 2>/dev/null)
    assert_eq "test_determinism_three_runs: run1 == run2" "$out1" "$out2"
    assert_eq "test_determinism_three_runs: run1 == run3" "$out1" "$out3"
    assert_pass_if_clean "test_determinism_three_runs"
}

# ── test_missing_criteria_results_exits_nonzero ───────────────────────────────
# JSON with no criteria_results field must exit non-zero and emit error to stderr.
test_missing_criteria_results_exits_nonzero() {
    _snapshot_fail
    local json
    json='{"P1":"PASS"}'
    local rc=0
    local stderr_output
    stderr_output=$(echo "$json" | bash "$SCRIPT" 2>&1 >/dev/null) || rc=$?
    assert_ne "test_missing_criteria_results_exits_nonzero: exit code is non-zero" \
        "0" "$rc"
    assert_contains "test_missing_criteria_results_exits_nonzero: stderr contains error" \
        "criteria_results" "$stderr_output"
    assert_pass_if_clean "test_missing_criteria_results_exits_nonzero"
}

# ── Run all tests ──────────────────────────────────────────────────────────────
test_p1_pass_all_criteria_met
test_p1_fail_partial_criteria
test_determinism_three_runs
test_missing_criteria_results_exits_nonzero

print_summary
