#!/usr/bin/env bash
# tests/scripts/test-python-resolver-config-driven.sh
# TDD tests verifying that 8 scripts use config-driven Python venv paths
# instead of hardcoded app/.venv/bin/python3 references.
#
# Tests:
#   test_<script>_uses_config_python_venv — no hardcoded app/.venv/bin/python in script
#   test_<script>_sources_config_paths    — script sources config-paths.sh
#   test_classify_task_no_hardcoded_poetry_lock — no hardcoded app/poetry.lock
#
# Usage: bash tests/scripts/test-python-resolver-config-driven.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DSO_PLUGIN_DIR="$PLUGIN_ROOT/plugins/dso"
REPO_ROOT="$(cd "$SCRIPT_DIR" && git rev-parse --show-toplevel)"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

echo "=== test-python-resolver-config-driven.sh ==="

SCRIPTS_DIR="$DSO_PLUGIN_DIR/scripts"

# List of 6 scripts that must use config-driven paths
SCRIPTS=(
    "read-config.sh"
    "ci-status.sh"
    "worktree-create.sh"
    "check-local-env.sh"
    "classify-task.sh"
    "issue-batch.sh"
)

# ── test_<script>_uses_config_python_venv ──────────────────────────────────
# No hardcoded app/.venv/bin/python in any of the 6 scripts
echo ""
echo "--- No hardcoded app/.venv/bin/python ---"

for script in "${SCRIPTS[@]}"; do
    _snapshot_fail
    filepath="$SCRIPTS_DIR/$script"
    if [[ ! -f "$filepath" ]]; then
        assert_eq "test_${script}_uses_config_python_venv: file exists" "exists" "missing"
        continue
    fi
    # Count non-comment lines containing hardcoded app/.venv/bin/python
    # Exclude ${..:-app/.venv/...} parameter expansion defaults (config-driven with fallback)
    hardcoded=$(grep -v '^\s*#' "$filepath" | grep -v ':-app/\.venv/bin/python' | grep -c 'app/\.venv/bin/python' || true)
    assert_eq "test_${script}_uses_config_python_venv" "0" "$hardcoded"
    assert_pass_if_clean "test_${script}_uses_config_python_venv"
done

# ── test_<script>_sources_config_paths ─────────────────────────────────────
# All 6 scripts source config-paths.sh
echo ""
echo "--- Sources config-paths.sh ---"

for script in "${SCRIPTS[@]}"; do
    _snapshot_fail
    filepath="$SCRIPTS_DIR/$script"
    if [[ ! -f "$filepath" ]]; then
        assert_eq "test_${script}_sources_config_paths: file exists" "exists" "missing"
        continue
    fi
    sources_config=$(grep -c 'config-paths\.sh' "$filepath" || true)
    assert_ne "test_${script}_sources_config_paths" "0" "$sources_config"
    assert_pass_if_clean "test_${script}_sources_config_paths"
done

# ── test_classify_task_no_hardcoded_poetry_lock ────────────────────────────
# classify-task.sh should not reference app/poetry.lock
echo ""
echo "--- No hardcoded app/poetry.lock in classify-task.sh ---"

_snapshot_fail
classify_script="$SCRIPTS_DIR/classify-task.sh"
poetry_lock_refs=$(grep -v '^\s*#' "$classify_script" | grep -c 'app/poetry\.lock' || true)
assert_eq "test_classify_task_no_hardcoded_poetry_lock" "0" "$poetry_lock_refs"
assert_pass_if_clean "test_classify_task_no_hardcoded_poetry_lock"

# ── test_worktree_sync_no_hardcoded_venv_bin ───────────────────────────────
# worktree-sync-from-main.sh should not have hardcoded _VENV_BIN=...app/.venv/bin
echo ""
echo "--- No hardcoded _VENV_BIN in worktree-sync-from-main.sh ---"

_snapshot_fail
sync_script="$SCRIPTS_DIR/worktree-sync-from-main.sh"
venv_bin_refs=$(grep -v '^\s*#' "$sync_script" | grep -c 'app/\.venv/bin"' || true)
assert_eq "test_worktree_sync_no_hardcoded_venv_bin" "0" "$venv_bin_refs"
assert_pass_if_clean "test_worktree_sync_no_hardcoded_venv_bin"

print_summary
