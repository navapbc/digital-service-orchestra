#!/usr/bin/env bash
# tests/scripts/test-check-manifest-completeness.sh
# TDD tests for plugins/dso/scripts/check-manifest-completeness.sh
#
# Tests cover: complete JSON with all 5 required fields exits 0,
# JSON missing criteria_results exits 1, JSON missing consumer_smoke_tests exits 1.
#
# Usage: bash tests/scripts/test-check-manifest-completeness.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail
#
# RED STATE: All tests currently fail because check-manifest-completeness.sh does not
# yet exist. They will pass (GREEN) after the script is implemented.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SCRIPT="$PLUGIN_ROOT/plugins/dso/scripts/check-manifest-completeness.sh"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

echo "=== test-check-manifest-completeness.sh ==="

# ── test_complete_json_exits_0 ─────────────────────────────────────────────────
# Complete verifier JSON with all 5 required fields must exit 0
test_complete_json_exits_0() {
    _snapshot_fail
    local rc=0
    printf '%s' '{
  "criteria_results": {"SC1": "PASS", "SC2": "PASS"},
  "consumer_smoke_tests": {"all": "PASS"},
  "ticket_id": "bbb5-1435-1983-4676",
  "overall_verdict": "PASS",
  "remediation_tasks_created": []
}' | bash "$SCRIPT" 2>/dev/null || rc=$?
    assert_eq "test_complete_json_exits_0: exit code is 0 for complete JSON" "0" "$rc"
    assert_pass_if_clean "test_complete_json_exits_0"
}

# ── test_missing_criteria_results_exits_1 ─────────────────────────────────────
# JSON missing criteria_results field must exit 1
test_missing_criteria_results_exits_1() {
    _snapshot_fail
    local rc=0
    printf '%s' '{
  "consumer_smoke_tests": {"all": "PASS"},
  "ticket_id": "bbb5-1435-1983-4676",
  "overall_verdict": "PASS",
  "remediation_tasks_created": []
}' | bash "$SCRIPT" 2>/dev/null || rc=$?
    assert_eq "test_missing_criteria_results_exits_1: exit code is 1 for missing criteria_results" "1" "$rc"
    assert_pass_if_clean "test_missing_criteria_results_exits_1"
}

# ── test_missing_consumer_smoke_tests_exits_1 ─────────────────────────────────
# JSON with criteria_results present but missing consumer_smoke_tests must exit 1
test_missing_consumer_smoke_tests_exits_1() {
    _snapshot_fail
    local rc=0
    printf '%s' '{
  "criteria_results": {"SC1": "PASS", "SC2": "PASS"},
  "ticket_id": "bbb5-1435-1983-4676",
  "overall_verdict": "PASS",
  "remediation_tasks_created": []
}' | bash "$SCRIPT" 2>/dev/null || rc=$?
    assert_eq "test_missing_consumer_smoke_tests_exits_1: exit code is 1 for missing consumer_smoke_tests" "1" "$rc"
    assert_pass_if_clean "test_missing_consumer_smoke_tests_exits_1"
}

# ── Run all tests ──────────────────────────────────────────────────────────────
test_complete_json_exits_0
test_missing_criteria_results_exits_1
test_missing_consumer_smoke_tests_exits_1

print_summary
