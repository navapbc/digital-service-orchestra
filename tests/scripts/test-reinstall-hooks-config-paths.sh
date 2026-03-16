#!/usr/bin/env bash
# tests/scripts/test-reinstall-hooks-config-paths.sh
# TDD tests verifying reinstall-hooks.sh uses config-derived app/ paths
# instead of hardcoded app/.venv and app/pyproject.toml references.
#
# Tests:
#   test_reinstall_hooks_sources_config_paths — script sources config-paths.sh
#   test_reinstall_hooks_no_hardcoded_app_venv — no hardcoded app/.venv in non-comment lines
#   test_reinstall_hooks_no_hardcoded_app_pyproject — no hardcoded app/pyproject.toml in non-comment lines
#   test_reinstall_hooks_shim_uses_config_paths — generated shim code references config-derived paths
#   test_reinstall_hooks_uses_cfg_app_dir — references CFG_APP_DIR variable
#   test_reinstall_hooks_syntax_valid — script has valid bash syntax
#
# Usage: bash tests/scripts/test-reinstall-hooks-config-paths.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
REPO_ROOT="$(git rev-parse --show-toplevel)"
SCRIPT="$PLUGIN_ROOT/scripts/reinstall-hooks.sh"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

echo "=== test-reinstall-hooks-config-paths.sh ==="

# ============================================================================
# test_reinstall_hooks_sources_config_paths
# ============================================================================
echo "=== test_reinstall_hooks_sources_config_paths ==="
_snapshot_fail

SOURCES_CONFIG=$(grep -v '^\s*#' "$SCRIPT" | grep -c 'config-paths.sh' || true)
assert_ne "reinstall-hooks.sh sources config-paths.sh" "0" "$SOURCES_CONFIG"

assert_pass_if_clean "test_reinstall_hooks_sources_config_paths"

# ============================================================================
# test_reinstall_hooks_no_hardcoded_app_venv
# ============================================================================
echo "=== test_reinstall_hooks_no_hardcoded_app_venv ==="
_snapshot_fail

HARDCODED_VENV=$(grep -v '^\s*#' "$SCRIPT" | grep -c 'app/\.venv' || true)
assert_eq "no hardcoded app/.venv in non-comment lines of reinstall-hooks.sh" "0" "$HARDCODED_VENV"

assert_pass_if_clean "test_reinstall_hooks_no_hardcoded_app_venv"

# ============================================================================
# test_reinstall_hooks_no_hardcoded_app_pyproject
# ============================================================================
echo "=== test_reinstall_hooks_no_hardcoded_app_pyproject ==="
_snapshot_fail

HARDCODED_PYPROJECT=$(grep -v '^\s*#' "$SCRIPT" | grep -c 'app/pyproject\.toml' || true)
assert_eq "no hardcoded app/pyproject.toml in non-comment lines of reinstall-hooks.sh" "0" "$HARDCODED_PYPROJECT"

assert_pass_if_clean "test_reinstall_hooks_no_hardcoded_app_pyproject"

# ============================================================================
# test_reinstall_hooks_shim_uses_config_paths
# ============================================================================
# The awk-injected shim code should reference config-derived paths (CFG_APP_DIR)
# rather than hardcoded app/ paths.
echo "=== test_reinstall_hooks_shim_uses_config_paths ==="
_snapshot_fail

# The awk block injects fallback code into hook shims. Check that the awk output
# lines (inside the awk script) do not contain hardcoded app/ references.
# Extract the awk script block and check for hardcoded app/ paths.
AWK_HARDCODED=$(sed -n "/^    awk '/,/^    ' /p" "$SCRIPT" | grep -c 'app/' || true)
assert_eq "awk-injected shim code has no hardcoded app/ paths" "0" "$AWK_HARDCODED"

assert_pass_if_clean "test_reinstall_hooks_shim_uses_config_paths"

# ============================================================================
# test_reinstall_hooks_uses_cfg_app_dir
# ============================================================================
echo "=== test_reinstall_hooks_uses_cfg_app_dir ==="
_snapshot_fail

USES_CFG=$(grep -v '^\s*#' "$SCRIPT" | grep -c 'CFG_APP_DIR' || true)
assert_ne "reinstall-hooks.sh uses CFG_APP_DIR" "0" "$USES_CFG"

assert_pass_if_clean "test_reinstall_hooks_uses_cfg_app_dir"

# ============================================================================
# test_reinstall_hooks_syntax_valid
# ============================================================================
echo "=== test_reinstall_hooks_syntax_valid ==="
_snapshot_fail

if bash -n "$SCRIPT" 2>/dev/null; then
    SYNTAX_OK="yes"
else
    SYNTAX_OK="no"
fi
assert_eq "reinstall-hooks.sh has valid syntax" "yes" "$SYNTAX_OK"

assert_pass_if_clean "test_reinstall_hooks_syntax_valid"

print_summary
