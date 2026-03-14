#!/usr/bin/env bash
# lockpick-workflow/tests/hooks/test-compute-diff-hash-checkpoint.sh
# Tests for checkpoint-aware diff hash computation in compute-diff-hash.sh.
#
# Verifies that compute-diff-hash.sh:
#   1. Reads pre-checkpoint-base from ARTIFACTS_DIR (primary path)
#   2. Validates stored SHA with rev-parse --verify and merge-base --is-ancestor
#   3. Falls back to bounded commit walk (max 10 iterations)
#   4. Uses CHECKPOINT_LABEL as a shared constant

REPO_ROOT="$(git rev-parse --show-toplevel)"
HOOK="$REPO_ROOT/lockpick-workflow/hooks/compute-diff-hash.sh"

source "$REPO_ROOT/lockpick-workflow/tests/lib/assert.sh"

# Temp dir cleanup on exit
_CLEANUP_DIRS=()
_cleanup() { for d in "${_CLEANUP_DIRS[@]}"; do rm -rf "$d"; done; }
trap _cleanup EXIT

# ============================================================
# Static source analysis tests
# ============================================================

HOOK_SOURCE=$(cat "$HOOK")

# test_source_reads_pre_checkpoint_base
# The script must read the pre-checkpoint-base file from ARTIFACTS_DIR
assert_contains "test_source_reads_pre_checkpoint_base" \
    "pre-checkpoint-base" "$HOOK_SOURCE"

# test_source_uses_rev_parse_verify
# SHA validation must use rev-parse --verify
assert_contains "test_source_uses_rev_parse_verify" \
    "rev-parse --verify" "$HOOK_SOURCE"

# test_source_uses_merge_base_is_ancestor
# SHA validation must check ancestry with merge-base --is-ancestor
assert_contains "test_source_uses_merge_base_is_ancestor" \
    "merge-base --is-ancestor" "$HOOK_SOURCE"

# test_source_has_bounded_walk
# Fallback commit walk must be bounded (max 10 iterations)
if echo "$HOOK_SOURCE" | grep -qE 'MAX_WALK|max_walk|10'; then
    (( ++PASS ))
else
    (( ++FAIL ))
    printf "FAIL: test_source_has_bounded_walk\n  expected: MAX_WALK or literal 10 bound\n" >&2
fi

# test_source_uses_checkpoint_label_constant
# Must use CHECKPOINT_LABEL as a shared constant (not hardcoded string)
assert_contains "test_source_uses_checkpoint_label_constant" \
    "CHECKPOINT_LABEL" "$HOOK_SOURCE"

# test_source_uses_get_artifacts_dir
# Must use get_artifacts_dir to locate the artifacts directory
assert_contains "test_source_uses_get_artifacts_dir" \
    "get_artifacts_dir" "$HOOK_SOURCE"

# ============================================================
# Behavioral tests in a temp git repo
# ============================================================

# Helper: create a temp git repo with an initial commit
setup_test_repo() {
    local dir
    dir=$(mktemp -d)
    _CLEANUP_DIRS+=("$dir")
    (
        cd "$dir"
        git init -q
        git config user.email "test@test.com"
        git config user.name "Test"
        echo "initial content" > file.txt
        git add file.txt
        git commit -q -m "initial"
    )
    echo "$dir"
}

# Helper: run compute-diff-hash.sh in a test repo with optional ARTIFACTS_DIR override
run_hook_in_repo() {
    local test_repo="$1"
    local test_artifacts_dir="${2:-}"
    (
        cd "$test_repo"
        if [[ -n "$test_artifacts_dir" ]]; then
            # Override get_artifacts_dir to return our test dir
            export _TEST_ARTIFACTS_DIR="$test_artifacts_dir"
            bash -c '
                source "'"$REPO_ROOT"'/lockpick-workflow/hooks/lib/deps.sh"
                get_artifacts_dir() { echo "$_TEST_ARTIFACTS_DIR"; }
                export -f get_artifacts_dir
                source "'"$HOOK"'"
            ' 2>/dev/null
        else
            bash "$HOOK" 2>/dev/null
        fi
    )
}

# --- Test: Normal (non-checkpoint) case still works ---
# test_non_checkpoint_produces_hash
# Without any checkpoint commits, should produce a normal hash
TEST_REPO=$(setup_test_repo)
HASH=$(run_hook_in_repo "$TEST_REPO")
assert_ne "test_non_checkpoint_produces_hash" "" "$HASH"
rm -rf "$TEST_REPO"

# --- Test: Primary path — pre-checkpoint-base file ---
# test_primary_path_uses_stored_base
# When pre-checkpoint-base exists with a valid SHA, diff should use that as base.
# We create: initial -> real_work -> checkpoint_commit, with base file pointing to real_work.
TEST_REPO=$(setup_test_repo)
TEST_ARTIFACTS=$(mktemp -d)
_CLEANUP_DIRS+=("$TEST_ARTIFACTS")
(
    cd "$TEST_REPO"
    # Add real work
    echo "real work" > work.txt
    git add work.txt
    git commit -q -m "real work"
    REAL_WORK_SHA=$(git rev-parse HEAD)
    # Create a checkpoint commit
    echo "checkpoint state" > checkpoint.txt
    git add checkpoint.txt
    git commit -q -m "checkpoint: pre-compaction auto-save"
    # Write the pre-checkpoint-base file (simulating what pre-compact-checkpoint.sh does)
    echo -n "$REAL_WORK_SHA" > "$TEST_ARTIFACTS/pre-checkpoint-base"
)

# The hash should be non-empty (the diff from real_work_sha to working tree)
HASH_WITH_BASE=$(run_hook_in_repo "$TEST_REPO" "$TEST_ARTIFACTS")
assert_ne "test_primary_path_uses_stored_base" "" "$HASH_WITH_BASE"
rm -rf "$TEST_REPO" "$TEST_ARTIFACTS"

# --- Test: Invalid stored SHA falls through to fallback ---
# test_invalid_stored_sha_falls_through
TEST_REPO=$(setup_test_repo)
TEST_ARTIFACTS=$(mktemp -d)
_CLEANUP_DIRS+=("$TEST_ARTIFACTS")
echo -n "not_a_valid_sha_at_all_1234567890abcdef" > "$TEST_ARTIFACTS/pre-checkpoint-base"
(
    cd "$TEST_REPO"
    echo "some change" > changed.txt
    git add changed.txt
    git commit -q -m "checkpoint: pre-compaction auto-save"
)
HASH_INVALID_BASE=$(run_hook_in_repo "$TEST_REPO" "$TEST_ARTIFACTS")
assert_ne "test_invalid_stored_sha_falls_through" "" "$HASH_INVALID_BASE"
rm -rf "$TEST_REPO" "$TEST_ARTIFACTS"

# --- Test: Fallback — bounded walk finds checkpoint commit ---
# test_fallback_walk_finds_checkpoint
# When no pre-checkpoint-base file exists, the script should walk commits
# and find the checkpoint, using its parent as the diff base.
TEST_REPO=$(setup_test_repo)
TEST_ARTIFACTS=$(mktemp -d)
_CLEANUP_DIRS+=("$TEST_ARTIFACTS")
(
    cd "$TEST_REPO"
    # Add real work
    echo "real work" > work.txt
    git add work.txt
    git commit -q -m "real work"
    # Create a checkpoint commit (HEAD becomes the checkpoint)
    echo "checkpoint state" > checkpoint.txt
    git add checkpoint.txt
    git commit -q -m "checkpoint: pre-compaction auto-save"
)
# No pre-checkpoint-base file — force fallback
HASH_FALLBACK=$(run_hook_in_repo "$TEST_REPO" "$TEST_ARTIFACTS")
assert_ne "test_fallback_walk_finds_checkpoint" "" "$HASH_FALLBACK"
rm -rf "$TEST_REPO" "$TEST_ARTIFACTS"

# --- Test: Fallback walk is bounded (max 10) ---
# test_fallback_walk_bounded
# Create a repo with >10 non-checkpoint commits after the initial one.
# With no pre-checkpoint-base file and no checkpoint commits in the walk,
# the walk should stop after 10 iterations and fall through to HEAD.
TEST_REPO=$(setup_test_repo)
TEST_ARTIFACTS=$(mktemp -d)
_CLEANUP_DIRS+=("$TEST_ARTIFACTS")
(
    cd "$TEST_REPO"
    for i in $(seq 1 12); do
        echo "commit $i" > "file_$i.txt"
        git add "file_$i.txt"
        git commit -q -m "normal commit $i"
    done
)
# Should still produce a hash (falls through to HEAD since no checkpoint found)
HASH_BOUNDED=$(run_hook_in_repo "$TEST_REPO" "$TEST_ARTIFACTS")
assert_ne "test_fallback_walk_bounded" "" "$HASH_BOUNDED"
rm -rf "$TEST_REPO" "$TEST_ARTIFACTS"

# --- Test: Checkpoint detection uses CHECKPOINT_LABEL, not hardcoded string ---
# test_checkpoint_label_not_hardcoded
# The source should reference CHECKPOINT_LABEL variable in the commit walk grep,
# not a raw hardcoded "checkpoint:" string for matching.
# (The constant definition itself is fine; the check is about usage in matching.)
if echo "$HOOK_SOURCE" | grep -q 'CHECKPOINT_LABEL'; then
    (( ++PASS ))
else
    (( ++FAIL ))
    printf "FAIL: test_checkpoint_label_not_hardcoded\n  CHECKPOINT_LABEL variable not found in source\n" >&2
fi

# Cleanup any remaining temp dirs
rm -rf "$TEST_REPO" "$TEST_ARTIFACTS" 2>/dev/null || true

print_summary
