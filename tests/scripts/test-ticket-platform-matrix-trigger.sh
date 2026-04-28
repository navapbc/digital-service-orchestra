#!/usr/bin/env bash
# tests/scripts/test-ticket-platform-matrix-trigger.sh
# Structural tests for .github/workflows/ticket-platform-matrix.yml
#
# Tests covered:
#   1. test_pull_request_trigger_has_no_paths_filter         — pull_request must fire on every PR
#   2. test_strategy_does_not_have_continue_on_error         — key is invalid under strategy: in GH
#      Actions schema; placement caused workflow startup_failure (bug 9cb3-6ef0)
#   3. test_three_leg_names_in_workflow                       — all three matrix leg names present
#   4. test_required_checks_txt_exists_and_contains_leg_names — required-checks.txt lists all legs
#
# Usage: bash tests/scripts/test-ticket-platform-matrix-trigger.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
WORKFLOW_FILE="$REPO_ROOT/.github/workflows/ticket-platform-matrix.yml"
REQUIRED_CHECKS_FILE="$REPO_ROOT/.github/required-checks.txt"

# shellcheck source=../lib/assert.sh
source "$REPO_ROOT/tests/lib/assert.sh"

echo "=== test-ticket-platform-matrix-trigger.sh ==="

# ── test_pull_request_trigger_has_no_paths_filter ────────────────────────────
# The pull_request trigger must NOT have a paths: key.
# RED: current workflow has paths: under on.pull_request.
_snapshot_fail
no_paths_exit=0
no_paths_output=""
no_paths_output=$(python3 -c "
import yaml, sys
with open('$WORKFLOW_FILE') as f:
    doc = yaml.safe_load(f)
# YAML 'on' is parsed as Python True in PyYAML
on_block = doc.get(True, doc.get('on', {})) or {}
pr_block = on_block.get('pull_request', {})
if pr_block is None:
    pr_block = {}
if 'paths' in pr_block:
    print('HAS_PATHS_FILTER: on.pull_request has paths: ' + str(pr_block['paths']))
    sys.exit(1)
print('OK')
" 2>&1) || no_paths_exit=$?
assert_eq "test_pull_request_trigger_has_no_paths_filter: exit 0" "0" "$no_paths_exit"
assert_eq "test_pull_request_trigger_has_no_paths_filter: no paths: key under pull_request" "OK" "$no_paths_output"
assert_pass_if_clean "test_pull_request_trigger_has_no_paths_filter"

# ── test_strategy_does_not_have_continue_on_error ────────────────────────────
# jobs['ticket-platform-tests']['strategy']['continue-on-error'] must NOT exist.
# Per the GitHub Actions schema, valid strategy keys are fail-fast, matrix, max-parallel.
# Placing continue-on-error under strategy: causes workflow startup_failure (bug 9cb3-6ef0).
_snapshot_fail
coe_exit=0
coe_output=""
coe_output=$(python3 -c "
import yaml, sys
with open('$WORKFLOW_FILE') as f:
    doc = yaml.safe_load(f)
jobs = doc.get('jobs', {})
job = jobs.get('ticket-platform-tests', {})
strategy = job.get('strategy', {})
if 'continue-on-error' in strategy:
    print('INVALID_KEY: strategy.continue-on-error is present (invalid GH Actions schema; causes startup_failure)')
    sys.exit(1)
print('OK')
" 2>&1) || coe_exit=$?
assert_eq "test_strategy_does_not_have_continue_on_error: exit 0" "0" "$coe_exit"
assert_eq "test_strategy_does_not_have_continue_on_error: strategy.continue-on-error absent" "OK" "$coe_output"
assert_pass_if_clean "test_strategy_does_not_have_continue_on_error"

# ── test_three_leg_names_in_workflow ─────────────────────────────────────────
# All three matrix leg names must exist in strategy.matrix.include.
# Names: linux-bash4, macos-bash3, alpine-busybox
# This test may PASS already if the names are present in the current file.
_snapshot_fail
legs_exit=0
legs_output=""
legs_output=$(python3 -c "
import yaml, sys
with open('$WORKFLOW_FILE') as f:
    doc = yaml.safe_load(f)
jobs = doc.get('jobs', {})
job = jobs.get('ticket-platform-tests', {})
strategy = job.get('strategy', {})
matrix = strategy.get('matrix', {})
include = matrix.get('include', [])
names = [item.get('name', '') for item in include]
required_names = ['linux-bash4', 'macos-bash3', 'alpine-busybox']
missing = [n for n in required_names if n not in names]
if missing:
    print('MISSING_LEG_NAMES: ' + ', '.join(missing) + ' not in ' + str(names))
    sys.exit(1)
print('OK')
" 2>&1) || legs_exit=$?
assert_eq "test_three_leg_names_in_workflow: exit 0" "0" "$legs_exit"
assert_eq "test_three_leg_names_in_workflow: all three leg names present" "OK" "$legs_output"
assert_pass_if_clean "test_three_leg_names_in_workflow"

# ── test_required_checks_txt_exists_and_contains_leg_names ───────────────────
# .github/required-checks.txt must exist AND contain all three leg names.
# RED: file does not yet exist.
_snapshot_fail
rc_file_exists="missing"
if [[ -f "$REQUIRED_CHECKS_FILE" ]]; then
    rc_file_exists="exists"
fi
assert_eq "test_required_checks_txt_exists_and_contains_leg_names: file exists" "exists" "$rc_file_exists"

if [[ "$rc_file_exists" == "exists" ]]; then
    rc_linux="missing"
    rc_macos="missing"
    rc_alpine="missing"
    if grep -q 'linux-bash4' "$REQUIRED_CHECKS_FILE" 2>/dev/null; then
        rc_linux="found"
    fi
    if grep -q 'macos-bash3' "$REQUIRED_CHECKS_FILE" 2>/dev/null; then
        rc_macos="found"
    fi
    if grep -q 'alpine-busybox' "$REQUIRED_CHECKS_FILE" 2>/dev/null; then
        rc_alpine="found"
    fi
    assert_eq "test_required_checks_txt_exists_and_contains_leg_names: linux-bash4 present" "found" "$rc_linux"
    assert_eq "test_required_checks_txt_exists_and_contains_leg_names: macos-bash3 present" "found" "$rc_macos"
    assert_eq "test_required_checks_txt_exists_and_contains_leg_names: alpine-busybox present" "found" "$rc_alpine"
fi
assert_pass_if_clean "test_required_checks_txt_exists_and_contains_leg_names"

# ── Summary ───────────────────────────────────────────────────────────────────
print_summary
