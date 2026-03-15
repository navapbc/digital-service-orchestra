#!/usr/bin/env bash
# lockpick-workflow/tests/hooks/test-review-gate-self-healing.sh
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
#   test_review_gate_self_heals_formatting_only_mismatch
#   test_review_gate_does_not_self_heal_substantive_mismatch

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git rev-parse --show-toplevel)"
export CLAUDE_PLUGIN_ROOT="$REPO_ROOT/lockpick-workflow"

source "$REPO_ROOT/lockpick-workflow/tests/lib/assert.sh"
source "$REPO_ROOT/lockpick-workflow/hooks/lib/deps.sh"
source "$REPO_ROOT/lockpick-workflow/hooks/lib/pre-bash-functions.sh"

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

# ---------------------------------------------------------------------------
# Integration tests for hook_review_gate self-healing
# ---------------------------------------------------------------------------

# Helper: run hook_review_gate in a temp git repo with a stale-hash review-status
# that was caused only by formatting changes vs. substantive changes.
# Args: scenario — "formatting" or "substantive"
# Returns the exit code of hook_review_gate.
_run_self_healing_test() {
    local scenario="$1"

    local tmpdir
    tmpdir=$(mktemp -d)

    (
        cd "$tmpdir"
        git init -q
        git config user.email "test@test.com"
        git config user.name "Test"
        git config commit.gpgsign false

        # Create initial committed file
        printf 'def foo(x, y):\n    return x + y\n' > src_file.py
        git add src_file.py
        git commit -q -m "init"

        # Set up artifacts dir
        local ARTIFACTS_DIR
        ARTIFACTS_DIR="$tmpdir/.artifacts"
        mkdir -p "$ARTIFACTS_DIR"
        export ARTIFACTS_DIR
        export WORKFLOW_PLUGIN_ARTIFACTS_DIR="$ARTIFACTS_DIR"

        if [[ "$scenario" == "formatting" ]]; then
            # Simulate: reviewed with trailing whitespace, then formatter cleaned it up.
            # Step 1: Make change with trailing whitespace (review-time state)
            printf 'def foo(x, y):\n    return x+y  \n' > src_file.py

            # Compute review-time hash and save diff
            local REVIEW_HASH
            REVIEW_HASH=$("$CLAUDE_PLUGIN_ROOT/hooks/compute-diff-hash.sh" 2>/dev/null || echo "deadbeef")
            git diff HEAD -- > "$ARTIFACTS_DIR/review-diff.txt" 2>/dev/null

            printf 'passed\nscore=9\ndiff_hash=%s\ntimestamp=2026-03-15T10:00:00Z\n' "$REVIEW_HASH" \
                > "$ARTIFACTS_DIR/review-status"

            # Step 2: Formatter strips trailing whitespace (same logic, different whitespace)
            printf 'def foo(x, y):\n    return x+y\n' > src_file.py
        else
            # Make a working tree change (the "reviewed" state)
            printf 'def foo(x, y):\n    return x+y\n' > src_file.py

            # Compute review-time hash and save diff
            local REVIEW_HASH
            REVIEW_HASH=$("$CLAUDE_PLUGIN_ROOT/hooks/compute-diff-hash.sh" 2>/dev/null || echo "deadbeef")
            git diff HEAD -- > "$ARTIFACTS_DIR/review-diff.txt" 2>/dev/null

            printf 'passed\nscore=9\ndiff_hash=%s\ntimestamp=2026-03-15T10:00:00Z\n' "$REVIEW_HASH" \
                > "$ARTIFACTS_DIR/review-status"

            # Simulate substantive change: actual logic changed
            printf 'def foo(x, y):\n    return x * y\n' > src_file.py
        fi

        # Source the functions in subshell (reset load guard for clean subshell)
        _DEPS_LOADED=""
        _PRE_BASH_FUNCTIONS_LOADED=""
        source "$REPO_ROOT/lockpick-workflow/hooks/lib/deps.sh"
        source "$REPO_ROOT/lockpick-workflow/hooks/lib/pre-bash-functions.sh"

        local INPUT
        INPUT='{"tool_name":"Bash","tool_input":{"command":"git commit -m \"feat: update foo\""}}'
        local exit_code=0
        hook_review_gate "$INPUT" 2>/dev/null || exit_code=$?
        exit "$exit_code"
    )
    local result=$?
    rm -rf "$tmpdir"
    return $result
}

# test_review_gate_self_heals_formatting_only_mismatch
# When hash mismatch is caused only by formatting, the gate should auto-heal and allow (exit 0).
echo "--- test_review_gate_self_heals_formatting_only_mismatch ---"
EXIT_CODE=0
_run_self_healing_test "formatting" || EXIT_CODE=$?
assert_eq "test_review_gate_self_heals_formatting_only_mismatch" "0" "$EXIT_CODE"

# test_review_gate_does_not_self_heal_substantive_mismatch
# When hash mismatch is caused by substantive code changes, the gate should block (exit 2).
echo "--- test_review_gate_does_not_self_heal_substantive_mismatch ---"
EXIT_CODE=0
_run_self_healing_test "substantive" || EXIT_CODE=$?
assert_eq "test_review_gate_does_not_self_heal_substantive_mismatch" "2" "$EXIT_CODE"

# test_is_formatting_only_change_function_exists
# Verify that is_formatting_only_change is defined after sourcing pre-bash-functions.sh
echo "--- test_is_formatting_only_change_function_exists ---"
FUNC_EXISTS=0
declare -f is_formatting_only_change >/dev/null 2>&1 && FUNC_EXISTS=1
assert_eq "test_is_formatting_only_change_function_exists" "1" "$FUNC_EXISTS"

print_summary
