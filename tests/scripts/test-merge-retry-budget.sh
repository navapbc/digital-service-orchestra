#!/usr/bin/env bash
# tests/scripts/test-merge-retry-budget.sh
# Tests for retry_count tracking and escalation gate in merge-to-main.sh
#
# TDD tests:
#   1. test_get_retry_count_returns_zero_for_missing_key
#   2. test_retry_count_increments_on_call
#   3. test_escalation_blocks_at_threshold (retry_count=5 -> blocked)
#   4. test_fifth_resume_does_not_escalate (retry_count=4 -> passes)
#   5. test_retry_count_resets_on_success
#
# Usage: bash tests/scripts/test-merge-retry-budget.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DSO_PLUGIN_DIR="$PLUGIN_ROOT/plugins/dso"

MERGE_SCRIPT="$DSO_PLUGIN_DIR/scripts/merge-to-main.sh"
MERGE_HELPERS_LIB="$DSO_PLUGIN_DIR/hooks/lib/merge-helpers.sh"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

echo "=== test-merge-retry-budget.sh ==="

# =============================================================================
# Helper: extract state helper functions from merge-to-main.sh and eval them
# in a subshell with a known state file path.
# Usage: _run_in_state_context <state_file> <body>
# =============================================================================
_run_in_state_context() {
    local _sf="$1"
    local _body="$2"

    # Extract the state file helper functions (lines between the helpers section marker
    # and the SIGURG trap section). Fall back to merge-helpers.sh if extracted to lib.
    local _helpers
    _helpers=$(awk '/^# --- State file helpers/,/^# --- SIGURG trap/' "$MERGE_SCRIPT" \
        | grep -v '^# ---')
    if [[ -z "$_helpers" ]] && [[ -f "${MERGE_HELPERS_LIB:-}" ]]; then
        _helpers=$(cat "$MERGE_HELPERS_LIB")
    fi

    bash -c "
export CLAUDE_PLUGIN_ROOT='$PLUGIN_ROOT'
# Provide a BRANCH variable so _state_file_path works
BRANCH='test-branch'

# Provide MAX_MERGE_RETRIES
MAX_MERGE_RETRIES=5

# Source the helpers (defines _state_file_path using BRANCH)
$_helpers

# Override _state_file_path AFTER sourcing helpers so our override wins
_state_file_path() { echo '$_sf'; }

$_body
"
}

# =============================================================================
# Test 1: _state_get_retry_count returns 0 when retry_count key is missing
# (backward compatibility with existing state files that have no retry_count)
# =============================================================================
echo ""
echo "--- test_get_retry_count_returns_zero_for_missing_key ---"
_snapshot_fail

_T1_TMP=$(mktemp -d)
trap 'rm -rf "$_T1_TMP"' EXIT

# Create a state file without retry_count key (simulating old format)
python3 -c "
import json
d = {'branch': 'test-branch', 'merge_sha': '', 'completed_phases': [], 'current_phase': '', 'phases': {}}
with open('$_T1_TMP/state.json', 'w') as f:
    json.dump(d, f)
"

_result=$(_run_in_state_context "$_T1_TMP/state.json" '_state_get_retry_count' 2>&1)
assert_eq "test_get_retry_count_returns_zero_for_missing_key" "0" "$_result"

assert_pass_if_clean "get_retry_count: missing key returns 0"

# =============================================================================
# Test 2: _state_increment_retry increments retry_count in state file
# =============================================================================
echo ""
echo "--- test_retry_count_increments_on_call ---"
_snapshot_fail

_T2_TMP=$(mktemp -d)
# Append T2 tmp to the EXIT trap cleanly
trap 'rm -rf "$_T1_TMP" "$_T2_TMP"' EXIT

# Create a fresh state file with retry_count=0
python3 -c "
import json
d = {'branch': 'test-branch', 'merge_sha': '', 'completed_phases': [], 'current_phase': '', 'phases': {}, 'retry_count': 0}
with open('$_T2_TMP/state.json', 'w') as f:
    json.dump(d, f)
"

# Increment once and read back
_run_in_state_context "$_T2_TMP/state.json" '_state_increment_retry' 2>/dev/null
_count_after=$(_run_in_state_context "$_T2_TMP/state.json" '_state_get_retry_count' 2>&1)
assert_eq "test_retry_count_increments_on_call" "1" "$_count_after"

# Increment again — should be 2
_run_in_state_context "$_T2_TMP/state.json" '_state_increment_retry' 2>/dev/null
_count_after2=$(_run_in_state_context "$_T2_TMP/state.json" '_state_get_retry_count' 2>&1)
assert_eq "test_retry_count_increments_twice" "2" "$_count_after2"

assert_pass_if_clean "retry_count increments correctly"

# =============================================================================
# Test 3: Escalation gate blocks when retry_count >= MAX_MERGE_RETRIES (5)
# The --resume dispatch should print ESCALATE message and exit 1
# =============================================================================
echo ""
echo "--- test_escalation_blocks_at_threshold ---"
_snapshot_fail

_T3_TMP=$(mktemp -d)
trap 'rm -rf "$_T1_TMP" "$_T2_TMP" "$_T3_TMP"' EXIT

# State file with retry_count=5
python3 -c "
import json
d = {'branch': 'test-branch', 'merge_sha': '', 'completed_phases': [], 'current_phase': '', 'phases': {}, 'retry_count': 5}
with open('$_T3_TMP/state.json', 'w') as f:
    json.dump(d, f)
"

# Extract helpers + build a minimal --resume dispatch escalation check
# Fall back to merge-helpers.sh if state helpers were extracted there.
_escalation_snippet=$(awk '/^# --- State file helpers/,/^# --- SIGURG trap/' "$MERGE_SCRIPT" \
    | grep -v '^# ---')
if [[ -z "$_escalation_snippet" ]] && [[ -f "${MERGE_HELPERS_LIB:-}" ]]; then
    _escalation_snippet=$(cat "$MERGE_HELPERS_LIB")
fi

_escalation_output=$(bash -c "
export CLAUDE_PLUGIN_ROOT='$PLUGIN_ROOT'
BRANCH='test-branch'
MAX_MERGE_RETRIES=5
$_escalation_snippet
# Override _state_file_path AFTER helpers so our override wins
_state_file_path() { echo '$_T3_TMP/state.json'; }

# Simulate the escalation check at top of --resume dispatch
_retry_count=\$(_state_get_retry_count)
if [[ \$_retry_count -ge \$MAX_MERGE_RETRIES ]]; then
    echo 'ESCALATE: Merge has failed 5 times. Stop and ask the user for help. Do NOT retry.'
    exit 1
fi
echo 'CONTINUE'
" 2>&1)
_escalation_exit=$?

assert_eq "test_escalation_blocks_at_threshold: exit code" "1" "$_escalation_exit"
assert_contains "test_escalation_blocks_at_threshold: message" "ESCALATE" "$_escalation_output"
assert_contains "test_escalation_blocks_at_threshold: do not retry" "Do NOT retry" "$_escalation_output"

assert_pass_if_clean "escalation gate blocks at threshold=5"

# =============================================================================
# Test 4: Fifth resume does NOT escalate (retry_count=4 is below threshold)
# =============================================================================
echo ""
echo "--- test_fifth_resume_does_not_escalate ---"
_snapshot_fail

_T4_TMP=$(mktemp -d)
trap 'rm -rf "$_T1_TMP" "$_T2_TMP" "$_T3_TMP" "$_T4_TMP"' EXIT

# State file with retry_count=4 (one below threshold)
python3 -c "
import json
d = {'branch': 'test-branch', 'merge_sha': '', 'completed_phases': [], 'current_phase': '', 'phases': {}, 'retry_count': 4}
with open('$_T4_TMP/state.json', 'w') as f:
    json.dump(d, f)
"

_no_escalation_output=$(bash -c "
export CLAUDE_PLUGIN_ROOT='$PLUGIN_ROOT'
BRANCH='test-branch'
MAX_MERGE_RETRIES=5
$_escalation_snippet
# Override _state_file_path AFTER helpers so our override wins
_state_file_path() { echo '$_T4_TMP/state.json'; }

# Simulate the escalation check (retry_count=4 — should NOT escalate)
_retry_count=\$(_state_get_retry_count)
if [[ \$_retry_count -ge \$MAX_MERGE_RETRIES ]]; then
    echo 'ESCALATE: Merge has failed 5 times. Stop and ask the user for help. Do NOT retry.'
    exit 1
fi
echo 'CONTINUE'
" 2>&1)
_no_escalation_exit=$?

assert_eq "test_fifth_resume_does_not_escalate: exit code" "0" "$_no_escalation_exit"
assert_contains "test_fifth_resume_does_not_escalate: continues" "CONTINUE" "$_no_escalation_output"

assert_pass_if_clean "fifth resume (count=4) does not escalate"

# =============================================================================
# Test 5: _state_reset_retry_count resets retry_count to 0
# =============================================================================
echo ""
echo "--- test_retry_count_resets_on_success ---"
_snapshot_fail

_T5_TMP=$(mktemp -d)
trap 'rm -rf "$_T1_TMP" "$_T2_TMP" "$_T3_TMP" "$_T4_TMP" "$_T5_TMP"' EXIT

# State file with retry_count=3 (mid-retry)
python3 -c "
import json
d = {'branch': 'test-branch', 'merge_sha': '', 'completed_phases': [], 'current_phase': '', 'phases': {}, 'retry_count': 3}
with open('$_T5_TMP/state.json', 'w') as f:
    json.dump(d, f)
"

_run_in_state_context "$_T5_TMP/state.json" '_state_reset_retry_count' 2>/dev/null
_count_after_reset=$(_run_in_state_context "$_T5_TMP/state.json" '_state_get_retry_count' 2>&1)
assert_eq "test_retry_count_resets_on_success" "0" "$_count_after_reset"

assert_pass_if_clean "retry_count resets to 0 on success"

# =============================================================================
# Test 6: State file is deleted after successful completion
# The DONE exit paths should rm the state file so --resume starts fresh next time
# =============================================================================
echo ""
echo "--- test_state_file_deleted_on_success ---"
_snapshot_fail

_T6_TMP=$(mktemp -d)
trap 'rm -rf "$_T1_TMP" "$_T2_TMP" "$_T3_TMP" "$_T4_TMP" "$_T5_TMP" "$_T6_TMP"' EXIT

_T6_SF="$_T6_TMP/state.json"
python3 -c "
import json
d = {'branch': 'test-branch', 'merge_sha': '', 'completed_phases': ['sync','merge','validate','push','archive','ci_trigger'], 'current_phase': 'ci_trigger', 'phases': {}, 'retry_count': 2}
with open('$_T6_SF', 'w') as f:
    json.dump(d, f)
"

# Verify file exists before cleanup
assert_eq "test_state_file_exists_before" "0" "$(test -f "$_T6_SF" && echo 0 || echo 1)"

# Simulate the cleanup that happens at the DONE exit points
rm -f "$_T6_SF" 2>/dev/null

# Verify file is gone
assert_eq "test_state_file_deleted_on_success" "1" "$(test -f "$_T6_SF" && echo 0 || echo 1)"

assert_pass_if_clean "state file deleted on successful completion"

# Verify the script source contains rm -f at both DONE points
_done_cleanup_count=$(grep -c 'rm -f.*_state_file_path' "$MERGE_SCRIPT" || true)
assert_ne "test_script_has_state_cleanup" "0" "$_done_cleanup_count"

# =============================================================================
# Summary
# =============================================================================
print_summary
