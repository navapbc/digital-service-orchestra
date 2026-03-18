#!/usr/bin/env bash
# tests/hooks/test-state-dir-migration.sh
# RED PHASE tests for get_artifacts_dir() in hooks/lib/deps.sh
#
# These tests MUST FAIL until get_artifacts_dir() is implemented.
# Once the function exists (task j46vp.3.2), these tests should all PASS.
#
# Tests:
#   test_artifacts_dir_uses_workflow_plugin_hash
#   test_artifacts_dir_backward_compat_fallback
#   test_artifacts_dir_migration_is_idempotent

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DSO_PLUGIN_DIR="$PLUGIN_ROOT/plugins/dso"
REPO_ROOT="$(git rev-parse --show-toplevel)"
DEPS="$DSO_PLUGIN_DIR/hooks/lib/deps.sh"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

# Temporary directory for test isolation
TEST_TMP=$(mktemp -d)
cleanup() {
    rm -rf "$TEST_TMP"
}
trap cleanup EXIT

# Helper: compute the hash suffix that get_artifacts_dir() should use
# (same logic as the expected implementation: shasum/sha256sum/md5 of REPO_ROOT)
compute_expected_hash() {
    local root="$1"
    local hash
    if command -v shasum &>/dev/null; then
        hash=$(echo -n "$root" | shasum -a 256 | awk '{print $1}' | head -c 16)
    elif command -v sha256sum &>/dev/null; then
        hash=$(echo -n "$root" | sha256sum | awk '{print $1}' | head -c 16)
    elif command -v md5 &>/dev/null; then
        hash=$(echo -n "$root" | md5 | head -c 16)
    elif command -v md5sum &>/dev/null; then
        hash=$(echo -n "$root" | md5sum | awk '{print $1}' | head -c 16)
    else
        hash=$(echo -n "$root" | cksum | awk '{print $1}')
    fi
    echo "$hash"
}

# ============================================================
# test_artifacts_dir_uses_workflow_plugin_hash
#
# After sourcing deps.sh, call get_artifacts_dir() with REPO_ROOT set
# to a tmp directory. Assert that the returned path:
#   1. Contains '/tmp/workflow-plugin-' (new naming scheme)
#   2. Does NOT contain '/tmp/lockpick-test-artifacts-' (old naming scheme)
#
# MUST FAIL — function does not yet exist.
# ============================================================

# Create a fake REPO_ROOT for this test so it doesn't collide with real state
FAKE_REPO_ROOT="$TEST_TMP/fake-repo"
mkdir -p "$FAKE_REPO_ROOT"

# Source deps.sh with the fake REPO_ROOT set
ARTIFACTS_DIR_RESULT=""
GET_ARTIFACTS_DIR_EXIT=0
(
    export REPO_ROOT="$FAKE_REPO_ROOT"
    source "$DEPS"
    ARTIFACTS_DIR_RESULT=$(get_artifacts_dir 2>/dev/null)
    echo "$ARTIFACTS_DIR_RESULT"
) > "$TEST_TMP/artifacts_dir_output.txt" 2>/dev/null || GET_ARTIFACTS_DIR_EXIT=$?

ARTIFACTS_DIR_RESULT=$(cat "$TEST_TMP/artifacts_dir_output.txt" 2>/dev/null || echo "")

# Assertion 1: output contains /tmp/workflow-plugin-
assert_contains \
    "test_artifacts_dir_uses_workflow_plugin_hash: output contains /tmp/workflow-plugin-" \
    "/tmp/workflow-plugin-" \
    "$ARTIFACTS_DIR_RESULT"

# Assertion 2: output does NOT contain /tmp/lockpick-test-artifacts-
OLD_PREFIX_FOUND="no"
if [[ "$ARTIFACTS_DIR_RESULT" == */tmp/lockpick-test-artifacts-* ]]; then
    OLD_PREFIX_FOUND="yes"
fi
assert_eq \
    "test_artifacts_dir_uses_workflow_plugin_hash: output does not use old prefix" \
    "no" \
    "$OLD_PREFIX_FOUND"

# ============================================================
# test_artifacts_dir_backward_compat_fallback
#
# Setup: Create an old-style artifacts dir (/tmp/lockpick-test-artifacts-<worktree>/)
#        with a dummy status file. Set REPO_ROOT so get_artifacts_dir() computes
#        a new hash path with NO files at the new path.
#
# Action: Call get_artifacts_dir().
#
# Assert: The new path now contains the status file (migration occurred).
#
# MUST FAIL — function does not yet exist.
# ============================================================

FAKE_REPO2="$TEST_TMP/fake-repo-2"
mkdir -p "$FAKE_REPO2"

FAKE_WORKTREE_NAME="fake-repo-2"
OLD_ARTIFACTS_DIR="/tmp/lockpick-test-artifacts-${FAKE_WORKTREE_NAME}"

# Create old-style artifacts dir with a dummy status file
mkdir -p "$OLD_ARTIFACTS_DIR"
echo "passed" > "$OLD_ARTIFACTS_DIR/status"

# Compute what the new path should be
EXPECTED_HASH=$(compute_expected_hash "$FAKE_REPO2")
NEW_ARTIFACTS_DIR="/tmp/workflow-plugin-${EXPECTED_HASH}"

# Ensure new path does NOT exist before the call
rm -rf "$NEW_ARTIFACTS_DIR" 2>/dev/null || true

# Call get_artifacts_dir() in a subshell
(
    export REPO_ROOT="$FAKE_REPO2"
    source "$DEPS"
    get_artifacts_dir 2>/dev/null
) > "$TEST_TMP/migration_output.txt" 2>/dev/null || true

# Assert: new path exists and has the status file (migration happened)
NEW_STATUS_PRESENT="no"
if [[ -f "$NEW_ARTIFACTS_DIR/status" ]]; then
    NEW_STATUS_PRESENT="yes"
fi
assert_eq \
    "test_artifacts_dir_backward_compat_fallback: status file migrated to new path" \
    "yes" \
    "$NEW_STATUS_PRESENT"

# Cleanup old artifacts dir we created
rm -rf "$OLD_ARTIFACTS_DIR" 2>/dev/null || true
rm -rf "$NEW_ARTIFACTS_DIR" 2>/dev/null || true

# ============================================================
# test_artifacts_dir_migration_is_idempotent
#
# Setup: Create old-style dir AND new-style dir (both with files).
# Action: Call get_artifacts_dir() twice.
# Assert: file count in new path is identical after both calls (no duplication).
#
# MUST FAIL — function does not yet exist.
# ============================================================

FAKE_REPO3="$TEST_TMP/fake-repo-3"
mkdir -p "$FAKE_REPO3"

FAKE_WORKTREE_NAME3="fake-repo-3"
OLD_ARTIFACTS_DIR3="/tmp/lockpick-test-artifacts-${FAKE_WORKTREE_NAME3}"

# Create old-style dir with two dummy files
mkdir -p "$OLD_ARTIFACTS_DIR3"
echo "passed" > "$OLD_ARTIFACTS_DIR3/status"
echo "review-ok" > "$OLD_ARTIFACTS_DIR3/review-status"

# Compute new path
EXPECTED_HASH3=$(compute_expected_hash "$FAKE_REPO3")
NEW_ARTIFACTS_DIR3="/tmp/workflow-plugin-${EXPECTED_HASH3}"
rm -rf "$NEW_ARTIFACTS_DIR3" 2>/dev/null || true

# First call
(
    export REPO_ROOT="$FAKE_REPO3"
    source "$DEPS"
    get_artifacts_dir 2>/dev/null
) > /dev/null 2>/dev/null || true

# Count files after first call
FILE_COUNT_AFTER_FIRST=$(ls "$NEW_ARTIFACTS_DIR3" 2>/dev/null | wc -l | tr -d ' ' || echo "0")

# Second call
(
    export REPO_ROOT="$FAKE_REPO3"
    source "$DEPS"
    get_artifacts_dir 2>/dev/null
) > /dev/null 2>/dev/null || true

# Count files after second call
FILE_COUNT_AFTER_SECOND=$(ls "$NEW_ARTIFACTS_DIR3" 2>/dev/null | wc -l | tr -d ' ' || echo "0")

# Assert: same count after both calls (idempotent)
assert_eq \
    "test_artifacts_dir_migration_is_idempotent: file count unchanged after second call" \
    "$FILE_COUNT_AFTER_FIRST" \
    "$FILE_COUNT_AFTER_SECOND"

# Also assert: at least one file was migrated (so first call did something)
assert_ne \
    "test_artifacts_dir_migration_is_idempotent: new dir is non-empty after first call" \
    "0" \
    "$FILE_COUNT_AFTER_FIRST"

# Cleanup
rm -rf "$OLD_ARTIFACTS_DIR3" 2>/dev/null || true
rm -rf "$NEW_ARTIFACTS_DIR3" 2>/dev/null || true

# ============================================================
# Summary
# ============================================================
print_summary
