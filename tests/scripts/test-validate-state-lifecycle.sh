#!/usr/bin/env bash
# tests/scripts/test-validate-state-lifecycle.sh
# TDD tests for validate.sh in_progress/interrupted state lifecycle.
#
# Tests:
#   test_validate_writes_in_progress_at_startup — in_progress written before checks
#   test_validate_writes_interrupted_on_exit    — EXIT trap writes interrupted when in_progress
#   test_validate_in_progress_grep_present      — grep -q "in_progress" finds it in validate.sh
#   test_validate_interrupted_grep_present      — grep -q "interrupted" finds it in validate.sh
#   test_validate_syntax_valid                  — validate.sh passes bash -n
#
# Usage: bash tests/scripts/test-validate-state-lifecycle.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DSO_PLUGIN_DIR="$PLUGIN_ROOT/plugins/dso"
REPO_ROOT="$(git rev-parse --show-toplevel)"
VALIDATE_SCRIPT="$DSO_PLUGIN_DIR/scripts/validate.sh"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

echo "=== test-validate-state-lifecycle.sh ==="

# ============================================================================
# test_validate_in_progress_grep_present
# Acceptance criterion: grep -q "in_progress" scripts/validate.sh
# ============================================================================
echo ""
echo "=== test_validate_in_progress_grep_present ==="
_snapshot_fail

if grep -q "in_progress" "$VALIDATE_SCRIPT" 2>/dev/null; then
    IN_PROGRESS_FOUND="yes"
else
    IN_PROGRESS_FOUND="no"
fi
assert_eq "validate.sh contains in_progress string" "yes" "$IN_PROGRESS_FOUND"

assert_pass_if_clean "test_validate_in_progress_grep_present"

# ============================================================================
# test_validate_interrupted_grep_present
# Acceptance criterion: grep -q "interrupted" scripts/validate.sh
# ============================================================================
echo ""
echo "=== test_validate_interrupted_grep_present ==="
_snapshot_fail

if grep -q "interrupted" "$VALIDATE_SCRIPT" 2>/dev/null; then
    INTERRUPTED_FOUND="yes"
else
    INTERRUPTED_FOUND="no"
fi
assert_eq "validate.sh contains interrupted string" "yes" "$INTERRUPTED_FOUND"

assert_pass_if_clean "test_validate_interrupted_grep_present"

# ============================================================================
# test_validate_syntax_valid
# ============================================================================
echo ""
echo "=== test_validate_syntax_valid ==="
_snapshot_fail

if bash -n "$VALIDATE_SCRIPT" 2>/dev/null; then
    SYNTAX_OK="yes"
else
    SYNTAX_OK="no"
fi
assert_eq "validate.sh has valid bash syntax" "yes" "$SYNTAX_OK"

assert_pass_if_clean "test_validate_syntax_valid"

# ============================================================================
# test_validate_writes_in_progress_at_startup
# Verifies that in_progress is written to the status file before any checks
# run. We use a minimal stub environment that intercepts the ARTIFACTS_DIR.
#
# Strategy: Run validate.sh with all check commands set to "true" (instant
# success) in a temp directory. Capture the state file after completion.
# Since we can't observe the intermediate state with instant commands, we
# instead use a sentinel approach: replace one check command with a script
# that reads the state file. That script must see "in_progress".
# ============================================================================
echo ""
echo "=== test_validate_writes_in_progress_at_startup ==="
_snapshot_fail

# Create a temp workspace
_tmp_startup=$(mktemp -d)
_state_captured_file="$_tmp_startup/captured-state.txt"

# Create a stub check that reads the status file (written before checks launch)
_stub_dir="$_tmp_startup/stubs"
mkdir -p "$_stub_dir"

# We need to intercept VALIDATION_STATE_FILE — validate.sh uses ARTIFACTS_DIR
# (set by get_artifacts_dir from deps.sh). We can override by setting
# WORKTREE_NAME so that ARTIFACTS_DIR=/tmp/lockpick-test-artifacts-<name>
# goes to our controlled directory.
_wt_name="test-validate-state-$$"
_artifacts_dir="/tmp/lockpick-test-artifacts-${_wt_name}"
mkdir -p "$_artifacts_dir"

# Stub: capture the state file content when the first "real" check fires
cat > "$_stub_dir/capture-state.sh" << 'STUB'
#!/bin/bash
# Read the status file and save its first line (the state)
STATUS_FILE="$1"
OUT_FILE="$2"
# Give the status file a moment to be written (it should already be written)
sleep 0.1
if [ -f "$STATUS_FILE" ]; then
    head -n 1 "$STATUS_FILE" > "$OUT_FILE" 2>/dev/null || echo "READ_ERROR" > "$OUT_FILE"
else
    echo "FILE_NOT_FOUND" > "$OUT_FILE"
fi
exit 0
STUB
chmod +x "$_stub_dir/capture-state.sh"

# We will run validate.sh with the syntax check replaced by our capture script.
# All other checks are set to "true" (instant no-op success).
# We can't set ARTIFACTS_DIR directly since validate.sh overwrites it via
# get_artifacts_dir() if deps.sh is available. Instead we leverage the fact
# that validate.sh sets WORKTREE_NAME=$(basename "$REPO_ROOT"). We run the
# script with a fake REPO_ROOT that has basename matching our _wt_name.

# Create a fake repo root directory with the right basename
_fake_repo="$_tmp_startup/${_wt_name}"
mkdir -p "$_fake_repo"
# It must NOT have a .git file (so WORKTREE_MODE=0 and no worktree special path)
# It also needs dso-config.conf and APP_DIR structure to avoid config errors
mkdir -p "$_fake_repo/app"

# The validate.sh will set ARTIFACTS_DIR=/tmp/lockpick-test-artifacts-<_wt_name>
# which we created above. But if deps.sh provides get_artifacts_dir() it may
# override with a different path. We'll check by looking at what validate.sh
# sets as VALIDATION_STATE_FILE.

# The most reliable approach: just verify in_progress is written at some point
# by running validate.sh with a slow syntax check that polls the state file.
# But that requires running the real validate.sh against the real app, which
# is too slow and environment-dependent for a unit test.

# Simplified approach: parse validate.sh statically to confirm in_progress
# is written BEFORE the "wait" call that blocks for all checks to finish,
# meaning it is written before checks complete.

# Find line number of "in_progress" write vs line number of "wait" (after launching checks)
_in_progress_lines=$(grep -n 'in_progress' "$VALIDATE_SCRIPT" 2>/dev/null | grep -v '^\s*#' | grep -v 'ci.result\|CHECK_DIR\|ci_rc\|ci\.rc\|was_cancelled\|ci\.was_cancelled' || true)
_startup_write_line=$(echo "$_in_progress_lines" | grep '"in_progress"' | head -1 | cut -d: -f1)

# Find the first "wait" line after check launches (the blocking wait after background jobs)
# It appears after LAUNCHED_CHECKS and the background run_check calls
_wait_line=$(grep -n '^wait$' "$VALIDATE_SCRIPT" | head -1 | cut -d: -f1)

assert_ne "in_progress startup write line found in validate.sh" "" "$_startup_write_line"

if [[ -n "$_startup_write_line" && -n "$_wait_line" ]]; then
    if [[ "$_startup_write_line" -lt "$_wait_line" ]]; then
        _ordering="before_wait"
    else
        _ordering="after_wait"
    fi
    assert_eq "in_progress written before blocking wait (startup before checks complete)" "before_wait" "$_ordering"
fi

rm -rf "$_tmp_startup" "$_artifacts_dir" 2>/dev/null || true

assert_pass_if_clean "test_validate_writes_in_progress_at_startup"

# ============================================================================
# test_validate_writes_interrupted_on_exit
# Verifies that the EXIT trap writes "interrupted" when status is in_progress.
# Static analysis: the EXIT trap function should contain logic to write
# "interrupted" when the current state is "in_progress".
# ============================================================================
echo ""
echo "=== test_validate_writes_interrupted_on_exit ==="
_snapshot_fail

# The cleanup function (EXIT trap) should write "interrupted" if status is in_progress
# Verify: cleanup function block contains both "in_progress" check and "interrupted" write
_cleanup_body=$(awk '/^cleanup\(\)/{found=1} found{print; if(/^\}/) exit}' "$VALIDATE_SCRIPT" 2>/dev/null || true)

if echo "$_cleanup_body" | grep -q 'in_progress'; then
    CLEANUP_CHECKS_IN_PROGRESS="yes"
else
    CLEANUP_CHECKS_IN_PROGRESS="no"
fi
assert_eq "cleanup() EXIT trap checks for in_progress state" "yes" "$CLEANUP_CHECKS_IN_PROGRESS"

if echo "$_cleanup_body" | grep -q 'interrupted'; then
    CLEANUP_WRITES_INTERRUPTED="yes"
else
    CLEANUP_WRITES_INTERRUPTED="no"
fi
assert_eq "cleanup() EXIT trap writes interrupted state" "yes" "$CLEANUP_WRITES_INTERRUPTED"

assert_pass_if_clean "test_validate_writes_interrupted_on_exit"

# ============================================================================
# test_validate_interrupted_has_timestamp
# The interrupted state should include a timestamp for age-checking
# ============================================================================
echo ""
echo "=== test_validate_interrupted_has_timestamp ==="
_snapshot_fail

# Check that the interrupted write includes timestamp
_interrupted_write_context=$(grep -A 5 '"interrupted"' "$VALIDATE_SCRIPT" | grep -v '^\s*#' || true)
if echo "$_interrupted_write_context" | grep -q 'timestamp\|date'; then
    HAS_TIMESTAMP="yes"
else
    HAS_TIMESTAMP="no"
fi
assert_eq "interrupted state write includes timestamp" "yes" "$HAS_TIMESTAMP"

assert_pass_if_clean "test_validate_interrupted_has_timestamp"

print_summary
