#!/usr/bin/env bash
# lockpick-workflow/tests/scripts/test-cleanup-session-no-hardcoded-app.sh
# TDD tests verifying cleanup-claude-session.sh uses config-derived app/ paths
# instead of hardcoded app/ references.
#
# Tests:
#   test_cleanup_session_sources_config_paths — script sources config-paths.sh
#   test_cleanup_session_no_hardcoded_app — no hardcoded app/ in non-comment lines
#
# Usage: bash lockpick-workflow/tests/scripts/test-cleanup-session-no-hardcoded-app.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
SCRIPT="$REPO_ROOT/lockpick-workflow/scripts/cleanup-claude-session.sh"

source "$REPO_ROOT/lockpick-workflow/tests/lib/assert.sh"

echo "=== test-cleanup-session-no-hardcoded-app.sh ==="

# ============================================================================
# test_cleanup_session_sources_config_paths
# ============================================================================
echo "=== test_cleanup_session_sources_config_paths ==="
_snapshot_fail

SOURCES_CONFIG=$(grep -v '^\s*#' "$SCRIPT" | grep -c 'config-paths.sh' || true)
assert_ne "cleanup-claude-session.sh sources config-paths.sh" "0" "$SOURCES_CONFIG"

assert_pass_if_clean "test_cleanup_session_sources_config_paths"

# ============================================================================
# test_cleanup_session_no_hardcoded_app
# ============================================================================
# The AC specifically checks: grep -v '^\s*#' ... | grep -q '".*app/'
# We check for any hardcoded app/ in non-comment lines.
echo "=== test_cleanup_session_no_hardcoded_app ==="
_snapshot_fail

HARDCODED_APP=$(grep -v '^\s*#' "$SCRIPT" | grep -c '".*app/' || true)
assert_eq "no hardcoded app/ in non-comment quoted strings of cleanup-claude-session.sh" "0" "$HARDCODED_APP"

assert_pass_if_clean "test_cleanup_session_no_hardcoded_app"

# ============================================================================
# test_cleanup_session_syntax_valid
# ============================================================================
echo "=== test_cleanup_session_syntax_valid ==="
_snapshot_fail

if bash -n "$SCRIPT" 2>/dev/null; then
    SYNTAX_OK="yes"
else
    SYNTAX_OK="no"
fi
assert_eq "cleanup-claude-session.sh has valid syntax" "yes" "$SYNTAX_OK"

assert_pass_if_clean "test_cleanup_session_syntax_valid"

print_summary
