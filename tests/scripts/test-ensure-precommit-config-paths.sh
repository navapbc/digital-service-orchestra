#!/usr/bin/env bash
# tests/scripts/test-ensure-precommit-config-paths.sh
# TDD tests verifying ensure-pre-commit.sh uses config-derived app/ paths
# instead of hardcoded app/.venv references.
#
# Tests:
#   test_ensure_precommit_sources_config_paths — script sources config-paths.sh
#   test_ensure_precommit_no_hardcoded_app_venv — no hardcoded app/.venv in non-comment lines
#   test_ensure_precommit_uses_cfg_app_dir — references CFG_APP_DIR variable
#   test_ensure_precommit_syntax_valid — script has valid bash syntax
#
# Usage: bash tests/scripts/test-ensure-precommit-config-paths.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DSO_PLUGIN_DIR="$PLUGIN_ROOT/plugins/dso"
REPO_ROOT="$(git rev-parse --show-toplevel)"
SCRIPT="$DSO_PLUGIN_DIR/scripts/ensure-pre-commit.sh"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

echo "=== test-ensure-precommit-config-paths.sh ==="

# ============================================================================
# test_ensure_precommit_sources_config_paths
# ============================================================================
echo "=== test_ensure_precommit_sources_config_paths ==="
_snapshot_fail

SOURCES_CONFIG=$(grep -v '^\s*#' "$SCRIPT" | grep -c 'config-paths.sh' || true)
assert_ne "ensure-pre-commit.sh sources config-paths.sh" "0" "$SOURCES_CONFIG"

assert_pass_if_clean "test_ensure_precommit_sources_config_paths"

# ============================================================================
# test_ensure_precommit_no_hardcoded_app_venv
# ============================================================================
echo "=== test_ensure_precommit_no_hardcoded_app_venv ==="
_snapshot_fail

HARDCODED_VENV=$(grep -v '^\s*#' "$SCRIPT" | grep -c 'app/\.venv' || true)
assert_eq "no hardcoded app/.venv in non-comment lines of ensure-pre-commit.sh" "0" "$HARDCODED_VENV"

assert_pass_if_clean "test_ensure_precommit_no_hardcoded_app_venv"

# ============================================================================
# test_ensure_precommit_uses_cfg_app_dir
# ============================================================================
echo "=== test_ensure_precommit_uses_cfg_app_dir ==="
_snapshot_fail

USES_CFG=$(grep -v '^\s*#' "$SCRIPT" | grep -c 'CFG_APP_DIR' || true)
assert_ne "ensure-pre-commit.sh uses CFG_APP_DIR" "0" "$USES_CFG"

assert_pass_if_clean "test_ensure_precommit_uses_cfg_app_dir"

# ============================================================================
# test_ensure_precommit_syntax_valid
# ============================================================================
echo "=== test_ensure_precommit_syntax_valid ==="
_snapshot_fail

if bash -n "$SCRIPT" 2>/dev/null; then
    SYNTAX_OK="yes"
else
    SYNTAX_OK="no"
fi
assert_eq "ensure-pre-commit.sh has valid syntax" "yes" "$SYNTAX_OK"

assert_pass_if_clean "test_ensure_precommit_syntax_valid"

print_summary
