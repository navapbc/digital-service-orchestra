#!/usr/bin/env bash
# tests/hooks/test-mechanical-amend-bypass.sh
# Behavioral tests for DSO_MECHANICAL_AMEND bypass in pre-commit hooks.
#
# Validates that:
#   1. pre-commit-review-gate.sh exits 0 when DSO_MECHANICAL_AMEND=1
#   2. pre-commit-test-gate.sh exits 0 when DSO_MECHANICAL_AMEND=1
#   3. merge-to-main.sh sets DSO_MECHANICAL_AMEND=1 before git commit --amend
#   4. review-gate-bypass-sentinel.sh blocks DSO_MECHANICAL_AMEND on non-amend commits
#
# Usage: bash tests/hooks/test-mechanical-amend-bypass.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DSO_PLUGIN_DIR="$REPO_ROOT/plugins/dso"
REVIEW_GATE="$DSO_PLUGIN_DIR/hooks/pre-commit-review-gate.sh"
TEST_GATE="$DSO_PLUGIN_DIR/hooks/pre-commit-test-gate.sh"
MERGE_SCRIPT="$DSO_PLUGIN_DIR/scripts/merge-to-main.sh"
SENTINEL_LIB="$DSO_PLUGIN_DIR/hooks/lib/review-gate-bypass-sentinel.sh"

source "$REPO_ROOT/tests/lib/assert.sh"

# =============================================================================
# Helper: extract function body from a script file
# =============================================================================
_extract_fn() {
    local fn_name="$1" script="$2"
    awk "/^${fn_name}\\(\\)/{found=1} found{print; if(/^\\}$/){exit}}" "$script"
}

# =============================================================================
# Test 1: pre-commit-review-gate.sh checks DSO_MECHANICAL_AMEND
# The review gate script must contain a check for DSO_MECHANICAL_AMEND that
# exits 0 early. This is a structural test — the actual hook runs in a git
# pre-commit context which is hard to simulate.
# =============================================================================
echo ""
echo "--- test_review_gate_has_mechanical_amend_check ---"
_snapshot_fail

_RG_HAS_CHECK="not_found"
grep -q 'DSO_MECHANICAL_AMEND' "$REVIEW_GATE" 2>/dev/null && _RG_HAS_CHECK="found"
assert_eq "test_review_gate_has_mechanical_amend_check" "found" "$_RG_HAS_CHECK"

assert_pass_if_clean "test_review_gate_has_mechanical_amend_check"

# =============================================================================
# Test 2: pre-commit-test-gate.sh checks DSO_MECHANICAL_AMEND
# The test gate script must contain a check for DSO_MECHANICAL_AMEND that
# exits 0 early.
# =============================================================================
echo ""
echo "--- test_test_gate_has_mechanical_amend_check ---"
_snapshot_fail

_TG_HAS_CHECK="not_found"
grep -q 'DSO_MECHANICAL_AMEND' "$TEST_GATE" 2>/dev/null && _TG_HAS_CHECK="found"
assert_eq "test_test_gate_has_mechanical_amend_check" "found" "$_TG_HAS_CHECK"

assert_pass_if_clean "test_test_gate_has_mechanical_amend_check"

# =============================================================================
# Test 3: merge-to-main.sh _phase_version_bump sets DSO_MECHANICAL_AMEND=1
# The version bump phase must export DSO_MECHANICAL_AMEND=1 before git commit
# --amend and unset it after.
# =============================================================================
echo ""
echo "--- test_version_bump_sets_mechanical_amend ---"
_snapshot_fail

_VB_FN=$(_extract_fn "_phase_version_bump" "$MERGE_SCRIPT" 2>/dev/null || echo "")
_VB_HAS_AMEND_VAR="not_found"
echo "$_VB_FN" | grep -q 'DSO_MECHANICAL_AMEND' 2>/dev/null && _VB_HAS_AMEND_VAR="found"
assert_eq "test_version_bump_sets_mechanical_amend" "found" "$_VB_HAS_AMEND_VAR"

assert_pass_if_clean "test_version_bump_sets_mechanical_amend"

# =============================================================================
# Test 4: merge-to-main.sh _phase_validate sets DSO_MECHANICAL_AMEND=1
# The validate phase also uses git commit --amend and must set the var.
# =============================================================================
echo ""
echo "--- test_validate_phase_sets_mechanical_amend ---"
_snapshot_fail

_VAL_FN=$(_extract_fn "_phase_validate" "$MERGE_SCRIPT" 2>/dev/null || echo "")
_VAL_HAS_AMEND_VAR="not_found"
echo "$_VAL_FN" | grep -q 'DSO_MECHANICAL_AMEND' 2>/dev/null && _VAL_HAS_AMEND_VAR="found"
assert_eq "test_validate_phase_sets_mechanical_amend" "found" "$_VAL_HAS_AMEND_VAR"

assert_pass_if_clean "test_validate_phase_sets_mechanical_amend"

# =============================================================================
# Test 5: review gate exits 0 early when DSO_MECHANICAL_AMEND=1
# The check must be an early exit (exit 0) not just a variable reference.
# Look for the pattern: DSO_MECHANICAL_AMEND followed by exit 0 within ~3 lines.
# =============================================================================
echo ""
echo "--- test_review_gate_exits_early_on_mechanical_amend ---"
_snapshot_fail

# Check that the script has an exit 0 associated with DSO_MECHANICAL_AMEND
_RG_EXIT_PATTERN=$(awk '/DSO_MECHANICAL_AMEND/{found=1} found && /exit 0/{print "yes"; exit}' "$REVIEW_GATE" 2>/dev/null || echo "")
assert_eq "test_review_gate_exits_early_on_mechanical_amend" "yes" "$_RG_EXIT_PATTERN"

assert_pass_if_clean "test_review_gate_exits_early_on_mechanical_amend"

# =============================================================================
# Test 6: test gate exits 0 early when DSO_MECHANICAL_AMEND=1
# Same pattern as test 5 but for the test gate.
# =============================================================================
echo ""
echo "--- test_test_gate_exits_early_on_mechanical_amend ---"
_snapshot_fail

_TG_EXIT_PATTERN=$(awk '/DSO_MECHANICAL_AMEND/{found=1} found && /exit 0/{print "yes"; exit}' "$TEST_GATE" 2>/dev/null || echo "")
assert_eq "test_test_gate_exits_early_on_mechanical_amend" "yes" "$_TG_EXIT_PATTERN"

assert_pass_if_clean "test_test_gate_exits_early_on_mechanical_amend"

# =============================================================================
# Test 7: bypass sentinel blocks DSO_MECHANICAL_AMEND on non-amend commits
# Layer 2 must detect DSO_MECHANICAL_AMEND=1 on raw "git commit" (without
# --amend) and block it. This prevents misuse of the env var to bypass gates
# on normal commits.
# =============================================================================
echo ""
echo "--- test_sentinel_blocks_mechanical_amend_on_raw_commit ---"
_snapshot_fail

_SENT_HAS_CHECK="not_found"
grep -q 'DSO_MECHANICAL_AMEND' "$SENTINEL_LIB" 2>/dev/null && _SENT_HAS_CHECK="found"
assert_eq "test_sentinel_has_mechanical_amend_check" "found" "$_SENT_HAS_CHECK"

# Functionally test: source the sentinel and call with a raw git commit that
# has DSO_MECHANICAL_AMEND=1 as an inline prefix in the command string.
# NOTE: The sentinel is a PreToolUse hook running in Claude Code's process, NOT
# a child of the git subprocess. The env var must be detected in the command
# string — exporting it to the test subshell would test the wrong execution model.
_SENT_RC=0
(
    source "$SENTINEL_LIB" 2>/dev/null
    # Simulate "DSO_MECHANICAL_AMEND=1 git commit -m test" (non-amend) — sentinel should block
    _INPUT='{"tool_name":"Bash","tool_input":{"command":"DSO_MECHANICAL_AMEND=1 git commit -m test"}}'
    hook_review_bypass_sentinel "$_INPUT" 2>/dev/null
) || _SENT_RC=$?

assert_eq "test_sentinel_blocks_mechanical_amend_on_raw_commit" "2" "$_SENT_RC"

assert_pass_if_clean "test_sentinel_blocks_mechanical_amend_on_raw_commit"

# =============================================================================
# Test 8: bypass sentinel allows DSO_MECHANICAL_AMEND on --amend --no-edit
# Layer 2 must allow the env var when the command is specifically
# "git commit --amend --no-edit" (the pattern used by merge-to-main.sh).
# =============================================================================
echo ""
echo "--- test_sentinel_allows_mechanical_amend_on_amend_noedit ---"
_snapshot_fail

_SENT_ALLOW_RC=0
(
    source "$SENTINEL_LIB" 2>/dev/null
    # Simulate "DSO_MECHANICAL_AMEND=1 git commit --amend --no-edit --quiet" — sentinel should allow
    # The env var is in the command string (inline prefix), not exported to the environment,
    # matching the actual runtime model where the sentinel is a PreToolUse hook process.
    _INPUT='{"tool_name":"Bash","tool_input":{"command":"DSO_MECHANICAL_AMEND=1 git commit --amend --no-edit --quiet"}}'
    hook_review_bypass_sentinel "$_INPUT" 2>/dev/null
) || _SENT_ALLOW_RC=$?

assert_eq "test_sentinel_allows_mechanical_amend_on_amend_noedit" "0" "$_SENT_ALLOW_RC"

assert_pass_if_clean "test_sentinel_allows_mechanical_amend_on_amend_noedit"

# =============================================================================
print_summary
