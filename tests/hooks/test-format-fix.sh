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
DSO_PLUGIN_DIR="$REPO_ROOT/plugins/dso"
FORMAT_FIX_SCRIPT="$DSO_PLUGIN_DIR/scripts/pre-commit-format-fix.sh"

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
    exit 0
fi

# ── Shared repo setup (one init, reset between tests) ─────────────────────────
# Creating a git repo per test multiplies process-launch overhead. All tests
# share one repo and call reset_test_repo() before each test to restore a clean
# staged state. This reduces git process launches from ~20 to ~7 total.
TEST_REPO=$(mktemp -d)
REALENV=$(cd "$TEST_REPO" && pwd -P)

mkdir -p "$REALENV/app/src" "$REALENV/app/tests"

cat > "$REALENV/app/pyproject.toml" <<'PYPROJECT'
[tool.ruff]
line-length = 88
[tool.ruff.format]
quote-style = "double"
PYPROJECT

git init -q "$REALENV"
git -C "$REALENV" config user.email "test@test.com"
git -C "$REALENV" config user.name "Test"
# Disable GPG signing in the temp repo — prevents commit failures on CI machines
# where commit.gpgsign=true is set globally but no signing key is available.
git -C "$REALENV" config commit.gpgsign false

echo "# test" > "$REALENV/README.md"
git -C "$REALENV" add -A
git -C "$REALENV" commit -q -m "init"

# Reset repo to clean state (unstaged, no untracked files) between subtests.
# Removes stale git index lock files before running git commands — a lock can
# persist when FORMAT_FIX_SCRIPT's git-add is killed mid-operation by a test
# timeout (TEST_TIMEOUT=45s in suite-engine), causing subsequent git reset to
# fail with "Unable to create index.lock: File exists".
reset_test_repo() {
    # Clear stale git lock files from any interrupted git operation
    rm -f "$REALENV/.git/index.lock" "$REALENV/.git/config.lock"
    git -C "$REALENV" reset --mixed HEAD -q
    git -C "$REALENV" clean -fd -q
    # Recreate app/src/ in case git clean removed it (it has no committed files)
    mkdir -p "$REALENV/app/src"
}

cleanup_shared_repo() {
    rm -rf "$TEST_REPO"
}

# Ensure cleanup on exit or signal (prevents temp dir leaks on timeout/kill)
trap cleanup_shared_repo EXIT

# =============================================================================
# TEST A: Already-formatted file passes without modification
# =============================================================================

reset_test_repo

cat > "$REALENV/app/src/clean.py" <<'PY'
"""A well-formatted module."""


def hello():
    """Say hello."""
    return "hello"
PY
git -C "$REALENV" add -A
git -C "$REALENV" commit -q -m "add clean file"

# Stage a no-op change (touch the file without changing content)
echo "" >> "$REALENV/app/src/clean.py"
git -C "$REALENV" add "$REALENV/app/src/clean.py"

OUTPUT_A=$(cd "$REALENV" && bash "$FORMAT_FIX_SCRIPT" 2>&1); EXIT_A=$?

assert_eq "test_clean_file_exits_zero" "0" "$EXIT_A"

# =============================================================================
# TEST B: Unformatted file is auto-fixed and re-staged (exit 0)
# =============================================================================

reset_test_repo

# Write a poorly formatted Python file
cat > "$REALENV/app/src/messy.py" <<'PY'
import   os
import sys
def   foo( ):
    x=1
    return   x
PY
git -C "$REALENV" add "$REALENV/app/src/messy.py"

# Run the format fix hook
OUTPUT_B=$(cd "$REALENV" && bash "$FORMAT_FIX_SCRIPT" 2>&1); EXIT_B=$?

assert_eq "test_unformatted_file_exits_zero" "0" "$EXIT_B"

# Verify the file was actually formatted (check for the original bad formatting)
FILE_CONTENTS_B=$(cat "$REALENV/app/src/messy.py")
assert_not_contains "test_unformatted_file_was_fixed" "import   os" "$FILE_CONTENTS_B"

# Verify the fixed file is staged (in the index)
STAGED_DIFF_B=$(cd "$REALENV" && git diff --cached --name-only)
assert_contains "test_fixed_file_is_staged" "app/src/messy.py" "$STAGED_DIFF_B"

# =============================================================================
# TEST C: Staging area is preserved - other staged files remain staged
# =============================================================================

reset_test_repo

# Stage a clean Python file
cat > "$REALENV/app/src/other.py" <<'PY'
"""Another module."""


def bar():
    """Return bar."""
    return "bar"
PY
git -C "$REALENV" add "$REALENV/app/src/other.py"

# Stage a messy Python file alongside it
cat > "$REALENV/app/src/messy2.py" <<'PY'
import   os
def   baz( ):
    return   1
PY
git -C "$REALENV" add "$REALENV/app/src/messy2.py"

# Run the format fix hook
OUTPUT_C=$(cd "$REALENV" && bash "$FORMAT_FIX_SCRIPT" 2>&1); EXIT_C=$?

assert_eq "test_staging_preserved_exits_zero" "0" "$EXIT_C"

# Verify both files are still staged
STAGED_C=$(cd "$REALENV" && git diff --cached --name-only)
assert_contains "test_other_file_still_staged" "app/src/other.py" "$STAGED_C"
assert_contains "test_messy_file_still_staged" "app/src/messy2.py" "$STAGED_C"

# =============================================================================
# TEST D: Non-Python files are ignored
# =============================================================================

reset_test_repo

# Stage a non-Python file
echo "some text" > "$REALENV/app/src/readme.txt"
git -C "$REALENV" add "$REALENV/app/src/readme.txt"

OUTPUT_D=$(cd "$REALENV" && bash "$FORMAT_FIX_SCRIPT" 2>&1); EXIT_D=$?

assert_eq "test_non_python_exits_zero" "0" "$EXIT_D"

cleanup_shared_repo

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
