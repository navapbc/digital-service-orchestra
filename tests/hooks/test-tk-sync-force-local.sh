#!/usr/bin/env bash
# tests/hooks/test-tk-sync-force-local.sh
# Tests for tk sync --force-local conflict resolution.
#
# Verifies:
#   1. --force-local flag is accepted by cmd_sync argument parser
#   2. --force-local sets TK_SYNC_FORCE_LOCAL=1 (via static analysis)
#   3. _sync_push_ticket checks TK_SYNC_FORCE_LOCAL for conflict resolution
#   4. _sync_pull_ticket checks TK_SYNC_FORCE_LOCAL for conflict resolution
#   5. Push conflict path returns exit 4 (not 3) when force-local is set
#   6. Without --force-local, conflict paths return 3
#   7. bash -n syntax check
#
# These tests use static code analysis of scripts/tk since the script
# cannot be sourced (it has a main dispatch at the bottom) and cannot
# be run end-to-end without acli/Jira credentials.
#
# Usage: bash tests/hooks/test-tk-sync-force-local.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
REPO_ROOT="$(git rev-parse --show-toplevel)"
TK_SCRIPT="$PLUGIN_ROOT/scripts/tk"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

# Temp dir cleanup on exit
_CLEANUP_DIRS=()
_cleanup() { for d in "${_CLEANUP_DIRS[@]}"; do rm -rf "$d"; done; }
trap _cleanup EXIT

echo "=== test-tk-sync-force-local.sh ==="
echo ""

# ---------------------------------------------------------------------------
# Test 1: --force-local is accepted without error
# Run tk sync --force-local with a mock acli that fails immediately.
# The important thing is that argument parsing succeeds (no "unknown option").
# ---------------------------------------------------------------------------
echo "Test 1: --force-local flag accepted by argument parser"
_T1_OUTPUT=""
_T1_EXIT=0
# Mock acli with a stub that exits immediately to avoid real Jira calls.
# PATH="/dev/null:$PATH" does NOT work on macOS (/dev/null is a char device,
# not a directory — the shell skips it and finds the real acli).
_T1_MOCK_DIR=$(mktemp -d)
_CLEANUP_DIRS+=("$_T1_MOCK_DIR")
printf '#!/usr/bin/env bash\necho "Error: acli not authenticated" >&2; exit 1\n' > "$_T1_MOCK_DIR/acli"
chmod +x "$_T1_MOCK_DIR/acli"
_T1_OUTPUT=$(PATH="$_T1_MOCK_DIR:$PATH" bash "$TK_SCRIPT" sync --force-local 2>&1) || _T1_EXIT=$?
rm -rf "$_T1_MOCK_DIR"
# Should fail because acli stub fails connectivity (exit 1), NOT because of unknown flag
_T1_HAS_UNKNOWN=0
if echo "$_T1_OUTPUT" | grep -qi "unknown.*option"; then
    _T1_HAS_UNKNOWN=1
fi
assert_eq "test_force_local_accepted" "0" "$_T1_HAS_UNKNOWN"

# ---------------------------------------------------------------------------
# Test 2: cmd_sync exports TK_SYNC_FORCE_LOCAL=1 when --force-local is passed
# Static analysis: verify the export statement exists in the code path
# after the --force-local flag is parsed.
# ---------------------------------------------------------------------------
echo "Test 2: cmd_sync exports TK_SYNC_FORCE_LOCAL when --force-local parsed"
# Verify: the cmd_sync function contains "export TK_SYNC_FORCE_LOCAL=1"
_T2_HAS_EXPORT=$(grep -c 'export TK_SYNC_FORCE_LOCAL=1' "$TK_SCRIPT" || true)
assert_ne "test_export_exists" "0" "$_T2_HAS_EXPORT"

# Verify: the export is conditional on force_local variable
_T2_HAS_CONDITIONAL=$(grep -B2 'export TK_SYNC_FORCE_LOCAL=1' "$TK_SCRIPT" | grep -c 'force_local' || true)
assert_ne "test_export_conditional_on_flag" "0" "$_T2_HAS_CONDITIONAL"

# ---------------------------------------------------------------------------
# Test 3: _sync_push_ticket reads TK_SYNC_FORCE_LOCAL for conflict resolution
# Static analysis: verify the push function checks the env var.
# ---------------------------------------------------------------------------
echo "Test 3: _sync_push_ticket checks TK_SYNC_FORCE_LOCAL"
# Extract the _sync_push_ticket function body and check for env var reference
_T3_PUSH_CHECK=$(sed -n '/_sync_push_ticket()/,/^}/p' "$TK_SCRIPT" | grep -c 'TK_SYNC_FORCE_LOCAL' || true)
assert_ne "test_push_checks_force_local" "0" "$_T3_PUSH_CHECK"

# Verify: push conflict path with force-local sets _SYNC_FORCE_RESOLVED=1
_T3_FORCE_RESOLVED=$(sed -n '/_sync_push_ticket()/,/^}/p' "$TK_SCRIPT" | grep -c '_SYNC_FORCE_RESOLVED=1' || true)
assert_ne "test_push_sets_force_resolved" "0" "$_T3_FORCE_RESOLVED"

# ---------------------------------------------------------------------------
# Test 4: _sync_pull_ticket reads TK_SYNC_FORCE_LOCAL for conflict resolution
# Static analysis: verify the pull function checks the env var and returns 4.
# ---------------------------------------------------------------------------
echo "Test 4: _sync_pull_ticket checks TK_SYNC_FORCE_LOCAL and returns 4"
_T4_PULL_CHECK=$(sed -n '/_sync_pull_ticket()/,/^}/p' "$TK_SCRIPT" | grep -c 'TK_SYNC_FORCE_LOCAL' || true)
assert_ne "test_pull_checks_force_local" "0" "$_T4_PULL_CHECK"

# Verify: pull conflict path with force-local returns 4
_T4_PULL_RETURN4=$(sed -n '/_sync_pull_ticket()/,/^}/p' "$TK_SCRIPT" | grep -c 'return 4' || true)
assert_ne "test_pull_returns_4_on_force" "0" "$_T4_PULL_RETURN4"

# ---------------------------------------------------------------------------
# Test 5: Without --force-local, conflict paths return 3 (not 4)
# Static analysis: verify the non-force conflict paths return 3.
# ---------------------------------------------------------------------------
echo "Test 5: conflict paths return 3 without --force-local"
# Push conflict: "return 3" exists in the else branch (non-force path)
_T5_PUSH_RETURN3=$(sed -n '/_sync_push_ticket()/,/^}/p' "$TK_SCRIPT" | grep -c 'return 3' || true)
assert_ne "test_push_returns_3_on_conflict" "0" "$_T5_PUSH_RETURN3"

# Pull conflict: "return 3" exists in the else branch (non-force path)
_T5_PULL_RETURN3=$(sed -n '/_sync_pull_ticket()/,/^}/p' "$TK_SCRIPT" | grep -c 'return 3' || true)
assert_ne "test_pull_returns_3_on_conflict" "0" "$_T5_PULL_RETURN3"

# ---------------------------------------------------------------------------
# Test 6: cmd_sync counts force-resolved conflicts separately
# Static analysis: verify sync_forced counter and exit code 4 handling.
# ---------------------------------------------------------------------------
echo "Test 6: cmd_sync counts force-resolved conflicts (exit 4)"
_T6_FORCED_COUNTER=$(grep -c 'sync_forced' "$TK_SCRIPT" || true)
# Should appear multiple times: declaration, increment, summary output
assert_ne "test_forced_counter_exists" "0" "$_T6_FORCED_COUNTER"

# Verify: exit code 4 is handled in the push loop
_T6_EXIT4_HANDLING=$(grep -c '_push_exit -eq 4' "$TK_SCRIPT" || true)
assert_ne "test_exit4_handling" "0" "$_T6_EXIT4_HANDLING"

# ---------------------------------------------------------------------------
# Test 7: bash -n syntax check
# ---------------------------------------------------------------------------
echo "Test 7: scripts/tk has no bash syntax errors"
_T7_EXIT=0
bash -n "$TK_SCRIPT" 2>&1 || _T7_EXIT=$?
assert_eq "test_syntax_ok" "0" "$_T7_EXIT"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
print_summary
