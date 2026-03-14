#!/usr/bin/env bash
# lockpick-workflow/tests/hooks/test-checkpoint-merge-gate-fallback.sh
#
# Integration test: merge gate fallback when session terminates before rollback.
#
# Scenario:
#   1. pre-compact-checkpoint.sh fires (creates checkpoint commit + sentinel)
#   2. Session dies before rollback hook can unwind the checkpoint
#   3. merge-to-main.sh must BLOCK because .checkpoint-needs-review sentinel
#      remains committed (never deleted via /review + /commit)
#
# This validates the safety net: even if the rollback hook never runs,
# the merge gate catches the unreviewed checkpoint.
#
# Usage: bash lockpick-workflow/tests/hooks/test-checkpoint-merge-gate-fallback.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

REPO_ROOT="$(git rev-parse --show-toplevel)"
COMPACT_HOOK="$REPO_ROOT/lockpick-workflow/hooks/pre-compact-checkpoint.sh"
MERGE_SCRIPT="$REPO_ROOT/scripts/merge-to-main.sh"
DEPS_SH="$REPO_ROOT/lockpick-workflow/hooks/lib/deps.sh"

source "$REPO_ROOT/lockpick-workflow/tests/lib/assert.sh"

# Temp dir cleanup on exit
_CLEANUP_DIRS=()
_cleanup() { for d in "${_CLEANUP_DIRS[@]}"; do rm -rf "$d"; done; }
trap _cleanup EXIT

# ── Helper: minimal ticket file ───────────────────────────────────────────────
make_ticket_file() {
    local dir="$1" id="$2"
    mkdir -p "$dir/.tickets"
    cat > "$dir/.tickets/${id}.md" <<EOF
---
id: $id
status: open
deps: []
links: []
created: 2026-01-01T00:00:00Z
type: task
priority: 2
---
# Ticket $id
EOF
}

# ── Helper: set up a full merge-to-main test environment ─────────────────────
# Creates: bare repo (origin), main-clone, and worktree on feature-branch
setup_merge_env() {
    local tmpdir
    tmpdir=$(mktemp -d)
    _CLEANUP_DIRS+=("$tmpdir")
    local REALENV
    REALENV=$(cd "$tmpdir" && pwd -P)

    git init -q -b main "$REALENV/seed"
    git -C "$REALENV/seed" config user.email "test@test.com"
    git -C "$REALENV/seed" config user.name "Test"
    echo "initial" > "$REALENV/seed/README.md"
    # Add .gitignore matching real repo (checkpoint-pending-rollback is working-tree only)
    echo ".checkpoint-pending-rollback" > "$REALENV/seed/.gitignore"
    make_ticket_file "$REALENV/seed" "seed-init"
    git -C "$REALENV/seed" add -A
    git -C "$REALENV/seed" commit -q -m "init"

    git clone --bare -q "$REALENV/seed" "$REALENV/bare.git"
    git clone -q "$REALENV/bare.git" "$REALENV/main-clone"
    git -C "$REALENV/main-clone" config user.email "test@test.com"
    git -C "$REALENV/main-clone" config user.name "Test"

    git -C "$REALENV/main-clone" branch feature-branch 2>/dev/null || true
    git -C "$REALENV/main-clone" worktree add -q "$REALENV/worktree" feature-branch 2>/dev/null
    git -C "$REALENV/worktree" config user.email "test@test.com"
    git -C "$REALENV/worktree" config user.name "Test"

    echo "$REALENV"
}

cleanup_env() {
    local env_dir="$1"
    git -C "$env_dir/main-clone" worktree remove --force "$env_dir/worktree" 2>/dev/null || true
    rm -rf "$env_dir"
}

# =============================================================================
# TEST: Merge blocked when rollback not run (session termination scenario)
#
# This simulates a session that:
#   1. Had uncommitted work when compaction occurred
#   2. pre-compact-checkpoint.sh created a checkpoint commit with the
#      .checkpoint-needs-review sentinel
#   3. The session terminated (crashed, timed out, etc.) BEFORE the
#      rollback hook could unwind the checkpoint
#   4. A subsequent merge-to-main.sh attempt must be blocked
# =============================================================================

test_merge_blocked_when_rollback_not_run() {
    local TMPENV
    TMPENV=$(setup_merge_env)
    local WT
    WT=$(cd "$TMPENV/worktree" && pwd -P)

    # Step 1: Create uncommitted work in the worktree (simulating in-progress session)
    echo "feature code in progress" > "$WT/feature.py"

    # Step 2: Run pre-compact-checkpoint.sh
    # This simulates compaction firing: it stages all work, writes the
    # .checkpoint-needs-review sentinel with a nonce, and creates a checkpoint commit.
    # We override get_artifacts_dir and disable the dedup lock.
    local TEST_ARTIFACTS
    TEST_ARTIFACTS=$(mktemp -d)
    _CLEANUP_DIRS+=("$TEST_ARTIFACTS")
    (
        cd "$WT"
        export _DEPS_LOADED=1
        get_artifacts_dir() { echo "$TEST_ARTIFACTS"; }
        export -f get_artifacts_dir
        # Clear the dedup lock so the hook runs
        rm -f "${TMPDIR:-/tmp}/.precompact-lock-"* 2>/dev/null || true
        bash "$COMPACT_HOOK" 2>/dev/null
    ) || true

    # Verify the checkpoint commit was created with the sentinel
    local SENTINEL_IN_TREE
    SENTINEL_IN_TREE=$(cd "$WT" && git show HEAD:.checkpoint-needs-review 2>/dev/null || true)
    assert_ne "test_sentinel_was_committed" "" "$SENTINEL_IN_TREE"

    # Step 3: DO NOT run rollback — simulating session death.
    # The .checkpoint-needs-review sentinel remains committed.
    # The .checkpoint-pending-rollback marker exists in working tree but is irrelevant
    # to the merge gate (it checks git history, not working tree files).

    # Step 4: Attempt merge-to-main.sh — should be BLOCKED
    local MERGE_OUTPUT
    MERGE_OUTPUT=$(cd "$WT" && unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE && \
        bash "$MERGE_SCRIPT" 2>&1 || true)

    # Assert: merge was blocked with "Unreviewed checkpoint" message
    assert_contains "test_merge_blocked_when_rollback_not_run" \
        "Unreviewed checkpoint" "$MERGE_OUTPUT"

    # Assert: the error message mentions the checkpoint commit
    # (merge-to-main.sh includes the commit SHA in the error)
    local HAS_COMMIT_REF
    HAS_COMMIT_REF=$(echo "$MERGE_OUTPUT" | grep "Checkpoint commit:" | head -1 || true)
    assert_ne "test_merge_error_references_checkpoint_commit" "" "$HAS_COMMIT_REF"

    # Cleanup
    rm -rf "$TEST_ARTIFACTS"
    cleanup_env "$TMPENV"
}

test_merge_blocked_when_rollback_not_run

# =============================================================================
# TEST: Merge blocked even when additional commits follow the checkpoint
#
# Verifies that the merge gate is not fooled by subsequent commits that
# don't clear the sentinel. The sentinel ADD is still the most recent
# and has no corresponding DELETE.
# =============================================================================

test_merge_blocked_with_post_checkpoint_commits() {
    local TMPENV
    TMPENV=$(setup_merge_env)
    local WT
    WT=$(cd "$TMPENV/worktree" && pwd -P)

    # Create checkpoint commit with sentinel (manually, for control)
    echo "feature code" > "$WT/feature.py"
    echo "testnonce_fallback_abc" > "$WT/.checkpoint-needs-review"
    (cd "$WT" && git add feature.py .checkpoint-needs-review && \
        git commit -q -m "checkpoint: pre-compaction auto-save") 2>/dev/null

    # Additional commit AFTER checkpoint (simulating resumed work that
    # never went through /review + /commit to clear the sentinel)
    echo "more work" >> "$WT/feature.py"
    (cd "$WT" && git add feature.py && \
        git commit -q -m "feat: continued work after compaction") 2>/dev/null

    # Attempt merge — should still be blocked
    local MERGE_OUTPUT
    MERGE_OUTPUT=$(cd "$WT" && unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE && \
        bash "$MERGE_SCRIPT" 2>&1 || true)

    assert_contains "test_merge_blocked_with_post_checkpoint_commits" \
        "Unreviewed checkpoint" "$MERGE_OUTPUT"

    cleanup_env "$TMPENV"
}

test_merge_blocked_with_post_checkpoint_commits

# =============================================================================
# TEST: Merge allowed after sentinel is properly cleared
#
# Contrast case: when the sentinel IS deleted (simulating successful
# /review + /commit), merge should succeed. This ensures the test
# environment is correct and the gate logic works bidirectionally.
# =============================================================================

test_merge_allowed_after_sentinel_cleared() {
    local TMPENV
    TMPENV=$(setup_merge_env)
    local WT
    WT=$(cd "$TMPENV/worktree" && pwd -P)

    # Create checkpoint commit with sentinel
    echo "feature code" > "$WT/feature.py"
    echo "testnonce_cleared_xyz" > "$WT/.checkpoint-needs-review"
    (cd "$WT" && git add feature.py .checkpoint-needs-review && \
        git commit -q -m "checkpoint: pre-compaction auto-save") 2>/dev/null

    # Delete sentinel (simulating /review + /commit clearing it)
    (cd "$WT" && git rm -q .checkpoint-needs-review && \
        git commit -q -m "review: cleared checkpoint sentinel") 2>/dev/null

    # Attempt merge — should succeed
    local MERGE_OUTPUT
    MERGE_OUTPUT=$(cd "$WT" && unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE && \
        bash "$MERGE_SCRIPT" 2>&1 || true)

    # Should NOT contain "Unreviewed checkpoint"
    local BLOCKED
    BLOCKED=$(echo "$MERGE_OUTPUT" | grep "Unreviewed checkpoint" | head -1 || true)
    if [[ -z "$BLOCKED" ]]; then
        (( ++PASS ))
    else
        (( ++FAIL ))
        printf "FAIL: test_merge_allowed_after_sentinel_cleared\n  unexpected block: %s\n" "$BLOCKED" >&2
    fi

    cleanup_env "$TMPENV"
}

test_merge_allowed_after_sentinel_cleared

print_summary
