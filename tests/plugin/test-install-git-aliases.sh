#!/usr/bin/env bash
# lockpick-workflow/tests/plugin/test-install-git-aliases.sh
# TDD tests for install-git-aliases.sh (canonical copy in lockpick-workflow/scripts/)
#
# Output format: "PASS: <test_name>" or "FAIL: <test_name>"
# Exit 0 iff FAIL==0
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
REPO_ROOT="$(cd "$PLUGIN_ROOT/.." && pwd)"
CANONICAL_SCRIPT="$PLUGIN_ROOT/scripts/install-git-aliases.sh"
WRAPPER_SCRIPT="$REPO_ROOT/scripts/install-git-aliases.sh"

PASS=0
FAIL=0

echo "=== test-install-git-aliases.sh (plugin) ==="
echo ""

# ── Test: canonical_script_exists ────────────────────────────────────────────
echo "Test: canonical_script_exists"
if [ -f "$CANONICAL_SCRIPT" ]; then
    echo "  PASS: test_canonical_script_exists"
    ((PASS++))
else
    echo "  FAIL: test_canonical_script_exists (install-git-aliases.sh not found at $CANONICAL_SCRIPT)"
    ((FAIL++))
fi

# ── Test: canonical_script_executable ────────────────────────────────────────
echo "Test: canonical_script_executable"
if [ -x "$CANONICAL_SCRIPT" ]; then
    echo "  PASS: test_canonical_script_executable"
    ((PASS++))
else
    echo "  FAIL: test_canonical_script_executable (canonical script not executable)"
    ((FAIL++))
fi

# ── Test: wrapper_exists_and_delegates ───────────────────────────────────────
echo "Test: wrapper_exists_and_delegates"
if [ -f "$WRAPPER_SCRIPT" ]; then
    if grep -q 'exec.*lockpick-workflow/scripts/install-git-aliases.sh' "$WRAPPER_SCRIPT"; then
        echo "  PASS: test_wrapper_exists_and_delegates"
        ((PASS++))
    else
        echo "  FAIL: test_wrapper_exists_and_delegates (wrapper does not exec to plugin copy)"
        ((FAIL++))
    fi
else
    echo "  FAIL: test_wrapper_exists_and_delegates (wrapper not found at $WRAPPER_SCRIPT)"
    ((FAIL++))
fi

# ── Test: syntax_ok ────────────────────────────────────────────────────────────
echo "Test: syntax_ok"
if bash -n "$CANONICAL_SCRIPT" 2>/dev/null; then
    echo "  PASS: test_syntax_ok"
    ((PASS++))
else
    echo "  FAIL: test_syntax_ok (bash -n reports syntax errors)"
    ((FAIL++))
fi

# ── Test: test_install_git_aliases_registers_revert_safe ─────────────────────
# Run the installer in a temporary git repo, then verify that
# git config alias.revert-safe returns a command referencing git-revert-safe.sh

echo "Test: test_install_git_aliases_registers_revert_safe"

TMPDIR_1=$(mktemp -d)

cd "$TMPDIR_1" || { echo "  FAIL: test_install_git_aliases_registers_revert_safe (cd failed)"; ((FAIL++)); exit 1; }
git init -q
git config user.email "test@test.com"
git config user.name "Test User"

install_output=""
install_exit=0
install_output=$(bash "$CANONICAL_SCRIPT" 2>&1) || install_exit=$?

if [ "$install_exit" -ne 0 ]; then
    echo "  FAIL: test_install_git_aliases_registers_revert_safe (installer exited $install_exit: $install_output)"
    ((FAIL++))
else
    alias_value=$(git -C "$TMPDIR_1" config --get alias.revert-safe 2>/dev/null || true)
    if echo "$alias_value" | grep -q "git-revert-safe.sh"; then
        echo "  PASS: test_install_git_aliases_registers_revert_safe"
        ((PASS++))
    else
        echo "  FAIL: test_install_git_aliases_registers_revert_safe (alias.revert-safe does not reference git-revert-safe.sh)"
        echo "  alias value: '$alias_value'"
        ((FAIL++))
    fi
fi

rm -rf "$TMPDIR_1"

# ── Test: test_install_prints_confirmation ────────────────────────────────────
# The installer should print a confirmation message listing the alias.

echo "Test: test_install_prints_confirmation"

TMPDIR_2=$(mktemp -d)

cd "$TMPDIR_2" || { echo "  FAIL: test_install_prints_confirmation (cd failed)"; ((FAIL++)); exit 1; }
git init -q
git config user.email "test@test.com"
git config user.name "Test User"

confirm_output=""
confirm_exit=0
confirm_output=$(bash "$CANONICAL_SCRIPT" 2>&1) || confirm_exit=$?

if [ "$confirm_exit" -ne 0 ]; then
    echo "  FAIL: test_install_prints_confirmation (installer exited $confirm_exit)"
    ((FAIL++))
elif echo "$confirm_output" | grep -qi "revert-safe"; then
    echo "  PASS: test_install_prints_confirmation"
    ((PASS++))
else
    echo "  FAIL: test_install_prints_confirmation (output does not mention 'revert-safe')"
    echo "  output: $confirm_output"
    ((FAIL++))
fi

rm -rf "$TMPDIR_2"

# ── Test: test_install_idempotent ─────────────────────────────────────────────
# Running the installer twice should not error; alias should still be registered.

echo "Test: test_install_idempotent"

TMPDIR_3=$(mktemp -d)

cd "$TMPDIR_3" || { echo "  FAIL: test_install_idempotent (cd failed)"; ((FAIL++)); exit 1; }
git init -q
git config user.email "test@test.com"
git config user.name "Test User"

idempotent_exit=0
bash "$CANONICAL_SCRIPT" >/dev/null 2>&1 || idempotent_exit=$?
bash "$CANONICAL_SCRIPT" >/dev/null 2>&1 || idempotent_exit=$?

alias_value=$(git -C "$TMPDIR_3" config --get alias.revert-safe 2>/dev/null || true)

if [ "$idempotent_exit" -ne 0 ]; then
    echo "  FAIL: test_install_idempotent (second run exited $idempotent_exit)"
    ((FAIL++))
elif echo "$alias_value" | grep -q "git-revert-safe.sh"; then
    echo "  PASS: test_install_idempotent"
    ((PASS++))
else
    echo "  FAIL: test_install_idempotent (alias missing after second run)"
    echo "  alias value: '$alias_value'"
    ((FAIL++))
fi

rm -rf "$TMPDIR_3"

# ── Test: test_wrapper_delegates_to_canonical ─────────────────────────────────
# Verify the wrapper at scripts/install-git-aliases.sh correctly delegates to
# the canonical copy by running through the wrapper path.
echo "Test: test_wrapper_delegates_to_canonical"

TMPDIR_4=$(mktemp -d)

cd "$TMPDIR_4" || { echo "  FAIL: test_wrapper_delegates_to_canonical (cd failed)"; ((FAIL++)); exit 1; }
git init -q
git config user.email "test@test.com"
git config user.name "Test User"

wrapper_exit=0
wrapper_output=$(bash "$WRAPPER_SCRIPT" 2>&1) || wrapper_exit=$?

if [ "$wrapper_exit" -ne 0 ]; then
    echo "  FAIL: test_wrapper_delegates_to_canonical (wrapper exited $wrapper_exit: $wrapper_output)"
    ((FAIL++))
else
    alias_value=$(git -C "$TMPDIR_4" config --get alias.revert-safe 2>/dev/null || true)
    if echo "$alias_value" | grep -q "git-revert-safe.sh"; then
        echo "  PASS: test_wrapper_delegates_to_canonical"
        ((PASS++))
    else
        echo "  FAIL: test_wrapper_delegates_to_canonical (alias not registered via wrapper)"
        echo "  alias value: '$alias_value'"
        ((FAIL++))
    fi
fi

rm -rf "$TMPDIR_4"

# ── Summary ───────────────────────────────────────────────────────────────────

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
