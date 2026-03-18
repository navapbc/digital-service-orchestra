#!/usr/bin/env bash
# tests/hooks/test-review-gate-self-healing.sh
# Tests for the review gate self-healing logic for formatting-only hash mismatches.
#
# When the only difference between the review-time diff and the current diff
# is whitespace/formatting changes (e.g., ruff format ran), the gate should
# auto-heal by updating the hash instead of blocking.
#
# Tests:
#   test_is_formatting_only_change_identical_diffs
#   test_is_formatting_only_change_whitespace_only
#   test_is_formatting_only_change_blank_lines_only
#   test_is_formatting_only_change_mixed_whitespace
#   test_is_formatting_only_change_code_change_not_healed
#   test_is_formatting_only_change_added_line_not_healed
#   test_is_formatting_only_change_removed_line_not_healed

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DSO_PLUGIN_DIR="$PLUGIN_ROOT/plugins/dso"
REPO_ROOT="$(git rev-parse --show-toplevel)"
export CLAUDE_PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT}"

source "$PLUGIN_ROOT/tests/lib/assert.sh"
source "$DSO_PLUGIN_DIR/hooks/lib/deps.sh"
source "$DSO_PLUGIN_DIR/hooks/lib/pre-bash-functions.sh"

# ---------------------------------------------------------------------------
# Unit tests for is_formatting_only_change()
# ---------------------------------------------------------------------------

# test_is_formatting_only_change_identical_diffs
# Identical diffs should be considered formatting-only (returns 0)
echo "--- test_is_formatting_only_change_identical_diffs ---"
OLD_DIFF="-foo(x,y)+foo(x, y)"
NEW_DIFF="-foo(x,y)+foo(x, y)"
EXIT_CODE=0
is_formatting_only_change "$OLD_DIFF" "$NEW_DIFF" 2>/dev/null || EXIT_CODE=$?
assert_eq "test_is_formatting_only_change_identical_diffs" "0" "$EXIT_CODE"

# test_is_formatting_only_change_whitespace_only
# Diffs that differ only in trailing whitespace should be formatting-only (returns 0)
echo "--- test_is_formatting_only_change_whitespace_only ---"
OLD_DIFF="$(printf -- '-foo(x,y)  \n+foo(x, y)  ')"
NEW_DIFF="$(printf -- '-foo(x,y)\n+foo(x, y)')"
EXIT_CODE=0
is_formatting_only_change "$OLD_DIFF" "$NEW_DIFF" 2>/dev/null || EXIT_CODE=$?
assert_eq "test_is_formatting_only_change_whitespace_only" "0" "$EXIT_CODE"

# test_is_formatting_only_change_blank_lines_only
# Diffs that differ only by blank lines should be formatting-only (returns 0)
echo "--- test_is_formatting_only_change_blank_lines_only ---"
OLD_DIFF="$(printf -- '-foo(x)\n\n+bar(x)')"
NEW_DIFF="$(printf -- '-foo(x)\n+bar(x)')"
EXIT_CODE=0
is_formatting_only_change "$OLD_DIFF" "$NEW_DIFF" 2>/dev/null || EXIT_CODE=$?
assert_eq "test_is_formatting_only_change_blank_lines_only" "0" "$EXIT_CODE"

# test_is_formatting_only_change_mixed_whitespace
# Diffs that differ in trailing spaces and blank lines should be formatting-only (returns 0)
echo "--- test_is_formatting_only_change_mixed_whitespace ---"
OLD_DIFF="$(printf -- '-def foo():  \n\n+def foo():  \n    pass  ')"
NEW_DIFF="$(printf -- '-def foo():\n+def foo():\n    pass')"
EXIT_CODE=0
is_formatting_only_change "$OLD_DIFF" "$NEW_DIFF" 2>/dev/null || EXIT_CODE=$?
assert_eq "test_is_formatting_only_change_mixed_whitespace" "0" "$EXIT_CODE"

# test_is_formatting_only_change_code_change_not_healed
# Diffs that differ in actual code content should NOT be formatting-only (returns 1)
echo "--- test_is_formatting_only_change_code_change_not_healed ---"
OLD_DIFF="$(printf -- '-def foo():\n+def foo():\n     return 1')"
NEW_DIFF="$(printf -- '-def foo():\n+def foo():\n     return 2')"
EXIT_CODE=0
is_formatting_only_change "$OLD_DIFF" "$NEW_DIFF" 2>/dev/null || EXIT_CODE=$?
assert_eq "test_is_formatting_only_change_code_change_not_healed" "1" "$EXIT_CODE"

# test_is_formatting_only_change_added_line_not_healed
# New diff has an extra line that wasn't in the old diff → NOT formatting-only (returns 1)
echo "--- test_is_formatting_only_change_added_line_not_healed ---"
OLD_DIFF="$(printf -- '-foo(x)\n+foo(x, y)')"
NEW_DIFF="$(printf -- '-foo(x)\n+foo(x, y)\n+bar(z)')"
EXIT_CODE=0
is_formatting_only_change "$OLD_DIFF" "$NEW_DIFF" 2>/dev/null || EXIT_CODE=$?
assert_eq "test_is_formatting_only_change_added_line_not_healed" "1" "$EXIT_CODE"

# test_is_formatting_only_change_removed_line_not_healed
# New diff is missing a line from the old diff → NOT formatting-only (returns 1)
echo "--- test_is_formatting_only_change_removed_line_not_healed ---"
OLD_DIFF="$(printf -- '-foo(x)\n+foo(x, y)\n+bar(z)')"
NEW_DIFF="$(printf -- '-foo(x)\n+foo(x, y)')"
EXIT_CODE=0
is_formatting_only_change "$OLD_DIFF" "$NEW_DIFF" 2>/dev/null || EXIT_CODE=$?
assert_eq "test_is_formatting_only_change_removed_line_not_healed" "1" "$EXIT_CODE"

# test_is_formatting_only_change_function_exists
# Verify that is_formatting_only_change is defined after sourcing pre-bash-functions.sh
echo "--- test_is_formatting_only_change_function_exists ---"
FUNC_EXISTS=0
declare -f is_formatting_only_change >/dev/null 2>&1 && FUNC_EXISTS=1
assert_eq "test_is_formatting_only_change_function_exists" "1" "$FUNC_EXISTS"

print_summary
