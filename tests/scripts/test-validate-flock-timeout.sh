#!/usr/bin/env bash
# tests/scripts/test-validate-flock-timeout.sh
# TDD tests for validate.sh verbose_print flock timeout handling.
#
# Tests:
#   test_verbose_print_uses_flock_timeout    — flock -w 5 present in verbose_print
#   test_verbose_print_fallback_on_timeout   — fallback path reached when flock times out
#   test_verbose_print_flock_unavail_unchanged — existing no-flock fallback still present
#   test_validate_syntax_valid               — validate.sh passes bash -n
#
# Usage: bash tests/scripts/test-validate-flock-timeout.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DSO_PLUGIN_DIR="$PLUGIN_ROOT/plugins/dso"
REPO_ROOT="$(git rev-parse --show-toplevel)"
VALIDATE_SCRIPT="$DSO_PLUGIN_DIR/scripts/validate.sh"
VALIDATE_HELPERS_LIB="$DSO_PLUGIN_DIR/hooks/lib/validate-helpers.sh"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

echo "=== test-validate-flock-timeout.sh ==="

# ============================================================================
# test_verbose_print_uses_flock_timeout
# Acceptance criterion: grep -q "\-w 5\|--timeout" scripts/validate.sh
# ============================================================================
echo ""
echo "=== test_verbose_print_uses_flock_timeout ==="
_snapshot_fail

if grep -q "\-w 5\|--timeout" "$VALIDATE_SCRIPT" "$VALIDATE_HELPERS_LIB" 2>/dev/null; then
    FLOCK_TIMEOUT_FOUND="yes"
else
    FLOCK_TIMEOUT_FOUND="no"
fi
assert_eq "validate.sh verbose_print uses flock -w 5 timeout" "yes" "$FLOCK_TIMEOUT_FOUND"

assert_pass_if_clean "test_verbose_print_uses_flock_timeout"

# ============================================================================
# test_verbose_print_fallback_on_timeout
# The verbose_print function must have a fallback path when flock times out.
# Static analysis: the flock call using -w 5 must be followed by a non-zero
# exit check (|| pattern or if/fi block) that falls through to fallback output.
# ============================================================================
echo ""
echo "=== test_verbose_print_fallback_on_timeout ==="
_snapshot_fail

# Extract the verbose_print function body from validate.sh or the extracted helpers lib
_verbose_print_body=$(awk '/^verbose_print\(\)/{found=1} found{print; if(/^\}$/) exit}' "$VALIDATE_SCRIPT" 2>/dev/null || true)
[[ -z "$_verbose_print_body" ]] && _verbose_print_body=$(awk '/^verbose_print\(\)/{found=1} found{print; if(/^\}$/) exit}' "$VALIDATE_HELPERS_LIB" 2>/dev/null || true)

# Must contain flock with -w timeout
if [[ "$_verbose_print_body" =~ -w\ [0-9] ]]; then
    HAS_TIMEOUT_FLAG="yes"
else
    HAS_TIMEOUT_FLAG="no"
fi
assert_eq "verbose_print flock call has -w timeout flag" "yes" "$HAS_TIMEOUT_FLAG"

# Must have fallback output path (temp file + cat approach used when flock is unavailable or times out)
# The fallback uses mktemp + printf + cat pattern
if [[ "$_verbose_print_body" =~ mktemp|printf.*tmp|cat.*tmp ]]; then
    HAS_FALLBACK_OUTPUT="yes"
else
    HAS_FALLBACK_OUTPUT="no"
fi
assert_eq "verbose_print has fallback output path (mktemp/cat)" "yes" "$HAS_FALLBACK_OUTPUT"

# The flock timeout must trigger the fallback — check that there is a conditional
# that branches to the fallback (||, if flock fails, or similar pattern)
# Accept either: flock ... || fallback  OR  if ! flock ...; then fallback; fi
_flock_cond_re='flock.*[|][|]|if.*flock|flock.*&&|FLOCK_OK|flock_ok|flock_result|_flock_rc'
if [[ "$_verbose_print_body" =~ $_flock_cond_re ]]; then
    HAS_TIMEOUT_CONDITIONAL="yes"
elif [[ "$_verbose_print_body" =~ [|][|] ]]; then
    # Any || fallback pattern in the function is acceptable
    HAS_TIMEOUT_CONDITIONAL="yes"
else
    HAS_TIMEOUT_CONDITIONAL="no"
fi
assert_eq "verbose_print has conditional for flock timeout fallback" "yes" "$HAS_TIMEOUT_CONDITIONAL"

assert_pass_if_clean "test_verbose_print_fallback_on_timeout"

# ============================================================================
# test_verbose_print_flock_unavail_unchanged
# The existing fallback for when flock is NOT installed (command -v flock)
# must remain unchanged — the else branch from "if command -v flock" must
# still use the temp file + cat approach.
# ============================================================================
echo ""
echo "=== test_verbose_print_flock_unavail_unchanged ==="
_snapshot_fail

# The function must still check for flock availability
if [[ "$_verbose_print_body" == *"command -v flock"* ]]; then
    HAS_AVAILABILITY_CHECK="yes"
else
    HAS_AVAILABILITY_CHECK="no"
fi
assert_eq "verbose_print still checks flock availability (command -v flock)" "yes" "$HAS_AVAILABILITY_CHECK"

# The else branch for flock unavailable must still contain the temp file fallback
if [[ "$_verbose_print_body" == *"mktemp"* ]]; then
    HAS_MKTEMP_FALLBACK="yes"
else
    HAS_MKTEMP_FALLBACK="no"
fi
assert_eq "verbose_print still has mktemp-based fallback for flock unavailable" "yes" "$HAS_MKTEMP_FALLBACK"

assert_pass_if_clean "test_verbose_print_flock_unavail_unchanged"

# ============================================================================
# test_validate_syntax_valid
# validate.sh must pass bash syntax check after modification
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

print_summary
