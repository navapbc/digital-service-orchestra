#!/usr/bin/env bash
# lockpick-workflow/tests/hooks/test-checkpoint-rollback.sh
#
# Tests for hook_checkpoint_rollback() in pre-all-functions.sh:
#   (a) Rollback resets soft and removes marker when checkpoint at HEAD
#   (b) No-op when marker is absent
#   (c) Removes stale marker when HEAD does not match checkpoint label
#
# Usage: bash lockpick-workflow/tests/hooks/test-checkpoint-rollback.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

REPO_ROOT="$(git rev-parse --show-toplevel)"
PRE_ALL_FUNCTIONS="$REPO_ROOT/lockpick-workflow/hooks/lib/pre-all-functions.sh"
DEPS_SH="$REPO_ROOT/lockpick-workflow/hooks/lib/deps.sh"

source "$REPO_ROOT/lockpick-workflow/tests/lib/assert.sh"

# Temp dir cleanup on exit
_CLEANUP_DIRS=()
_cleanup() { for d in "${_CLEANUP_DIRS[@]}"; do rm -rf "$d"; done; }
trap _cleanup EXIT

# =============================================================================
# Helper: create a temp git repo with an initial commit
# =============================================================================
setup_test_repo() {
    local tmpdir
    tmpdir=$(mktemp -d)
    _CLEANUP_DIRS+=("$tmpdir")
    local realdir
    realdir=$(cd "$tmpdir" && pwd -P)

    git init -q "$realdir/repo"
    git -C "$realdir/repo" config user.email "test@test.com"
    git -C "$realdir/repo" config user.name "Test"
    echo "initial" > "$realdir/repo/README.md"
    git -C "$realdir/repo" add -A
    git -C "$realdir/repo" commit -q -m "initial commit"

    echo "$realdir/repo"
}

cleanup_test_repo() {
    rm -rf "$(dirname "$1")"
}

# =============================================================================
# TEST A: Rollback resets soft and removes marker when checkpoint commit at HEAD
# =============================================================================

test_rollback_resets_soft_and_removes_marker() {
    local TEST_DIR
    TEST_DIR=$(setup_test_repo)

    local CHECKPOINT_LABEL="checkpoint: pre-compaction auto-save"
    local MARKER_FILE=".checkpoint-pending-rollback"

    # Create a file and commit it as a checkpoint
    echo "work in progress" > "$TEST_DIR/work.py"
    echo "another file" > "$TEST_DIR/other.py"
    git -C "$TEST_DIR" add -A
    git -C "$TEST_DIR" commit -q -m "$CHECKPOINT_LABEL"

    local CHECKPOINT_SHA
    CHECKPOINT_SHA=$(git -C "$TEST_DIR" rev-parse HEAD)

    # Write the rollback marker
    echo "$CHECKPOINT_SHA" > "$TEST_DIR/$MARKER_FILE"

    # Record pre-rollback state: files in checkpoint commit
    local FILES_IN_CHECKPOINT
    FILES_IN_CHECKPOINT=$(git -C "$TEST_DIR" diff-tree --no-commit-id --name-only -r HEAD)

    # Run the rollback hook
    (
        cd "$TEST_DIR"
        # Source deps for parse_json_field etc.
        source "$DEPS_SH"
        # Source the function library
        source "$PRE_ALL_FUNCTIONS"
        # Call the rollback function (it takes JSON input but ignores it for rollback)
        hook_checkpoint_rollback '{}' 2>/dev/null
    )
    local EXIT_CODE=$?

    # Assert: exit code is 0
    assert_eq "test_rollback_exit_code" "0" "$EXIT_CODE"

    # Assert: HEAD moved back (checkpoint commit unwound)
    local NEW_HEAD
    NEW_HEAD=$(git -C "$TEST_DIR" rev-parse HEAD)
    assert_ne "test_rollback_head_moved" "$CHECKPOINT_SHA" "$NEW_HEAD"

    # Assert: marker file removed
    if [[ ! -f "$TEST_DIR/$MARKER_FILE" ]]; then
        (( ++PASS ))
    else
        (( ++FAIL ))
        printf "FAIL: test_rollback_marker_removed\n  marker file still exists\n" >&2
    fi

    # Assert: files from checkpoint are staged (git reset --soft preserves staging)
    local STAGED_FILES
    STAGED_FILES=$(git -C "$TEST_DIR" diff --cached --name-only)
    for f in $FILES_IN_CHECKPOINT; do
        if echo "$STAGED_FILES" | grep -q "^${f}$"; then
            (( ++PASS ))
        else
            (( ++FAIL ))
            printf "FAIL: test_rollback_file_staged_%s\n  file '%s' not in staging area\n  staged: %s\n" "$f" "$f" "$STAGED_FILES" >&2
        fi
    done

    cleanup_test_repo "$TEST_DIR"
}

test_rollback_resets_soft_and_removes_marker

# =============================================================================
# TEST B: No-op when marker is absent
# =============================================================================

test_rollback_noop_when_no_marker() {
    local TEST_DIR
    TEST_DIR=$(setup_test_repo)

    local ORIGINAL_HEAD
    ORIGINAL_HEAD=$(git -C "$TEST_DIR" rev-parse HEAD)

    # Run the rollback hook (no marker file exists)
    (
        cd "$TEST_DIR"
        source "$DEPS_SH"
        source "$PRE_ALL_FUNCTIONS"
        hook_checkpoint_rollback '{}' 2>/dev/null
    )
    local EXIT_CODE=$?

    # Assert: exit code is 0
    assert_eq "test_noop_exit_code" "0" "$EXIT_CODE"

    # Assert: HEAD unchanged (no git operations)
    local NEW_HEAD
    NEW_HEAD=$(git -C "$TEST_DIR" rev-parse HEAD)
    assert_eq "test_noop_head_unchanged" "$ORIGINAL_HEAD" "$NEW_HEAD"

    cleanup_test_repo "$TEST_DIR"
}

test_rollback_noop_when_no_marker

# =============================================================================
# TEST C: Removes stale marker when HEAD does not match checkpoint label
# =============================================================================

test_rollback_removes_stale_marker_when_head_not_checkpoint() {
    local TEST_DIR
    TEST_DIR=$(setup_test_repo)

    local MARKER_FILE=".checkpoint-pending-rollback"

    # Make a normal commit (not a checkpoint)
    echo "feature code" > "$TEST_DIR/feature.py"
    git -C "$TEST_DIR" add -A
    git -C "$TEST_DIR" commit -q -m "feat: add feature"

    local ORIGINAL_HEAD
    ORIGINAL_HEAD=$(git -C "$TEST_DIR" rev-parse HEAD)

    # Write a stale marker (points to HEAD but HEAD message doesn't match label)
    echo "$ORIGINAL_HEAD" > "$TEST_DIR/$MARKER_FILE"

    # Run the rollback hook
    local STDERR_OUTPUT
    STDERR_OUTPUT=$(
        cd "$TEST_DIR"
        source "$DEPS_SH"
        source "$PRE_ALL_FUNCTIONS"
        hook_checkpoint_rollback '{}' 2>&1 1>/dev/null
    )
    local EXIT_CODE=$?

    # Assert: exit code is 0
    assert_eq "test_stale_exit_code" "0" "$EXIT_CODE"

    # Assert: HEAD unchanged (no reset)
    local NEW_HEAD
    NEW_HEAD=$(git -C "$TEST_DIR" rev-parse HEAD)
    assert_eq "test_stale_head_unchanged" "$ORIGINAL_HEAD" "$NEW_HEAD"

    # Assert: stale marker removed
    if [[ ! -f "$TEST_DIR/$MARKER_FILE" ]]; then
        (( ++PASS ))
    else
        (( ++FAIL ))
        printf "FAIL: test_stale_marker_removed\n  stale marker file still exists\n" >&2
    fi

    # Assert: warning logged to stderr
    assert_contains "test_stale_warning_logged" "Stale marker removed" "$STDERR_OUTPUT"

    cleanup_test_repo "$TEST_DIR"
}

test_rollback_removes_stale_marker_when_head_not_checkpoint

print_summary
