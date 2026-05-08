#!/usr/bin/env bash
# tests/hooks/test-post-commit-override-cleanup.sh
# RED tests for plugins/dso/hooks/post-commit-override-cleanup.sh
# All tests must FAIL until T5 implements the hook.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"
HOOK="$REPO_ROOT/plugins/dso/hooks/post-commit-override-cleanup.sh"

source "$SCRIPT_DIR/../lib/assert.sh"

# ── test_cleanup_removes_token ──────────────────────────────────────────────
# Given override.token exists at $ARTIFACTS_DIR/override.token,
# the hook removes it and exits 0.
test_cleanup_removes_token() {
    local tmp_dir
    tmp_dir=$(mktemp -d)
    trap 'rm -rf "$tmp_dir"' RETURN

    # Arrange: create the token file
    touch "$tmp_dir/override.token"

    # Act: run the hook with the artifacts dir pointed at our isolated tmpdir
    local exit_code=0
    WORKFLOW_PLUGIN_ARTIFACTS_DIR="$tmp_dir" bash "$HOOK" >/dev/null 2>&1 || exit_code=$?

    # Assert: hook exited 0
    assert_eq "cleanup_exits_zero" "0" "$exit_code"

    # Assert: token file was removed
    local file_present=1
    [[ -f "$tmp_dir/override.token" ]] && file_present=0
    assert_eq "token_file_removed" "1" "$file_present"
}

# ── test_cleanup_idempotent ─────────────────────────────────────────────────
# Given no token file exists, the hook still exits 0 (rm -f is safe on absent file).
test_cleanup_idempotent() {
    local tmp_dir
    tmp_dir=$(mktemp -d)
    trap 'rm -rf "$tmp_dir"' RETURN

    # Arrange: no token file (tmp_dir is empty)

    # Act
    local exit_code=0
    WORKFLOW_PLUGIN_ARTIFACTS_DIR="$tmp_dir" bash "$HOOK" >/dev/null 2>&1 || exit_code=$?

    # Assert: hook still exits 0
    assert_eq "idempotent_exits_zero" "0" "$exit_code"
}

# ── test_single_use_cycle ───────────────────────────────────────────────────
# Write a token to $ARTIFACTS_DIR/override.token, run cleanup, assert the token
# no longer exists — confirming the single-use property.
test_single_use_cycle() {
    local tmp_dir
    tmp_dir=$(mktemp -d)
    trap 'rm -rf "$tmp_dir"' RETURN

    # Arrange: place a token as if dso commit-override had written it
    echo "override-granted" > "$tmp_dir/override.token"

    # Verify precondition
    local pre_exists=0
    [[ -f "$tmp_dir/override.token" ]] && pre_exists=1
    assert_eq "token_present_before_cleanup" "1" "$pre_exists"

    # Act
    WORKFLOW_PLUGIN_ARTIFACTS_DIR="$tmp_dir" bash "$HOOK" >/dev/null 2>&1 || true

    # Assert: token consumed — file must be gone
    local post_exists=0
    [[ -f "$tmp_dir/override.token" ]] && post_exists=1
    assert_eq "token_consumed_after_cleanup" "0" "$post_exists"
}

# Run all tests
test_cleanup_removes_token
test_cleanup_idempotent
test_single_use_cycle

print_summary
