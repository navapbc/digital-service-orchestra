#!/usr/bin/env bash
# tests/scripts/test-config-flag-disabled-paths.sh
# SDET audit P1-8: per-flag disabled-path tests for config feature flags.
#
# Prior coverage exercised enabled-path-only for these flags. This file
# asserts the disabled (false) path for each so a regression that breaks
# the off-switch is caught at pre-commit.
#
# Flags covered:
#   design.figma_collaboration
#   planning.external_dependency_block_enabled
#   scope_drift.enabled
#   worktree.isolation_enabled
#
# Usage: bash tests/scripts/test-config-flag-disabled-paths.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"
READ_CONFIG="$REPO_ROOT/plugins/dso/scripts/read-config.sh"

source "$REPO_ROOT/tests/lib/assert.sh"

echo "=== test-config-flag-disabled-paths.sh ==="

if [[ ! -f "$READ_CONFIG" ]]; then
    echo "SKIP: $READ_CONFIG not found"
    printf "PASSED: %d  FAILED: %d\n" "$PASS" "$FAIL"
    exit 0
fi

# Isolated test config to avoid pollution from the real dso-config.conf.
TEST_TMPDIR=$(mktemp -d "${TMPDIR:-/tmp}/config-disabled.XXXXXX")
trap 'rm -rf "$TEST_TMPDIR"' EXIT
TEST_CONFIG="$TEST_TMPDIR/dso-config.conf"

# Read a flag from the test config, returning the literal string (empty when
# unset). read-config.sh accepts an explicit config-file argument; pass our
# isolated test config to avoid pollution from the repo's real config.
_read_flag() {
    local key="$1"
    bash "$READ_CONFIG" "$key" "$TEST_CONFIG" 2>/dev/null || true
}

# ─── Test 1 — design.figma_collaboration=false yields empty/false ────────────
echo ""
echo "--- test_figma_collaboration_disabled_path ---"

test_figma_collaboration_disabled_path() {
    _snapshot_fail
    : > "$TEST_CONFIG"
    {
        echo "design.figma_collaboration=false"
    } > "$TEST_CONFIG"

    local value
    value=$(_read_flag design.figma_collaboration)
    assert_eq "design.figma_collaboration=false is preserved as 'false'" "false" "$value"
    assert_pass_if_clean "test_figma_collaboration_disabled_path"
}
test_figma_collaboration_disabled_path

# ─── Test 2 — planning.external_dependency_block_enabled=false ───────────────
echo ""
echo "--- test_external_dependency_block_disabled_path ---"

test_external_dependency_block_disabled_path() {
    _snapshot_fail
    {
        echo "planning.external_dependency_block_enabled=false"
    } > "$TEST_CONFIG"

    local value
    value=$(_read_flag planning.external_dependency_block_enabled)
    assert_eq "planning.external_dependency_block_enabled=false preserved" "false" "$value"
    assert_pass_if_clean "test_external_dependency_block_disabled_path"
}
test_external_dependency_block_disabled_path

# ─── Test 3 — scope_drift.enabled=false ──────────────────────────────────────
echo ""
echo "--- test_scope_drift_disabled_path ---"

test_scope_drift_disabled_path() {
    _snapshot_fail
    {
        echo "scope_drift.enabled=false"
    } > "$TEST_CONFIG"

    local value
    value=$(_read_flag scope_drift.enabled)
    assert_eq "scope_drift.enabled=false preserved" "false" "$value"
    assert_pass_if_clean "test_scope_drift_disabled_path"
}
test_scope_drift_disabled_path

# ─── Test 4 — worktree.isolation_enabled=false ───────────────────────────────
# This key is deprecated and consolidated into `dso.workflow`. read-config.sh
# applies a sentinel lockout when `.claude/.dso-config-v2-migrated` exists,
# returning empty for the legacy key. Skip post-migration; until then the test
# guards the legacy read path.
echo ""
echo "--- test_worktree_isolation_disabled_path ---"

test_worktree_isolation_disabled_path() {
    _snapshot_fail
    if [[ -f "$REPO_ROOT/.claude/.dso-config-v2-migrated" ]]; then
        echo "  skipped: post-migration sentinel present (legacy key locked out)"
        assert_pass_if_clean "test_worktree_isolation_disabled_path"
        return 0
    fi
    {
        echo "worktree.isolation_enabled=false"
    } > "$TEST_CONFIG"

    local value
    value=$(_read_flag worktree.isolation_enabled)
    assert_eq "worktree.isolation_enabled=false preserved" "false" "$value"
    assert_pass_if_clean "test_worktree_isolation_disabled_path"
}
test_worktree_isolation_disabled_path

# ─── Test 5 — absent flag returns empty (default-disabled semantics) ─────────
echo ""
echo "--- test_absent_flag_returns_empty ---"

test_absent_flag_returns_empty() {
    _snapshot_fail
    : > "$TEST_CONFIG"   # empty config

    local value
    value=$(_read_flag scope_drift.enabled)
    assert_eq "absent flag yields empty string" "" "$value"
    assert_pass_if_clean "test_absent_flag_returns_empty"
}
test_absent_flag_returns_empty

print_summary
