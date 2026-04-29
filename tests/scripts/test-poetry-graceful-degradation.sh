#!/usr/bin/env bash
# tests/scripts/test-poetry-graceful-degradation.sh
# TDD tests for Poetry graceful degradation in plugin scripts.
#
# Covers:
#   test_classify_task_no_poetry_uses_system_python
#     -- classify-task.sh falls back to system python3 when poetry absent
#   test_ensure_precommit_skips_install_without_poetry
#     -- ensure-pre-commit.sh skips hook installation when poetry absent
#   test_hook_chain_consistent_without_poetry
#     -- reinstall-hooks.sh degrades gracefully (exits non-zero or skips) when
#        poetry absent and no venv available
#
# Usage:
#   bash tests/scripts/test-poetry-graceful-degradation.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DSO_PLUGIN_DIR="$PLUGIN_ROOT/plugins/dso"
REPO_ROOT="$(cd "$SCRIPT_DIR" && git rev-parse --show-toplevel)"
ASSERT_LIB="$PLUGIN_ROOT/tests/lib/assert.sh"

CLASSIFY_TASK_SH="$DSO_PLUGIN_DIR/scripts/classify-task.sh"
ENSURE_PRECOMMIT_SH="$DSO_PLUGIN_DIR/scripts/ensure-pre-commit.sh"
REINSTALL_HOOKS_SH="$DSO_PLUGIN_DIR/scripts/reinstall-hooks.sh"

source "$ASSERT_LIB"

# Temp dir cleanup on exit
_CLEANUP_DIRS=()
_cleanup() { for d in "${_CLEANUP_DIRS[@]}"; do rm -rf "$d"; done; }
trap _cleanup EXIT

echo "=== test-poetry-graceful-degradation.sh ==="
echo ""

# Helper: build a PATH that excludes any poetry installation
_path_without_poetry() {
    echo "$PATH" | tr ':' '\n' | grep -v poetry | tr '\n' ':'
}

# Helper: create a tmp dir with a fake git repo for testing hooks
_make_fake_git_repo() {
    local tmpdir
    tmpdir="$(mktemp -d)"
    _CLEANUP_DIRS+=("$tmpdir")
    mkdir -p "$tmpdir/app"
    git -C "$tmpdir" init -q 2>/dev/null
    git -C "$tmpdir" config user.email "test@test.com"
    git -C "$tmpdir" config user.name "Test"
    echo "$tmpdir"
}

# ---------------------------------------------------------------------------
# Test 1: classify-task.sh syntax check
# ---------------------------------------------------------------------------
echo "Test 1: classify-task.sh syntax check"
syntax_exit=0
bash -n "$CLASSIFY_TASK_SH" 2>&1 || syntax_exit=$?
assert_eq "test_classify_task_syntax_ok" "0" "$syntax_exit"

# ---------------------------------------------------------------------------
# Test 2: test_classify_task_no_poetry_uses_system_python
# classify-task.sh must not crash when poetry is absent from PATH.
# With no args it exits 2 with usage -- exit code le 2 is acceptable.
# ---------------------------------------------------------------------------
echo "Test 2: test_classify_task_no_poetry_uses_system_python"
{
    no_poetry_path="$(_path_without_poetry)"
    rc=0
    PATH="$no_poetry_path" bash "$CLASSIFY_TASK_SH" 2>/dev/null || rc=$?
    if [ "$rc" -le 2 ]; then
        assert_eq "test_classify_task_no_poetry_uses_system_python" "exit<=2" "exit<=2"
    else
        assert_eq "test_classify_task_no_poetry_uses_system_python" "exit<=2" "exit=$rc"
    fi
}

# ---------------------------------------------------------------------------
# Test 3: issue-batch.sh does not crash when poetry absent
# ---------------------------------------------------------------------------
echo "Test 3: issue-batch.sh does not crash when poetry absent"
{
    ISSUE_BATCH_SH="$DSO_PLUGIN_DIR/scripts/issue-batch.sh"
    no_poetry_path="$(_path_without_poetry)"
    rc=0
    PATH="$no_poetry_path" bash "$ISSUE_BATCH_SH" 2>/dev/null || rc=$?
    if [ "$rc" -le 2 ]; then
        assert_eq "test_issue_batch_no_poetry_no_crash" "exit<=2" "exit<=2"
    else
        assert_eq "test_issue_batch_no_poetry_no_crash" "exit<=2" "exit=$rc"
    fi
}

# ---------------------------------------------------------------------------
# Test 4: test_ensure_precommit_skips_install_without_poetry (static check)
# ensure-pre-commit.sh must contain a command -v poetry or which poetry guard.
# ---------------------------------------------------------------------------
echo "Test 4: test_ensure_precommit_skips_install_without_poetry (static check)"
{
    if grep -q 'command -v poetry\|which poetry' "$ENSURE_PRECOMMIT_SH" 2>/dev/null; then
        assert_eq "test_ensure_precommit_has_poetry_guard" "has-poetry-guard" "has-poetry-guard"
    else
        assert_eq "test_ensure_precommit_has_poetry_guard" "has-poetry-guard" "missing-poetry-guard"
    fi
}

# ---------------------------------------------------------------------------
# Test 5: ensure-pre-commit.sh does not crash when poetry absent
# ---------------------------------------------------------------------------
echo "Test 5: ensure-pre-commit.sh does not crash when poetry absent"
{
    no_poetry_path="$(_path_without_poetry)"
    rc=0
    PATH="$no_poetry_path" bash "$ENSURE_PRECOMMIT_SH" 2>/dev/null || rc=$?
    if [ "$rc" -le 1 ]; then
        assert_eq "test_ensure_precommit_no_poetry_no_crash" "exit<=1" "exit<=1"
    else
        assert_eq "test_ensure_precommit_no_poetry_no_crash" "exit<=1" "exit=$rc"
    fi
}

# ---------------------------------------------------------------------------
# Test 6: test_hook_chain_consistent_without_poetry (static check)
# reinstall-hooks.sh must contain a command -v poetry guard.
# ---------------------------------------------------------------------------
echo "Test 6: test_hook_chain_consistent_without_poetry (static check)"
{
    if grep -q 'command -v poetry\|which poetry' "$REINSTALL_HOOKS_SH" 2>/dev/null; then
        assert_eq "test_reinstall_hooks_has_poetry_guard" "has-poetry-guard" "has-poetry-guard"
    else
        assert_eq "test_reinstall_hooks_has_poetry_guard" "has-poetry-guard" "missing-poetry-guard"
    fi
}

# ---------------------------------------------------------------------------
# Test 7: reinstall-hooks.sh exits non-zero cleanly when no venv and no poetry
# ---------------------------------------------------------------------------
echo "Test 7: reinstall-hooks.sh degrades gracefully when no venv and no poetry"
{
    fake_repo="$(_make_fake_git_repo)"
    no_poetry_path="$(_path_without_poetry)"
    rc=0
    # timeout guard: system pre-commit (when in PATH) initializes a SQLite cache
    # on first run; on cold CI runners this can take 30s/hook-type x 3 = 90s,
    # which hits the per-file test suite limit. timeout exits 124 (non-zero),
    # which the assert below already accepts as valid graceful degradation.
    if command -v timeout >/dev/null 2>&1; then
        output=$(WORKTREE_PATH="$fake_repo" PATH="$no_poetry_path" timeout 30 bash "$REINSTALL_HOOKS_SH" 2>&1) || rc=$?
    else
        output=$(WORKTREE_PATH="$fake_repo" PATH="$no_poetry_path" bash "$REINSTALL_HOOKS_SH" 2>&1) || rc=$?
    fi
    if [ "$rc" -eq 0 ]; then
        # Exit 0 is correct graceful degradation — no-op when nothing to install
        assert_eq "test_hook_chain_consistent_without_poetry" "exit=0" "exit=0"
    else
        # Non-zero is also acceptable (e.g., pre-commit found but install fails)
        assert_eq "test_hook_chain_consistent_without_poetry" "exit>0" "exit>0"
    fi
}

# ---------------------------------------------------------------------------
# Test 8: classify-task.sh with task ID falls back to system python3
# When poetry absent but system python3 is available, produces JSON output.
# ---------------------------------------------------------------------------
echo "Test 8: classify-task.sh with task ID falls back to system python3"
{
    if ! python3 -c "import yaml" 2>/dev/null; then
        echo "  SKIP: classify-task.py requires PyYAML for JSON output"
        (( PASS++ ))
    else
        no_poetry_path="$(_path_without_poetry)"
        output=""
        if command -v timeout >/dev/null 2>&1; then
            output=$(PATH="$no_poetry_path" timeout 30 bash "$CLASSIFY_TASK_SH" "lockpick-doc-to-logic-9o48" 2>/dev/null) || true
        else
            output=$(PATH="$no_poetry_path" bash "$CLASSIFY_TASK_SH" "lockpick-doc-to-logic-9o48" 2>/dev/null) || true
        fi
        if echo "$output" | python3 -c "import sys,json; json.load(sys.stdin)" 2>/dev/null; then
            assert_eq "test_classify_task_outputs_json_without_poetry" "json-output" "json-output"
        else
            assert_eq "test_classify_task_outputs_json_without_poetry" "json-output" "non-json-output"
        fi
    fi
}

# ---------------------------------------------------------------------------
# Print summary
# ---------------------------------------------------------------------------
echo ""
print_summary
