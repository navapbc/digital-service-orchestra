#!/usr/bin/env bash
# lockpick-workflow/tests/hooks/test-checkpoint-rollback-integration.sh
#
# Integration tests for the full checkpoint -> rollback cycle:
#   (a) Happy path: pre-compact-checkpoint.sh creates checkpoint commit + marker,
#       then hook_checkpoint_rollback() unwinds it (no checkpoint at HEAD,
#       changes staged, marker removed)
#   (b) No-op when no changes: clean working tree -> checkpoint hook skips commit,
#       rollback hook is a no-op
#   (c) No-op rollback without marker: checkpoint commit at HEAD but no marker file
#       -> rollback does nothing
#
# Usage: bash lockpick-workflow/tests/hooks/test-checkpoint-rollback-integration.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

REPO_ROOT="$(git rev-parse --show-toplevel)"
CHECKPOINT_HOOK="$REPO_ROOT/lockpick-workflow/hooks/pre-compact-checkpoint.sh"
PRE_ALL_FUNCTIONS="$REPO_ROOT/lockpick-workflow/hooks/lib/pre-all-functions.sh"
DEPS_SH="$REPO_ROOT/lockpick-workflow/hooks/lib/deps.sh"

source "$REPO_ROOT/lockpick-workflow/tests/lib/assert.sh"

# Temp dir cleanup on exit
_CLEANUP_DIRS=()
_cleanup() { for d in "${_CLEANUP_DIRS[@]}"; do rm -rf "$d"; done; }
trap _cleanup EXIT

CHECKPOINT_LABEL="checkpoint: pre-compaction auto-save"
MARKER_FILE=".checkpoint-pending-rollback"

# =============================================================================
# Helper: create a temp git repo with workflow-config.conf and initial commit
# =============================================================================
setup_test_repo() {
    local tmpdir
    tmpdir=$(mktemp -d)
    _CLEANUP_DIRS+=("$tmpdir")
    local realdir
    realdir=$(cd "$tmpdir" && pwd -P)

    git init -q -b main "$realdir/repo"
    git -C "$realdir/repo" config user.email "test@test.com"
    git -C "$realdir/repo" config user.name "Test"

    # Create workflow-config.conf so read-config.sh can find defaults
    cat > "$realdir/repo/workflow-config.conf" <<'CONF'
checkpoint.commit_label=checkpoint: pre-compaction auto-save
checkpoint.marker_file=.checkpoint-pending-rollback
CONF

    # .gitignore the marker file (as in production)
    echo "$MARKER_FILE" > "$realdir/repo/.gitignore"

    echo "initial" > "$realdir/repo/README.md"
    git -C "$realdir/repo" add -A
    git -C "$realdir/repo" commit -q -m "initial commit"

    echo "$realdir/repo"
}

cleanup_test_repo() {
    rm -rf "$(dirname "$1")"
}

# =============================================================================
# TEST A: Full cycle — checkpoint then rollback (happy path)
# =============================================================================

test_full_cycle_checkpoint_then_rollback() {
    local TEST_DIR
    TEST_DIR=$(setup_test_repo)

    # Create uncommitted work
    echo "work in progress" > "$TEST_DIR/work.py"
    echo "more stuff" > "$TEST_DIR/other.py"
    git -C "$TEST_DIR" add -A

    local PRE_CHECKPOINT_HEAD
    PRE_CHECKPOINT_HEAD=$(git -C "$TEST_DIR" rev-parse HEAD)

    # --- Run pre-compact-checkpoint.sh to create checkpoint commit + marker ---
    (
        cd "$TEST_DIR"
        # Disable dedup lock + telemetry side effects; provide deps.sh override
        export LOCKPICK_DISABLE_PRECOMPACT=""
        bash "$CHECKPOINT_HOOK" 2>/dev/null
    ) >/dev/null

    local POST_CHECKPOINT_HEAD
    POST_CHECKPOINT_HEAD=$(git -C "$TEST_DIR" rev-parse HEAD)

    # Verify checkpoint commit was created
    assert_ne "checkpoint_created_new_commit" "$PRE_CHECKPOINT_HEAD" "$POST_CHECKPOINT_HEAD"

    # Verify checkpoint commit message
    local HEAD_MSG
    HEAD_MSG=$(git -C "$TEST_DIR" log -1 --format=%s)
    assert_eq "checkpoint_commit_message" "$CHECKPOINT_LABEL" "$HEAD_MSG"

    # Verify marker file was written
    if [[ -f "$TEST_DIR/$MARKER_FILE" ]]; then
        (( ++PASS ))
    else
        (( ++FAIL ))
        printf "FAIL: checkpoint_marker_written\n  marker file not found at %s/%s\n" "$TEST_DIR" "$MARKER_FILE" >&2
    fi

    # --- Run rollback (simulating first post-compaction tool call) ---
    (
        cd "$TEST_DIR"
        source "$DEPS_SH"
        # Reset load guard so pre-all-functions.sh can source
        _PRE_ALL_FUNCTIONS_LOADED=0
        source "$PRE_ALL_FUNCTIONS"
        hook_checkpoint_rollback '{}' 2>/dev/null
    )

    # VERIFY 1: No checkpoint commit at HEAD (HEAD should be back to pre-checkpoint)
    local POST_ROLLBACK_HEAD
    POST_ROLLBACK_HEAD=$(git -C "$TEST_DIR" rev-parse HEAD)
    assert_eq "no_checkpoint_at_head" "$PRE_CHECKPOINT_HEAD" "$POST_ROLLBACK_HEAD"

    # VERIFY 2: All changes are staged (git diff --cached shows the files)
    local STAGED_FILES
    STAGED_FILES=$(git -C "$TEST_DIR" diff --cached --name-only | sort)
    if echo "$STAGED_FILES" | grep -q "work.py"; then
        (( ++PASS ))
    else
        (( ++FAIL ))
        printf "FAIL: work_py_staged\n  expected work.py in staged files\n  staged: %s\n" "$STAGED_FILES" >&2
    fi
    if echo "$STAGED_FILES" | grep -q "other.py"; then
        (( ++PASS ))
    else
        (( ++FAIL ))
        printf "FAIL: other_py_staged\n  expected other.py in staged files\n  staged: %s\n" "$STAGED_FILES" >&2
    fi

    # VERIFY 3: Marker file removed
    if [[ ! -f "$TEST_DIR/$MARKER_FILE" ]]; then
        (( ++PASS ))
    else
        (( ++FAIL ))
        printf "FAIL: marker_removed_after_rollback\n  marker file still exists\n" >&2
    fi

    cleanup_test_repo "$TEST_DIR"
}

test_full_cycle_checkpoint_then_rollback

# =============================================================================
# TEST B: No-op — no changes, no marker
# =============================================================================

test_noop_no_changes_no_marker() {
    local TEST_DIR
    TEST_DIR=$(setup_test_repo)

    local ORIGINAL_HEAD
    ORIGINAL_HEAD=$(git -C "$TEST_DIR" rev-parse HEAD)

    # --- Run pre-compact-checkpoint.sh on a clean working tree ---
    (
        cd "$TEST_DIR"
        export LOCKPICK_DISABLE_PRECOMPACT=""
        bash "$CHECKPOINT_HOOK" 2>/dev/null
    ) >/dev/null

    # Verify: no new commit created (HEAD unchanged)
    local POST_HEAD
    POST_HEAD=$(git -C "$TEST_DIR" rev-parse HEAD)
    assert_eq "noop_no_new_commit" "$ORIGINAL_HEAD" "$POST_HEAD"

    # Verify: no marker file written
    if [[ ! -f "$TEST_DIR/$MARKER_FILE" ]]; then
        (( ++PASS ))
    else
        (( ++FAIL ))
        printf "FAIL: noop_no_marker_written\n  marker file should not exist on clean tree\n" >&2
    fi

    # --- Run rollback on the same clean state ---
    (
        cd "$TEST_DIR"
        source "$DEPS_SH"
        _PRE_ALL_FUNCTIONS_LOADED=0
        source "$PRE_ALL_FUNCTIONS"
        hook_checkpoint_rollback '{}' 2>/dev/null
    )
    local EXIT_CODE=$?

    # Verify: clean exit
    assert_eq "noop_rollback_exit_code" "0" "$EXIT_CODE"

    # Verify: HEAD still unchanged (no git operations)
    local FINAL_HEAD
    FINAL_HEAD=$(git -C "$TEST_DIR" rev-parse HEAD)
    assert_eq "noop_rollback_head_unchanged" "$ORIGINAL_HEAD" "$FINAL_HEAD"

    cleanup_test_repo "$TEST_DIR"
}

test_noop_no_changes_no_marker

# =============================================================================
# TEST C: No-op rollback without marker (checkpoint commit at HEAD but no marker)
# =============================================================================

test_noop_rollback_without_marker() {
    local TEST_DIR
    TEST_DIR=$(setup_test_repo)

    # Create a checkpoint-style commit manually (without the marker file)
    echo "some work" > "$TEST_DIR/feature.py"
    git -C "$TEST_DIR" add -A
    git -C "$TEST_DIR" commit -q -m "$CHECKPOINT_LABEL"

    local CHECKPOINT_HEAD
    CHECKPOINT_HEAD=$(git -C "$TEST_DIR" rev-parse HEAD)

    # Ensure no marker file exists
    rm -f "$TEST_DIR/$MARKER_FILE"

    # --- Run rollback ---
    (
        cd "$TEST_DIR"
        source "$DEPS_SH"
        _PRE_ALL_FUNCTIONS_LOADED=0
        source "$PRE_ALL_FUNCTIONS"
        hook_checkpoint_rollback '{}' 2>/dev/null
    )
    local EXIT_CODE=$?

    # Verify: clean exit
    assert_eq "no_marker_rollback_exit_code" "0" "$EXIT_CODE"

    # Verify: HEAD unchanged (no git operations without marker)
    local POST_HEAD
    POST_HEAD=$(git -C "$TEST_DIR" rev-parse HEAD)
    assert_eq "no_marker_head_unchanged" "$CHECKPOINT_HEAD" "$POST_HEAD"

    cleanup_test_repo "$TEST_DIR"
}

test_noop_rollback_without_marker

print_summary
