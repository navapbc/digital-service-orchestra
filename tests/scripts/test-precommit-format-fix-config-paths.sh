#!/usr/bin/env bash
# tests/scripts/test-precommit-format-fix-config-paths.sh
# TDD tests verifying pre-commit-format-fix.sh uses config-derived app/ paths
# instead of hardcoded app/ references.
#
# Tests:
#   test_precommit_format_fix_sources_config_paths — script sources config-paths.sh
#   test_precommit_format_fix_no_hardcoded_app — no hardcoded app/ in non-comment lines
#   test_precommit_format_fix_uses_cfg_app_dir — references CFG_APP_DIR variable
#
# Usage: bash tests/scripts/test-precommit-format-fix-config-paths.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
REPO_ROOT="$(git rev-parse --show-toplevel)"
SCRIPT="$PLUGIN_ROOT/scripts/pre-commit-format-fix.sh"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

echo "=== test-precommit-format-fix-config-paths.sh ==="

# ============================================================================
# test_precommit_format_fix_sources_config_paths
# ============================================================================
echo "=== test_precommit_format_fix_sources_config_paths ==="
_snapshot_fail

SOURCES_CONFIG=$(grep -v '^\s*#' "$SCRIPT" | grep -c 'config-paths.sh' || true)
assert_ne "pre-commit-format-fix.sh sources config-paths.sh" "0" "$SOURCES_CONFIG"

assert_pass_if_clean "test_precommit_format_fix_sources_config_paths"

# ============================================================================
# test_precommit_format_fix_no_hardcoded_app
# ============================================================================
# Non-comment lines must not contain hardcoded app/ path patterns.
# Allowed: $CFG_APP_DIR references, comments explaining the change.
echo "=== test_precommit_format_fix_no_hardcoded_app ==="
_snapshot_fail

HARDCODED_APP=$(grep -v '^\s*#' "$SCRIPT" | grep -c 'app/' || true)
assert_eq "no hardcoded app/ in non-comment lines of pre-commit-format-fix.sh" "0" "$HARDCODED_APP"

assert_pass_if_clean "test_precommit_format_fix_no_hardcoded_app"

# ============================================================================
# test_precommit_format_fix_uses_cfg_app_dir
# ============================================================================
echo "=== test_precommit_format_fix_uses_cfg_app_dir ==="
_snapshot_fail

USES_CFG=$(grep -v '^\s*#' "$SCRIPT" | grep -c 'CFG_APP_DIR' || true)
assert_ne "pre-commit-format-fix.sh uses CFG_APP_DIR" "0" "$USES_CFG"

assert_pass_if_clean "test_precommit_format_fix_uses_cfg_app_dir"

# ============================================================================
# test_precommit_format_fix_syntax_valid
# ============================================================================
echo "=== test_precommit_format_fix_syntax_valid ==="
_snapshot_fail

if bash -n "$SCRIPT" 2>/dev/null; then
    SYNTAX_OK="yes"
else
    SYNTAX_OK="no"
fi
assert_eq "pre-commit-format-fix.sh has valid syntax" "yes" "$SYNTAX_OK"

assert_pass_if_clean "test_precommit_format_fix_syntax_valid"

print_summary
