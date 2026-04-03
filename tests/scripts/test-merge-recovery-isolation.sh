#!/usr/bin/env bash
# tests/scripts/test-merge-recovery-isolation.sh
# Verifies that test-merge-recovery-integration.sh cannot leak git config
# to the real repo when cd to a test repo fails.
#
# Bug: e899-77d0 — test-merge-recovery-integration.sh sets core.hooksPath
# on isolated test repos via (cd "$_MAIN_REPO"; git config ...) subshells,
# but if cd fails silently (no set -e), git config writes to the CWD's
# shared .git/config, poisoning all worktrees.
#
# Fix: Replace bare `cd + git config` with `git -C` which fails cleanly,
# and add a cleanup trap to unset core.hooksPath on exit.
#
# Usage: bash tests/scripts/test-merge-recovery-isolation.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

source "$REPO_ROOT/tests/lib/assert.sh"

echo "=== test-merge-recovery-isolation.sh ==="

# ============================================================
# test_no_bare_cd_git_config_in_subshell
# The test file must NOT use the pattern (cd "$VAR"; git config ...)
# because if cd fails, git config writes to CWD's repo.
# Instead it must use git -C "$VAR" config ... which fails cleanly.
# ============================================================
test_no_bare_cd_git_config_in_subshell() {
    local test_file="$REPO_ROOT/tests/scripts/test-merge-recovery-integration.sh"
    local bad_pattern_count=0

    # Look for bare `git config core.hooksPath <value>` writes (not reads, not -C).
    # A "write" has a value argument after hooksPath. A "read" does not.
    # Exclude lines that use -C (safe) or --unset (cleanup).
    # Count writes: lines matching `git config core.hooksPath "` or `git config core.hooksPath $`
    # that do NOT contain `-C` or `--unset`
    local bare_count
    bare_count=$(grep 'git config core\.hooksPath' "$test_file" \
        | grep -v '\-C\|--unset\|2>/dev/null || true' \
        | wc -l | tr -d ' ')

    assert_eq "test_no_bare_cd_git_config_in_subshell: no bare git config core.hooksPath (without -C)" "0" "$bare_count"
}

# ============================================================
# test_cleanup_trap_exists
# The test file must have a trap that cleans up temp dirs and
# unsets core.hooksPath on exit.
# ============================================================
test_cleanup_trap_exists() {
    local test_file="$REPO_ROOT/tests/scripts/test-merge-recovery-integration.sh"
    local has_trap="missing"

    if grep -q 'trap.*cleanup\|trap.*clean\|trap.*rm.*TEST_BASE\|trap.*unset.*hooksPath' "$test_file" 2>/dev/null; then
        has_trap="found"
    fi

    assert_eq "test_cleanup_trap_exists: cleanup trap exists in test file" "found" "$has_trap"
}

# ============================================================
# test_git_c_flag_used_for_hookspath
# All core.hooksPath config writes must use git -C to target
# the specific repo, not rely on CWD.
# ============================================================
test_git_c_flag_used_for_hookspath() {
    local test_file="$REPO_ROOT/tests/scripts/test-merge-recovery-integration.sh"

    # Count all git config core.hooksPath WRITE lines (exclude reads/unsets in cleanup)
    local total
    total=$(grep 'git.*config core\.hooksPath' "$test_file" \
        | grep -v '\-\-unset\|2>/dev/null || true' \
        | wc -l | tr -d ' ')
    # Count ones using -C flag
    local with_c=$(grep -c 'git -C .* config core\.hooksPath' "$test_file" 2>/dev/null || echo "0")

    assert_eq "test_git_c_flag_used_for_hookspath: all hooksPath writes use git -C ($with_c/$total)" "$total" "$with_c"
}

# Run tests
test_no_bare_cd_git_config_in_subshell
test_cleanup_trap_exists
test_git_c_flag_used_for_hookspath

echo ""
echo "=== Done ==="
