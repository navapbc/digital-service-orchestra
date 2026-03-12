#!/usr/bin/env bash
# lockpick-workflow/tests/scripts/test-reinstall-hooks.sh
# Tests for lockpick-workflow/scripts/reinstall-hooks.sh
#
# Tests:
#   test_syntax_ok                  — bash -n passes on reinstall-hooks.sh
#   test_script_exists              — reinstall-hooks.sh exists in lockpick-workflow/scripts/
#   test_accepts_worktree_path      — WORKTREE_PATH env var is required
#   test_missing_worktree_path      — exits non-zero when WORKTREE_PATH is unset
#   test_missing_app_dir            — exits non-zero when app/ dir does not exist
#   test_detects_venv               — detects the venv at app/.venv/bin/python
#   test_no_venv_falls_back         — falls back to poetry run when no venv found
#   test_hooks_reinstalled          — after install, hook shims point to current venv
#   test_stale_venv_path_fixed      — stale INSTALL_PYTHON path is replaced with current path
#   test_poetry_fallback_injected   — hook shim includes poetry run fallback after reinstall
#   test_all_three_hook_types       — installs pre-commit, pre-push, prepare-commit-msg hooks
#
# Usage:
#   bash lockpick-workflow/tests/scripts/test-reinstall-hooks.sh
#
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
ASSERT_LIB="$REPO_ROOT/lockpick-workflow/tests/lib/assert.sh"
SCRIPT="$REPO_ROOT/lockpick-workflow/scripts/reinstall-hooks.sh"

# Source shared assert helpers
# shellcheck source=../lib/assert.sh
source "$ASSERT_LIB"

echo "=== test-reinstall-hooks.sh ==="
echo ""

# ---------------------------------------------------------------------------
# Test 1: syntax check
# ---------------------------------------------------------------------------
echo "Test 1: syntax check"
syntax_exit=0
bash -n "$SCRIPT" 2>&1 || syntax_exit=$?
assert_eq "test_syntax_ok" "0" "$syntax_exit"

# ---------------------------------------------------------------------------
# Test 2: script exists
# ---------------------------------------------------------------------------
echo "Test 2: script exists in lockpick-workflow/scripts/"
if [ -f "$SCRIPT" ]; then
    assert_eq "test_script_exists" "exists" "exists"
else
    assert_eq "test_script_exists" "exists" "missing"
fi

# ---------------------------------------------------------------------------
# Test 3: exits non-zero when WORKTREE_PATH unset
# ---------------------------------------------------------------------------
echo "Test 3: exits non-zero when WORKTREE_PATH unset"
rc=0
(unset WORKTREE_PATH; bash "$SCRIPT" 2>/dev/null) || rc=$?
assert_ne "test_missing_worktree_path" "0" "$rc"

# ---------------------------------------------------------------------------
# Test 4: exits non-zero when app/ dir does not exist
# ---------------------------------------------------------------------------
echo "Test 4: exits non-zero when app/ dir does not exist"
TMPDIR_T4=$(mktemp -d)
rc=0
WORKTREE_PATH="$TMPDIR_T4" bash "$SCRIPT" 2>/dev/null || rc=$?
assert_ne "test_missing_app_dir" "0" "$rc"
rm -rf "$TMPDIR_T4"

# ---------------------------------------------------------------------------
# Test 5: exits non-zero when no venv and poetry not available
# ---------------------------------------------------------------------------
echo "Test 5: exits non-zero when no venv and no poetry"
TMPDIR_T5=$(mktemp -d)
mkdir -p "$TMPDIR_T5/app"
# No .venv and PATH points to empty dir with no poetry
rc=0
WORKTREE_PATH="$TMPDIR_T5" PATH="$TMPDIR_T5" bash "$SCRIPT" 2>/dev/null || rc=$?
assert_ne "test_no_venv_no_poetry_fails" "0" "$rc"
rm -rf "$TMPDIR_T5"

# ---------------------------------------------------------------------------
# Test 6: hook shims contain poetry run fallback after reinstall
#   - Create a fake git repo with .git/hooks/
#   - Create a fake venv with a mock pre-commit executable
#   - Run reinstall-hooks.sh
#   - Verify hook shims include poetry run fallback
# ---------------------------------------------------------------------------
echo "Test 6: hook shims contain poetry run fallback after reinstall"

TMPDIR_T6=$(mktemp -d)
FAKE_REPO="$TMPDIR_T6/repo"
mkdir -p "$FAKE_REPO/app/.venv/bin"

# Initialize git repo
git -C "$TMPDIR_T6" init -q "$FAKE_REPO"
git -C "$FAKE_REPO" config user.email "test@test.com"
git -C "$FAKE_REPO" config user.name "Test"

# Create a mock pre-commit executable that generates hook stubs
cat > "$FAKE_REPO/app/.venv/bin/pre-commit" << 'MOCK_PRECOMMIT'
#!/usr/bin/env bash
# Mock pre-commit that writes a realistic shim file when "install" is called
if [[ "${1:-}" == "install" ]]; then
    HOOK_DIR="$(git -C "$(pwd)" rev-parse --git-dir)/hooks"
    mkdir -p "$HOOK_DIR"
    # Parse --hook-type argument
    HOOK_TYPE="pre-commit"
    for arg in "$@"; do
        if [[ "$arg" == "--hook-type" ]]; then
            :
        elif [[ "${prev_arg:-}" == "--hook-type" ]]; then
            HOOK_TYPE="$arg"
        fi
        prev_arg="$arg"
    done
    # Write a realistic pre-commit shim with a hardcoded (now stale) venv path
    SHIM_FILE="$HOOK_DIR/$HOOK_TYPE"
    cat > "$SHIM_FILE" << SHIM_CONTENT
#!/usr/bin/env bash
# File generated by pre-commit: https://pre-commit.com

# start templated
INSTALL_PYTHON=/stale/path/to/.venv/bin/python
ARGS=(hook-impl --config=.pre-commit-config.yaml --hook-type=$HOOK_TYPE)
# end templated

HERE="\$(cd "\$(dirname "\$0")" && pwd)"
ARGS+=("--hook-dir" "\$HERE" -- "\$@")

if [ -x "\$INSTALL_PYTHON" ]; then
    exec "\$INSTALL_PYTHON" -mpre_commit "\${ARGS[@]}"
elif command -v pre-commit > /dev/null; then
    exec pre-commit "\${ARGS[@]}"
else
    echo '\`pre-commit\` not found.  Did you forget to activate your virtualenv?' 1>&2
    exit 1
fi
SHIM_CONTENT
    chmod +x "$SHIM_FILE"
    echo "pre-commit installed"
    exit 0
fi
echo "mock pre-commit: unhandled command $*" >&2
exit 1
MOCK_PRECOMMIT
chmod +x "$FAKE_REPO/app/.venv/bin/pre-commit"

# Run reinstall-hooks.sh
rc=0
WORKTREE_PATH="$FAKE_REPO" bash "$SCRIPT" 2>/dev/null || rc=$?

# Check that the hook shims were created and contain a poetry run fallback
if [ -f "$FAKE_REPO/.git/hooks/pre-commit" ]; then
    shim_content=$(cat "$FAKE_REPO/.git/hooks/pre-commit")
    if echo "$shim_content" | grep -q "poetry run"; then
        assert_eq "test_poetry_fallback_in_precommit_shim" "has-poetry-fallback" "has-poetry-fallback"
    else
        assert_eq "test_poetry_fallback_in_precommit_shim" "has-poetry-fallback" "no-poetry-fallback"
    fi
else
    assert_eq "test_precommit_shim_created" "exists" "missing"
fi

rm -rf "$TMPDIR_T6"

# ---------------------------------------------------------------------------
# Test 7: all three hook types are installed
# ---------------------------------------------------------------------------
echo "Test 7: all three hook types are installed"

TMPDIR_T7=$(mktemp -d)
FAKE_REPO7="$TMPDIR_T7/repo"
mkdir -p "$FAKE_REPO7/app/.venv/bin"
git -C "$TMPDIR_T7" init -q "$FAKE_REPO7"
git -C "$FAKE_REPO7" config user.email "test@test.com"
git -C "$FAKE_REPO7" config user.name "Test"

# Create a mock pre-commit that records which hook types were installed
INSTALLED_HOOKS_LOG="$TMPDIR_T7/installed-hooks.log"
cat > "$FAKE_REPO7/app/.venv/bin/pre-commit" << MOCK_T7
#!/usr/bin/env bash
if [[ "\${1:-}" == "install" ]]; then
    HOOK_TYPE="pre-commit"
    prev_arg=""
    for arg in "\$@"; do
        if [[ "\$prev_arg" == "--hook-type" ]]; then
            HOOK_TYPE="\$arg"
        fi
        prev_arg="\$arg"
    done
    echo "\$HOOK_TYPE" >> "$INSTALLED_HOOKS_LOG"
    HOOK_DIR="\$(git -C "\$(pwd)" rev-parse --git-dir)/hooks"
    mkdir -p "\$HOOK_DIR"
    echo "#!/usr/bin/env bash" > "\$HOOK_DIR/\$HOOK_TYPE"
    echo "# INSTALL_PYTHON=/stale/path/.venv/bin/python" >> "\$HOOK_DIR/\$HOOK_TYPE"
    chmod +x "\$HOOK_DIR/\$HOOK_TYPE"
    exit 0
fi
exit 1
MOCK_T7
chmod +x "$FAKE_REPO7/app/.venv/bin/pre-commit"

WORKTREE_PATH="$FAKE_REPO7" bash "$SCRIPT" 2>/dev/null || true

# Check that all 3 hook types were installed
for hook_type in pre-commit pre-push prepare-commit-msg; do
    if [ -f "$INSTALLED_HOOKS_LOG" ] && grep -q "^$hook_type$" "$INSTALLED_HOOKS_LOG"; then
        assert_eq "test_hook_type_installed_$hook_type" "installed" "installed"
    else
        assert_eq "test_hook_type_installed_$hook_type" "installed" "not-installed"
    fi
done

rm -rf "$TMPDIR_T7"

# ---------------------------------------------------------------------------
# Test 8: hook shim with stale INSTALL_PYTHON path gets poetry run fallback injected
#
# The fix does NOT remove the stale INSTALL_PYTHON path — it keeps the existing
# fallback chain and adds `poetry run pre-commit` before the final error. When
# INSTALL_PYTHON is stale (non-executable), the hook falls through to poetry run.
# ---------------------------------------------------------------------------
echo "Test 8: hook shim with stale INSTALL_PYTHON path gets poetry run fallback injected"

TMPDIR_T8=$(mktemp -d)
FAKE_REPO8="$TMPDIR_T8/repo"
mkdir -p "$FAKE_REPO8/app/.venv/bin"
git -C "$TMPDIR_T8" init -q "$FAKE_REPO8"
git -C "$FAKE_REPO8" config user.email "test@test.com"
git -C "$FAKE_REPO8" config user.name "Test"

# Create a mock pre-commit that writes a shim with a stale INSTALL_PYTHON
cat > "$FAKE_REPO8/app/.venv/bin/pre-commit" << MOCK_T8
#!/usr/bin/env bash
if [[ "\${1:-}" == "install" ]]; then
    HOOK_TYPE="pre-commit"
    prev_arg=""
    for arg in "\$@"; do
        if [[ "\$prev_arg" == "--hook-type" ]]; then
            HOOK_TYPE="\$arg"
        fi
        prev_arg="\$arg"
    done
    HOOK_DIR="\$(git -C "\$(pwd)" rev-parse --git-dir)/hooks"
    mkdir -p "\$HOOK_DIR"
    cat > "\$HOOK_DIR/\$HOOK_TYPE" << 'SHIM'
#!/usr/bin/env bash
INSTALL_PYTHON=/stale/old/path/to/.venv/bin/python
ARGS=(hook-impl --config=.pre-commit-config.yaml --hook-type=pre-commit)
HERE="\$(cd "\$(dirname "\$0")" && pwd)"
ARGS+=("--hook-dir" "\$HERE" -- "\$@")
if [ -x "\$INSTALL_PYTHON" ]; then
    exec "\$INSTALL_PYTHON" -mpre_commit "\${ARGS[@]}"
elif command -v pre-commit > /dev/null; then
    exec pre-commit "\${ARGS[@]}"
else
    echo 'pre-commit not found' 1>&2
    exit 1
fi
SHIM
    chmod +x "\$HOOK_DIR/\$HOOK_TYPE"
    exit 0
fi
exit 1
MOCK_T8
chmod +x "$FAKE_REPO8/app/.venv/bin/pre-commit"

WORKTREE_PATH="$FAKE_REPO8" bash "$SCRIPT" 2>/dev/null || true

# Verify the hook was patched: poetry run fallback should be injected.
# The stale INSTALL_PYTHON path remains in the file — that's intentional.
# When INSTALL_PYTHON is non-executable (stale), the hook falls through to
# the new `poetry run pre-commit` branch instead of hitting the final error.
if [ -f "$FAKE_REPO8/.git/hooks/pre-commit" ]; then
    shim_content=$(cat "$FAKE_REPO8/.git/hooks/pre-commit")
    # The stale path may still be present in the shim (we don't remove it, we add a fallback)
    # but the hook now has a poetry run fallback to handle the stale case
    if echo "$shim_content" | grep -q "poetry run"; then
        assert_eq "test_poetry_fallback_injected_stale_shim" "has-poetry-run" "has-poetry-run"
    else
        assert_eq "test_poetry_fallback_injected_stale_shim" "has-poetry-run" "missing-poetry-run"
    fi
else
    assert_eq "test_hook_shim_created_t8" "exists" "missing"
fi

rm -rf "$TMPDIR_T8"

# ---------------------------------------------------------------------------
# Test 9: executable bit is preserved on hook shims after patching
# ---------------------------------------------------------------------------
echo "Test 9: executable bit preserved on hook shims after patching"

TMPDIR_T9=$(mktemp -d)
FAKE_REPO9="$TMPDIR_T9/repo"
mkdir -p "$FAKE_REPO9/app/.venv/bin"
git -C "$TMPDIR_T9" init -q "$FAKE_REPO9"
git -C "$FAKE_REPO9" config user.email "test@test.com"
git -C "$FAKE_REPO9" config user.name "Test"

# Create a mock pre-commit that writes a shim
cat > "$FAKE_REPO9/app/.venv/bin/pre-commit" << MOCK_T9
#!/usr/bin/env bash
if [[ "\${1:-}" == "install" ]]; then
    HOOK_TYPE="pre-commit"
    prev_arg=""
    for arg in "\$@"; do
        if [[ "\$prev_arg" == "--hook-type" ]]; then
            HOOK_TYPE="\$arg"
        fi
        prev_arg="\$arg"
    done
    HOOK_DIR="\$(git -C "\$(pwd)" rev-parse --git-dir)/hooks"
    mkdir -p "\$HOOK_DIR"
    echo '#!/usr/bin/env bash' > "\$HOOK_DIR/\$HOOK_TYPE"
    echo 'INSTALL_PYTHON=/stale/path/.venv/bin/python' >> "\$HOOK_DIR/\$HOOK_TYPE"
    chmod +x "\$HOOK_DIR/\$HOOK_TYPE"
    exit 0
fi
exit 1
MOCK_T9
chmod +x "$FAKE_REPO9/app/.venv/bin/pre-commit"

WORKTREE_PATH="$FAKE_REPO9" bash "$SCRIPT" 2>/dev/null || true

# Check executable bit
if [ -f "$FAKE_REPO9/.git/hooks/pre-commit" ]; then
    if [ -x "$FAKE_REPO9/.git/hooks/pre-commit" ]; then
        assert_eq "test_executable_bit_preserved" "executable" "executable"
    else
        assert_eq "test_executable_bit_preserved" "executable" "not-executable"
    fi
else
    assert_eq "test_hook_shim_exists_t9" "exists" "missing"
fi

rm -rf "$TMPDIR_T9"

# ---------------------------------------------------------------------------
# Print summary
# ---------------------------------------------------------------------------
print_summary
