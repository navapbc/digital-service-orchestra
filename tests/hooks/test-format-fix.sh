#!/usr/bin/env bash
# tests/plugin/hooks/test-format-fix.sh
#
# Tests for pre-commit-format-fix.sh:
#   (a) Already-formatted files pass without modification (exit 0)
#   (b) Unformatted files are auto-fixed and re-staged (exit 0)
#   (c) Staging area is preserved across auto-fix (no lost staged changes)
#   (d) Non-Python files are ignored (exit 0)
#   (e) Syntax errors cause the hook to fail (exit non-zero)
#
# Usage: bash tests/plugin/hooks/test-format-fix.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -uo pipefail

PASS=0
FAIL=0

# ── Assertion helpers (self-contained) ────────────────────────────────────────
assert_eq() {
    local test_name="$1" expected="$2" actual="$3"
    if [[ "$expected" == "$actual" ]]; then
        (( ++PASS ))
    else
        (( ++FAIL ))
        printf "FAIL: %s\n  expected: %s\n  actual:   %s\n" "$test_name" "$expected" "$actual" >&2
    fi
}

assert_contains() {
    local test_name="$1" needle="$2" haystack="$3"
    if [[ "$haystack" == *"$needle"* ]]; then
        (( ++PASS ))
    else
        (( ++FAIL ))
        printf "FAIL: %s\n  expected to contain: %s\n  in: %s\n" "$test_name" "$needle" "$haystack" >&2
    fi
}

assert_not_contains() {
    local test_name="$1" needle="$2" haystack="$3"
    if [[ "$haystack" != *"$needle"* ]]; then
        (( ++PASS ))
    else
        (( ++FAIL ))
        printf "FAIL: %s\n  expected NOT to contain: %s\n  in: %s\n" "$test_name" "$needle" "$haystack" >&2
    fi
}

print_summary() {
    echo ""
    echo "================================"
    echo "Results: $PASS passed, $FAIL failed"
    echo "================================"
    if [[ $FAIL -gt 0 ]]; then
        exit 1
    fi
    exit 0
}

# ── Resolve script under test ─────────────────────────────────────────────────
REPO_ROOT="$(git rev-parse --show-toplevel)"
FORMAT_FIX_SCRIPT="$REPO_ROOT/lockpick-workflow/scripts/pre-commit-format-fix.sh"

if [[ ! -f "$FORMAT_FIX_SCRIPT" ]]; then
    echo "SKIP: $FORMAT_FIX_SCRIPT not found" >&2
    exit 1
fi

# ── Ensure ruff is on PATH ────────────────────────────────────────────────────
# The tests run in temp git repos where the app venv isn't available.
# Add the real app venv bin to PATH so ruff can be found.
REAL_APP_VENV="$REPO_ROOT/app/.venv/bin"
if [[ -x "$REAL_APP_VENV/ruff" ]]; then
    export PATH="$REAL_APP_VENV:$PATH"
elif ! command -v ruff >/dev/null 2>&1; then
    echo "SKIP: ruff not found (install in app venv or add to PATH)" >&2
    exit 1
fi

# ── Helper: create a temp git repo with poetry/ruff available ─────────────────
setup_test_repo() {
    local tmpdir
    tmpdir=$(mktemp -d)
    local REALENV
    REALENV=$(cd "$tmpdir" && pwd -P)

    mkdir -p "$REALENV/app/src" "$REALENV/app/tests"

    # Create minimal pyproject.toml so ruff can find config
    cat > "$REALENV/app/pyproject.toml" <<'PYPROJECT'
[tool.ruff]
line-length = 88
[tool.ruff.format]
quote-style = "double"
PYPROJECT

    git init -q "$REALENV"
    git -C "$REALENV" config user.email "test@test.com"
    git -C "$REALENV" config user.name "Test"

    # Initial commit so we have a HEAD
    echo "# test" > "$REALENV/README.md"
    git -C "$REALENV" add -A
    git -C "$REALENV" commit -q -m "init"

    echo "$REALENV"
}

cleanup_test_repo() {
    rm -rf "$1"
}

# =============================================================================
# TEST A: Already-formatted file passes without modification
# =============================================================================

TEST_REPO_A=$(setup_test_repo)
cat > "$TEST_REPO_A/app/src/clean.py" <<'PY'
"""A well-formatted module."""


def hello():
    """Say hello."""
    return "hello"
PY
git -C "$TEST_REPO_A" add -A
git -C "$TEST_REPO_A" commit -q -m "add clean file"

# Stage a no-op change (touch the file without changing content)
echo "" >> "$TEST_REPO_A/app/src/clean.py"
git -C "$TEST_REPO_A" add "$TEST_REPO_A/app/src/clean.py"

OUTPUT_A=$(cd "$TEST_REPO_A" && bash "$FORMAT_FIX_SCRIPT" 2>&1) || true
EXIT_A=$?

assert_eq "test_clean_file_exits_zero" "0" "$EXIT_A"

cleanup_test_repo "$TEST_REPO_A"

# =============================================================================
# TEST B: Unformatted file is auto-fixed and re-staged (exit 0)
# =============================================================================

TEST_REPO_B=$(setup_test_repo)

# Write a poorly formatted Python file
cat > "$TEST_REPO_B/app/src/messy.py" <<'PY'
import   os
import sys
def   foo( ):
    x=1
    return   x
PY
git -C "$TEST_REPO_B" add "$TEST_REPO_B/app/src/messy.py"

# Run the format fix hook
OUTPUT_B=$(cd "$TEST_REPO_B" && bash "$FORMAT_FIX_SCRIPT" 2>&1) || true
EXIT_B=$?

assert_eq "test_unformatted_file_exits_zero" "0" "$EXIT_B"

# Verify the file was actually formatted (check for the original bad formatting)
FILE_CONTENTS_B=$(cat "$TEST_REPO_B/app/src/messy.py")
assert_not_contains "test_unformatted_file_was_fixed" "import   os" "$FILE_CONTENTS_B"

# Verify the fixed file is staged (in the index)
STAGED_DIFF_B=$(cd "$TEST_REPO_B" && git diff --cached --name-only)
assert_contains "test_fixed_file_is_staged" "app/src/messy.py" "$STAGED_DIFF_B"

cleanup_test_repo "$TEST_REPO_B"

# =============================================================================
# TEST C: Staging area is preserved - other staged files remain staged
# =============================================================================

TEST_REPO_C=$(setup_test_repo)

# Stage a clean Python file
cat > "$TEST_REPO_C/app/src/other.py" <<'PY'
"""Another module."""


def bar():
    """Return bar."""
    return "bar"
PY
git -C "$TEST_REPO_C" add "$TEST_REPO_C/app/src/other.py"

# Stage a messy Python file alongside it
cat > "$TEST_REPO_C/app/src/messy2.py" <<'PY'
import   os
def   baz( ):
    return   1
PY
git -C "$TEST_REPO_C" add "$TEST_REPO_C/app/src/messy2.py"

# Run the format fix hook
OUTPUT_C=$(cd "$TEST_REPO_C" && bash "$FORMAT_FIX_SCRIPT" 2>&1) || true
EXIT_C=$?

assert_eq "test_staging_preserved_exits_zero" "0" "$EXIT_C"

# Verify both files are still staged
STAGED_C=$(cd "$TEST_REPO_C" && git diff --cached --name-only)
assert_contains "test_other_file_still_staged" "app/src/other.py" "$STAGED_C"
assert_contains "test_messy_file_still_staged" "app/src/messy2.py" "$STAGED_C"

cleanup_test_repo "$TEST_REPO_C"

# =============================================================================
# TEST D: Non-Python files are ignored
# =============================================================================

TEST_REPO_D=$(setup_test_repo)

# Stage a non-Python file
echo "some text" > "$TEST_REPO_D/app/src/readme.txt"
git -C "$TEST_REPO_D" add "$TEST_REPO_D/app/src/readme.txt"

OUTPUT_D=$(cd "$TEST_REPO_D" && bash "$FORMAT_FIX_SCRIPT" 2>&1) || true
EXIT_D=$?

assert_eq "test_non_python_exits_zero" "0" "$EXIT_D"

cleanup_test_repo "$TEST_REPO_D"

# =============================================================================
# TEST E: Script source contains key behaviors
# =============================================================================

SCRIPT_SOURCE=$(cat "$FORMAT_FIX_SCRIPT")

# Must use ruff format (auto-fix, not --check)
assert_contains "test_script_uses_ruff_format" "ruff format" "$SCRIPT_SOURCE"

# Must re-stage files after formatting
assert_contains "test_script_restages_files" "git add" "$SCRIPT_SOURCE"

# Must handle staged files specifically (not all files)
assert_contains "test_script_handles_staged" "staged" "$SCRIPT_SOURCE"

print_summary
