#!/usr/bin/env bash
# tests/hooks/test-pre-compact-checkpoint-skip.sh
# Tests for the "skip commit when no real changes" fix in
# hooks/pre-compact-checkpoint.sh.
#
# Covers three behaviors:
#   1. No real changes → skip commit entirely; sentinel NOT written to HEAD
#   2. Real changes exist → commit created; sentinel committed alongside code
#   3. Staged sentinel deletion preserved when real changes also exist
#
# Usage: bash tests/hooks/test-pre-compact-checkpoint-skip.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
REPO_ROOT="$(git rev-parse --show-toplevel)"
HOOK="$PLUGIN_ROOT/hooks/pre-compact-checkpoint.sh"
DEPS_SH="$PLUGIN_ROOT/hooks/lib/deps.sh"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

# ── Helper: get_artifacts_dir for a given repo path ──────────────────────────
get_test_artifacts_dir() {
    local repo_dir="$1"
    (cd "$repo_dir" && bash -c 'source "'"$DEPS_SH"'" && get_artifacts_dir' 2>/dev/null)
}

# ── Helper: run the hook inside a given temp repo ────────────────────────────
# Overrides get_artifacts_dir via _DEPS_LOADED guard so the hook uses a
# controlled artifacts dir (same pattern as test-checkpoint-sentinel.sh).
run_hook_in_repo() {
    local repo_dir="$1"
    local artifacts_dir="$2"
    (
        cd "$repo_dir"
        export _DEPS_LOADED=1
        get_artifacts_dir() { echo "$artifacts_dir"; }
        export -f get_artifacts_dir
        bash "$HOOK" 2>/dev/null
    ) || true
}

# =============================================================================
# Test 1: test_pre_compact_skips_commit_when_no_real_changes
#
# When the working tree has no real changes (only possibly .tickets/ files),
# the hook must not create a new commit and must not write the sentinel to HEAD.
#
# NOTE: This test currently fails (RED phase) due to a bug in the hook's
# _HAS_REAL_CHANGES detection. On macOS, `grep -c '.' || echo 0` produces
# "0\n0" when there are no matches (grep exits 1, outputs "0", then echo 0 appends
# another "0"), causing the arithmetic check `[[ "0\n0" -eq 0 ]]` to error.
# The ERR trap silently exits 0 and the else branch fires, creating a spurious
# checkpoint commit even with a clean working tree.
# Fix: replace `grep -c '.' || echo 0` with `grep -c '.' 2>/dev/null; true`.
# =============================================================================

TEST_GIT_1=$(mktemp -d)
TEST_ARTIFACTS_1=$(mktemp -d)
trap 'rm -rf "$TEST_GIT_1" "$TEST_ARTIFACTS_1"' EXIT

(
    cd "$TEST_GIT_1"
    git init -q -b main
    git config user.email "test@test.com"
    git config user.name "Test"
    echo "initial" > README.md
    git add README.md
    git commit -q -m "init"
    # Clean working tree — nothing uncommitted
) 2>/dev/null

HEAD_BEFORE_1=$(cd "$TEST_GIT_1" && git rev-parse HEAD 2>/dev/null)

run_hook_in_repo "$TEST_GIT_1" "$TEST_ARTIFACTS_1"

HEAD_AFTER_1=$(cd "$TEST_GIT_1" && git rev-parse HEAD 2>/dev/null)
HEAD_MSG_1=$(cd "$TEST_GIT_1" && git log -1 --format="%s" 2>/dev/null)
SENTINEL_IN_HEAD_1=$(cd "$TEST_GIT_1" && git cat-file -e "HEAD:.checkpoint-needs-review" 2>/dev/null && echo "yes" || echo "no")

# Assert: no new commit was created (HEAD SHA unchanged)
assert_eq "test_pre_compact_skips_commit_when_no_real_changes (HEAD unchanged)" \
    "$HEAD_BEFORE_1" "$HEAD_AFTER_1"

# Assert: HEAD commit message does NOT contain "pre-compaction"
if [[ "$HEAD_MSG_1" != *"pre-compaction"* ]]; then
    (( ++PASS ))
else
    (( ++FAIL ))
    printf "FAIL: test_pre_compact_skips_commit_when_no_real_changes (no checkpoint commit)\n  HEAD message: %s\n" "$HEAD_MSG_1" >&2
fi

# Assert: .checkpoint-needs-review does NOT exist in HEAD
assert_eq "test_pre_compact_skips_commit_when_no_real_changes (sentinel not in HEAD)" \
    "no" "$SENTINEL_IN_HEAD_1"

rm -rf "$TEST_GIT_1" "$TEST_ARTIFACTS_1"
trap - EXIT

# =============================================================================
# Test 2: test_pre_compact_commits_when_real_changes_exist
#
# When a real file has uncommitted changes, the hook must create a checkpoint
# commit, and both .checkpoint-needs-review and the changed file must be in HEAD.
# =============================================================================

TEST_GIT_2=$(mktemp -d)
TEST_ARTIFACTS_2=$(mktemp -d)
trap 'rm -rf "$TEST_GIT_2" "$TEST_ARTIFACTS_2"' EXIT

(
    cd "$TEST_GIT_2"
    git init -q -b main
    git config user.email "test@test.com"
    git config user.name "Test"
    echo "initial" > README.md
    git add README.md
    git commit -q -m "init"
    # Stage a real code change
    echo "x" > feature.py
    git add feature.py
) 2>/dev/null

run_hook_in_repo "$TEST_GIT_2" "$TEST_ARTIFACTS_2"

HEAD_MSG_2=$(cd "$TEST_GIT_2" && git log -1 --format="%s" 2>/dev/null)
SENTINEL_IN_HEAD_2=$(cd "$TEST_GIT_2" && git cat-file -e "HEAD:.checkpoint-needs-review" 2>/dev/null && echo "yes" || echo "no")
FEATURE_IN_HEAD_2=$(cd "$TEST_GIT_2" && git cat-file -e "HEAD:feature.py" 2>/dev/null && echo "yes" || echo "no")

# Assert: HEAD commit message contains "pre-compaction auto-save"
assert_contains "test_pre_compact_commits_when_real_changes_exist (commit message)" \
    "pre-compaction auto-save" "$HEAD_MSG_2"

# Assert: .checkpoint-needs-review IS in HEAD
assert_eq "test_pre_compact_commits_when_real_changes_exist (sentinel in HEAD)" \
    "yes" "$SENTINEL_IN_HEAD_2"

# Assert: feature.py IS in HEAD
assert_eq "test_pre_compact_commits_when_real_changes_exist (real file in HEAD)" \
    "yes" "$FEATURE_IN_HEAD_2"

rm -rf "$TEST_GIT_2" "$TEST_ARTIFACTS_2"
trap - EXIT

# =============================================================================
# Test 3: test_pre_compact_preserves_staged_sentinel_deletion
#
# When .checkpoint-needs-review is tracked in HEAD (from a prior checkpoint)
# and has been staged for deletion (as record-review.sh would do), and real
# code changes also exist, the hook must NOT re-stage the sentinel.
# After the hook runs, the index must still show the sentinel as deleted.
# =============================================================================

TEST_GIT_3=$(mktemp -d)
TEST_ARTIFACTS_3=$(mktemp -d)
trap 'rm -rf "$TEST_GIT_3" "$TEST_ARTIFACTS_3"' EXIT

(
    cd "$TEST_GIT_3"
    git init -q -b main
    git config user.email "test@test.com"
    git config user.name "Test"
    echo "initial" > README.md
    git add README.md
    git commit -q -m "init"
    # Simulate a prior checkpoint: commit the sentinel
    echo "priornonce123" > .checkpoint-needs-review
    echo "some code" > src.py
    git add .checkpoint-needs-review src.py
    git commit -q -m "checkpoint: pre-compaction auto-save"
    # Simulate record-review.sh having staged the sentinel deletion
    git rm --cached .checkpoint-needs-review
    # Also stage a real uncommitted code change so the "has real changes" check passes
    echo "new work" >> src.py
    git add src.py
) 2>/dev/null

run_hook_in_repo "$TEST_GIT_3" "$TEST_ARTIFACTS_3"

# After the hook runs and commits, the staged deletion should have been COMMITTED
# (not overridden by a re-add). Verify that .checkpoint-needs-review is NOT tracked
# in the new HEAD — the deletion was preserved through the commit, not undone.
#
# We check: git cat-file -e HEAD:.checkpoint-needs-review exits non-zero (file absent from HEAD).
SENTINEL_IN_HEAD_3=$(cd "$TEST_GIT_3" && git cat-file -e "HEAD:.checkpoint-needs-review" 2>/dev/null && echo "yes" || echo "no")

assert_eq "test_pre_compact_preserves_staged_sentinel_deletion (sentinel absent from HEAD)" \
    "no" "$SENTINEL_IN_HEAD_3"

# Also verify that the checkpoint commit was still created (real changes were captured).
HEAD_MSG_3=$(cd "$TEST_GIT_3" && git log -1 --format="%s" 2>/dev/null)
assert_contains "test_pre_compact_preserves_staged_sentinel_deletion (commit created)" \
    "pre-compaction auto-save" "$HEAD_MSG_3"

rm -rf "$TEST_GIT_3" "$TEST_ARTIFACTS_3"
trap - EXIT

print_summary
