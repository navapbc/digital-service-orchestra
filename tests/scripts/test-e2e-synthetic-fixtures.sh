#!/usr/bin/env bash
# tests/scripts/test-e2e-synthetic-fixtures.sh
# End-to-end tests for synthetic scope-drift and intent-conflict fixtures.
#
# Validates that fixture directories contain the expected files and that
# fixture content matches the scope-drift / intent-conflict scenarios.
#
# Usage: bash tests/scripts/test-e2e-synthetic-fixtures.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
FIXTURE_BASE="$REPO_ROOT/tests/fixtures/scope-drift-detection"

source "$REPO_ROOT/tests/lib/assert.sh"

echo "=== test-e2e-synthetic-fixtures.sh ==="

# ── Section 1: test_fixture_a_exists ─────────────────────────────────────────
test_fixture_a_exists() {
    local ticket="$FIXTURE_BASE/fixture-a/ticket.md"
    local patch="$FIXTURE_BASE/fixture-a/diff.patch"

    if [[ -f "$ticket" ]]; then
        assert_eq "fixture-a/ticket.md exists" "yes" "yes"
    else
        assert_eq "fixture-a/ticket.md exists" "yes" "no"
    fi

    if [[ -f "$patch" ]]; then
        assert_eq "fixture-a/diff.patch exists" "yes" "yes"
    else
        assert_eq "fixture-a/diff.patch exists" "yes" "no"
    fi
}

# ── Section 2: test_fixture_a_has_undocumented_return_change ─────────────────
test_fixture_a_has_undocumented_return_change() {
    local ticket="$FIXTURE_BASE/fixture-a/ticket.md"
    local patch="$FIXTURE_BASE/fixture-a/diff.patch"

    # diff.patch must contain a '+return' line (return value change)
    if grep -q '^+.*return' "$patch" 2>/dev/null; then
        assert_eq "fixture-a/diff.patch has +return line" "yes" "yes"
    else
        assert_eq "fixture-a/diff.patch has +return line" "yes" "no"
    fi

    # ticket.md must NOT mention "return" (scope drift: undocumented)
    if grep -qi 'return' "$ticket" 2>/dev/null; then
        assert_eq "fixture-a/ticket.md does not mention return" "yes" "no"
    else
        assert_eq "fixture-a/ticket.md does not mention return" "yes" "yes"
    fi
}

# ── Section 3: test_fixture_b_exists ─────────────────────────────────────────
test_fixture_b_exists() {
    local ticket="$FIXTURE_BASE/fixture-b/ticket.md"
    local callers="$FIXTURE_BASE/fixture-b/callers.txt"

    if [[ -f "$ticket" ]]; then
        assert_eq "fixture-b/ticket.md exists" "yes" "yes"
    else
        assert_eq "fixture-b/ticket.md exists" "yes" "no"
    fi

    if [[ -f "$callers" ]]; then
        assert_eq "fixture-b/callers.txt exists" "yes" "yes"
    else
        assert_eq "fixture-b/callers.txt exists" "yes" "no"
    fi
}

# ── Section 4: test_fixture_b_has_three_callers ──────────────────────────────
test_fixture_b_has_three_callers() {
    local callers="$FIXTURE_BASE/fixture-b/callers.txt"

    local none_count=0
    none_count=$(grep -c -E 'None|null' "$callers" 2>/dev/null) || true
    if [[ "$none_count" -ge 3 ]]; then
        assert_eq "fixture-b/callers.txt has 3+ None/null refs" "yes" "yes"
    else
        assert_eq "fixture-b/callers.txt has 3+ None/null refs" "yes" "no (found $none_count)"
    fi
}

# ── Section 5: test_fixture_c_exists ─────────────────────────────────────────
test_fixture_c_exists() {
    local ticket="$FIXTURE_BASE/fixture-c/ticket.md"
    local patch="$FIXTURE_BASE/fixture-c/diff.patch"
    local investigated="$FIXTURE_BASE/fixture-c/investigated-files.txt"

    if [[ -f "$ticket" ]]; then
        assert_eq "fixture-c/ticket.md exists" "yes" "yes"
    else
        assert_eq "fixture-c/ticket.md exists" "yes" "no"
    fi

    if [[ -f "$patch" ]]; then
        assert_eq "fixture-c/diff.patch exists" "yes" "yes"
    else
        assert_eq "fixture-c/diff.patch exists" "yes" "no"
    fi

    if [[ -f "$investigated" ]]; then
        assert_eq "fixture-c/investigated-files.txt exists" "yes" "yes"
    else
        assert_eq "fixture-c/investigated-files.txt exists" "yes" "no"
    fi
}

# ── Section 6: test_fixture_c_diff_within_investigated_files ─────────────────
test_fixture_c_diff_within_investigated_files() {
    local patch="$FIXTURE_BASE/fixture-c/diff.patch"
    local investigated="$FIXTURE_BASE/fixture-c/investigated-files.txt"

    # Extract files changed in diff.patch (lines starting with +++ b/ or --- a/)
    local diff_files
    diff_files=$(grep '^+++ b/' "$patch" 2>/dev/null | sed 's|^+++ b/||' | sort -u)

    if [[ -z "$diff_files" ]]; then
        assert_eq "fixture-c/diff.patch has changed files" "yes" "no"
        return
    fi

    local all_covered="yes"
    while IFS= read -r file; do
        if ! grep -qF "$file" "$investigated" 2>/dev/null; then
            all_covered="no"
            printf "  missing from investigated-files.txt: %s\n" "$file" >&2
        fi
    done <<< "$diff_files"

    assert_eq "fixture-c diff files all in investigated-files.txt" "yes" "$all_covered"
}

# ── Run all tests ────────────────────────────────────────────────────────────
test_fixture_a_exists
test_fixture_a_has_undocumented_return_change
test_fixture_b_exists
test_fixture_b_has_three_callers
test_fixture_c_exists
test_fixture_c_diff_within_investigated_files

print_summary
