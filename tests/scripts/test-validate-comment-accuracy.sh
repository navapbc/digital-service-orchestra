#!/usr/bin/env bash
# tests/scripts/test-validate-comment-accuracy.sh
# Bug dso-w20r: Comment says "do NOT use run_with_timeout" but code does use it.
# Bug dso-xhhv: Unquoted $* in RUN: line produces broken resume command.
#
# Usage: bash tests/scripts/test-validate-comment-accuracy.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

source "$REPO_ROOT/tests/lib/assert.sh"

echo "=== test-validate-comment-accuracy.sh ==="
echo ""

VALIDATE_SCRIPT="$REPO_ROOT/plugins/dso/scripts/validate.sh"

# ── Test 1: No "do NOT use run_with_timeout" comment near run_with_timeout call ─
echo "--- test_no_contradictory_run_with_timeout_comment ---"
_snapshot_fail
_has_contradiction=0
# Look for "do NOT use run_with_timeout" — this contradicts the actual code
if grep -qiF "do NOT use run_with_timeout" "$VALIDATE_SCRIPT"; then
    _has_contradiction=1
fi
assert_eq "test_no_contradictory_run_with_timeout_comment: must not say 'do NOT use run_with_timeout' when code uses it" \
    "0" "$_has_contradiction"
assert_pass_if_clean "test_no_contradictory_run_with_timeout_comment"

# ── Test 2: RUN: line uses proper quoting (not bare $*) ─────────────────────
echo ""
echo "--- test_run_line_proper_quoting ---"
_snapshot_fail
_has_unquoted=0
# Check for 'echo "RUN:...$*"' pattern which loses quoting on space-containing args
if grep -qE 'echo.*RUN:.*\$\*' "$VALIDATE_SCRIPT"; then
    _has_unquoted=1
fi
assert_eq "test_run_line_proper_quoting: RUN: line must not use unquoted \$* (use printf %q instead)" \
    "0" "$_has_unquoted"
assert_pass_if_clean "test_run_line_proper_quoting"

# ── Summary ───────────────────────────────────────────────────────────────────
print_summary
