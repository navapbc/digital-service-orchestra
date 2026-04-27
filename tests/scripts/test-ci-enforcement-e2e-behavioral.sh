#!/usr/bin/env bash
# tests/scripts/test-ci-enforcement-e2e-behavioral.sh
# Behavioral tests for tests/scripts/test-ci-enforcement-e2e.sh
#
# RED phase: tests/scripts/test-ci-enforcement-e2e.sh does NOT exist yet.
# All tests are expected to FAIL until the GREEN task (1611-6951) creates it.
#
# Usage: bash tests/scripts/test-ci-enforcement-e2e-behavioral.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR" && git rev-parse --show-toplevel)"

source "$REPO_ROOT/tests/lib/assert.sh"

SCRIPT="$REPO_ROOT/tests/scripts/test-ci-enforcement-e2e.sh"

echo "=== test-ci-enforcement-e2e-behavioral.sh ==="

# -- test_opt_in_gate_exits_zero_skip -----------------------------------------
# Given: RUN_CI_E2E is absent
# When:  bash tests/scripts/test-ci-enforcement-e2e.sh 2>/dev/null
# Then:  exits 0 AND output contains "SKIP"
#
# RED: script does not exist yet — will exit non-zero (bash: file not found)
# and produce no "SKIP" output. Both assertions will FAIL.
_snapshot_fail
rc1=0
output1=""
output1="$(bash "$SCRIPT" 2>/dev/null)" || rc1=$?
assert_eq "test_opt_in_gate_exits_zero_skip exit" "0" "$rc1"
assert_contains "test_opt_in_gate_exits_zero_skip output contains SKIP" "SKIP" "$output1"
assert_pass_if_clean "test_opt_in_gate_exits_zero_skip"

# -- test_missing_repo_exits_nonzero ------------------------------------------
# Given: RUN_CI_E2E=1, CI_E2E_REPO absent
# When:  RUN_CI_E2E=1 bash tests/scripts/test-ci-enforcement-e2e.sh 2>/dev/null
# Then:  exits non-zero (1 or 2)
#
# RED: script does not exist yet — bash will exit non-zero, but rc==127 (not 1
# or 2) so the assertion will FAIL.
_snapshot_fail
rc2=0
RUN_CI_E2E=1 bash "$SCRIPT" 2>/dev/null || rc2=$?
is_nonzero2="$([ "$rc2" -ne 0 ] && echo true || echo false)"
assert_eq "test_missing_repo_exits_nonzero exit (non-zero)" "true" "$is_nonzero2"
assert_pass_if_clean "test_missing_repo_exits_nonzero"

# -- test_missing_gh_exits_nonzero --------------------------------------------
# Given: RUN_CI_E2E=1, CI_E2E_REPO=owner/repo, but gh not on PATH
# When:  RUN_CI_E2E=1 CI_E2E_REPO=owner/repo env PATH=/usr/bin:/bin bash ... 2>/dev/null
# Then:  exits non-zero (1 or 2)
#
# RED: script does not exist yet — bash will exit non-zero, but rc==127 (not 1
# or 2) so the assertion will FAIL.
_snapshot_fail
rc3=0
RUN_CI_E2E=1 CI_E2E_REPO=owner/repo env PATH=/usr/bin:/bin bash "$SCRIPT" 2>/dev/null || rc3=$?
is_nonzero3="$([ "$rc3" -ne 0 ] && echo true || echo false)"
assert_eq "test_missing_gh_exits_nonzero exit (non-zero)" "true" "$is_nonzero3"
assert_pass_if_clean "test_missing_gh_exits_nonzero"

print_summary
