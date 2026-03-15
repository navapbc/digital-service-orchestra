#!/usr/bin/env bash
# lockpick-workflow/scripts/ensure-pre-commit.sh
# Pre-flight check: ensure pre-commit is available and git hook shims are not stale.
#
# Called by COMMIT-WORKFLOW.md Step 0 before any git commands.
# Activates the venv if pre-commit is not on PATH, and detects stale
# INSTALL_PYTHON paths in git hook shims (left behind when worktrees are
# cleaned up). If a stale shim is found without a fallback, automatically
# runs reinstall-hooks.sh to patch it.
#
# Usage: source ensure-pre-commit.sh   (sources into current shell for venv activation)
#    or: bash ensure-pre-commit.sh      (runs as subprocess — venv won't persist in caller)
#
# Exit codes:
#   0 — pre-commit is available (or shim was repaired)
#   1 — pre-commit not found after all fallback attempts (warning only, not fatal)
#
# Note: This script intentionally avoids `set -euo pipefail` because it may be
# sourced into the caller's shell. Setting shell options here would persist in
# the caller and break scripts that rely on unset variables being empty strings.

_ensure_precommit_repo_root=$(git rev-parse --show-toplevel 2>/dev/null || echo "")
if [[ -z "$_ensure_precommit_repo_root" ]]; then
    echo "WARNING: Not in a git repository — skipping pre-commit check" >&2
    return 0 2>/dev/null || exit 0
fi

# Resolve plugin scripts directory
_ensure_precommit_plugin_scripts="${CLAUDE_PLUGIN_ROOT:-$_ensure_precommit_repo_root/lockpick-workflow}/scripts"

# Source config-paths.sh for portable path resolution
_ensure_precommit_config_paths="$_ensure_precommit_plugin_scripts/../hooks/lib/config-paths.sh"
if [ -f "$_ensure_precommit_config_paths" ]; then
    # shellcheck source=../hooks/lib/config-paths.sh
    source "$_ensure_precommit_config_paths"
fi
_ensure_precommit_app_dir="${CFG_APP_DIR:-app}"

# 1. Activate venv if pre-commit is not on PATH
if ! command -v pre-commit &>/dev/null; then
    if [ -f "$_ensure_precommit_repo_root/$_ensure_precommit_app_dir/.venv/bin/activate" ]; then
        # shellcheck disable=SC1091
        source "$_ensure_precommit_repo_root/$_ensure_precommit_app_dir/.venv/bin/activate"
    fi
fi

# 2. Check if git hook shims have a stale INSTALL_PYTHON path.
#    Worktree cleanup can leave .git/hooks/pre-commit pointing at a dead venv.
#    The venv-python and poetry-run fallbacks (added by reinstall-hooks.sh)
#    prevent failures, but if they're missing, reinstall now.
#    Sentinel: reinstall-hooks.sh patches shims to add both '<app_dir>/.venv/bin/python'
#    and 'poetry run pre-commit' fallbacks. Check for either to detect patched shims.
_ensure_precommit_hook_shim="$_ensure_precommit_repo_root/.git/hooks/pre-commit"
if [ -f "$_ensure_precommit_hook_shim" ]; then
    _ensure_precommit_install_py=$(grep '^INSTALL_PYTHON=' "$_ensure_precommit_hook_shim" 2>/dev/null | head -1 | cut -d= -f2-)
    _ensure_precommit_has_fallback=0
    if grep -q "$_ensure_precommit_app_dir/.venv/bin/python" "$_ensure_precommit_hook_shim" 2>/dev/null \
       || grep -q 'poetry run pre-commit' "$_ensure_precommit_hook_shim" 2>/dev/null; then
        _ensure_precommit_has_fallback=1
    fi
    if [ -n "$_ensure_precommit_install_py" ] \
       && [ ! -x "$_ensure_precommit_install_py" ] \
       && [ "$_ensure_precommit_has_fallback" -eq 0 ]; then
        echo "Stale INSTALL_PYTHON in hook shim — running reinstall-hooks.sh" >&2
        WORKTREE_PATH="$_ensure_precommit_repo_root" "$_ensure_precommit_plugin_scripts/reinstall-hooks.sh" 2>&1 || true
    fi
fi

# 3. Final check — warn if pre-commit is still not available
if ! command -v pre-commit &>/dev/null; then
    # Check if the venv python has pre_commit installed as a module.
    # If so, add the venv bin dir to PATH so subsequent `pre-commit` calls work.
    if [ -x "$_ensure_precommit_repo_root/$_ensure_precommit_app_dir/.venv/bin/python" ]; then
        if "$_ensure_precommit_repo_root/$_ensure_precommit_app_dir/.venv/bin/python" -c "import pre_commit" &>/dev/null; then
            export PATH="$_ensure_precommit_repo_root/$_ensure_precommit_app_dir/.venv/bin:$PATH"
            return 0 2>/dev/null || exit 0
        fi
    fi
    echo "WARNING: pre-commit not found on PATH — git commit hooks may fail" >&2
    echo "  Fix: cd app && poetry install" >&2
    return 1 2>/dev/null || exit 1
fi

return 0 2>/dev/null || exit 0
