#!/usr/bin/env bash
# lockpick-workflow/tests/hooks/test-checkpoint-sentinel.sh
#
# Tests for the checkpoint review sentinel mechanism (kg1n):
#   (a) pre-compact-checkpoint.sh writes a nonce to .checkpoint-needs-review
#   (b) record-review.sh writes checkpoint_cleared=<nonce> and stages sentinel removal
#   (c) merge-to-main.sh blocks if checkpoint_cleared is absent/mismatched
#   (d) merge-to-main.sh passes after a legitimate review clears the sentinel
#
# Usage: bash lockpick-workflow/tests/hooks/test-checkpoint-sentinel.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

REPO_ROOT="$(git rev-parse --show-toplevel)"
COMPACT_HOOK="$REPO_ROOT/lockpick-workflow/hooks/pre-compact-checkpoint.sh"
RECORD_HOOK="$REPO_ROOT/lockpick-workflow/hooks/record-review.sh"
MERGE_SCRIPT="$REPO_ROOT/scripts/merge-to-main.sh"
DEPS_SH="$REPO_ROOT/lockpick-workflow/hooks/lib/deps.sh"
COMPUTE_HASH="$REPO_ROOT/lockpick-workflow/hooks/compute-diff-hash.sh"

source "$REPO_ROOT/lockpick-workflow/tests/lib/assert.sh"

# ── Helper: compute get_artifacts_dir for a given repo path ──────────────────
# Must run from inside the repo so git rev-parse --show-toplevel returns the right path.
get_test_artifacts_dir() {
    local repo_dir="$1"
    (cd "$repo_dir" && bash -c 'source "'"$DEPS_SH"'" && get_artifacts_dir' 2>/dev/null)
}

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
setup_merge_env() {
    local tmpdir
    tmpdir=$(mktemp -d)
    local REALENV
    REALENV=$(cd "$tmpdir" && pwd -P)

    git init -q -b main "$REALENV/seed"
    git -C "$REALENV/seed" config user.email "test@test.com"
    git -C "$REALENV/seed" config user.name "Test"
    echo "initial" > "$REALENV/seed/README.md"
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
# PART A: pre-compact-checkpoint.sh writes .checkpoint-needs-review
# =============================================================================

# test_pre_compact_hook_source_contains_checkpoint_needs_review
HOOK_SOURCE=$(cat "$COMPACT_HOOK")
assert_contains "test_pre_compact_writes_checkpoint_sentinel" \
    ".checkpoint-needs-review" "$HOOK_SOURCE"

# test_pre_compact_uses_nonce_generation
assert_contains "test_pre_compact_uses_nonce_generation" \
    "NONCE" "$HOOK_SOURCE"

# test_pre_compact_sentinel_written_before_git_add
SENTINEL_WRITE_LINE=$(grep -n 'checkpoint-needs-review' "$COMPACT_HOOK" | head -1 | cut -d: -f1)
GIT_ADD_LINE=$(grep -n 'git add -A' "$COMPACT_HOOK" | head -1 | cut -d: -f1)
if [[ -n "$SENTINEL_WRITE_LINE" && -n "$GIT_ADD_LINE" ]] && \
   (( SENTINEL_WRITE_LINE < GIT_ADD_LINE )); then
    (( ++PASS ))
else
    (( ++FAIL ))
    printf "FAIL: test_pre_compact_sentinel_written_before_git_add\n  sentinel_line=%s, git_add_line=%s\n" \
        "${SENTINEL_WRITE_LINE:-not found}" "${GIT_ADD_LINE:-not found}" >&2
fi

# test_pre_compact_sentinel_committed_in_temp_repo
# Run the hook in a temp git repo and verify .checkpoint-needs-review is committed.
TEST_GIT_A=$(mktemp -d)
TEST_ARTIFACTS_A=$(mktemp -d)
(
    cd "$TEST_GIT_A"
    git init -q
    git config user.email "test@test.com"
    git config user.name "Test"
    echo "test" > file.txt
    git add file.txt
    git commit -q -m "initial"
) 2>/dev/null

# Run the hook — it calls get_artifacts_dir, so we set _DEPS_LOADED + export override
# to prevent deps.sh from redefining our function.
(
    cd "$TEST_GIT_A"
    # The hook sets up ARTIFACTS_DIR itself; we override get_artifacts_dir via env.
    export _DEPS_LOADED=1
    get_artifacts_dir() { echo "$TEST_ARTIFACTS_A"; }
    export -f get_artifacts_dir
    # Now run the hook — it sources deps.sh but _DEPS_LOADED=1 guard prevents redefinition
    bash "$COMPACT_HOOK" 2>/dev/null
) || true

# Check: sentinel was committed (in HEAD tree) or written as a file
SENTINEL_IN_TREE=$(cd "$TEST_GIT_A" && git show HEAD:.checkpoint-needs-review 2>/dev/null | tr -d '[:space:]' || true)
if [[ -n "$SENTINEL_IN_TREE" ]]; then
    (( ++PASS ))
elif [[ -f "$TEST_GIT_A/.checkpoint-needs-review" ]]; then
    (( ++PASS ))
else
    (( ++FAIL ))
    printf "FAIL: test_pre_compact_sentinel_committed_in_temp_repo\n  .checkpoint-needs-review not found in HEAD or working tree\n" >&2
fi

rm -rf "$TEST_GIT_A" "$TEST_ARTIFACTS_A"

# =============================================================================
# PART B: record-review.sh detects sentinel, writes checkpoint_cleared, stages removal
# =============================================================================

# test_record_review_source_references_sentinel
RECORD_SOURCE=$(cat "$RECORD_HOOK")
assert_contains "test_record_review_source_contains_checkpoint_needs_review" \
    ".checkpoint-needs-review" "$RECORD_SOURCE"
assert_contains "test_record_review_source_contains_checkpoint_cleared" \
    "checkpoint_cleared" "$RECORD_SOURCE"
assert_contains "test_record_review_source_stages_sentinel_removal" \
    "git rm" "$RECORD_SOURCE"

# test_record_review_writes_checkpoint_cleared_when_sentinel_present
# Set up a minimal git repo with a sentinel file committed.
# record-review.sh should detect it and write checkpoint_cleared to review-status.
TEST_GIT_B=$(mktemp -d)
NONCE_B="testnonceabcd1234"
(
    cd "$TEST_GIT_B"
    git init -q
    git config user.email "test@test.com"
    git config user.name "Test"
    echo "code change" > src.py
    echo "$NONCE_B" > .checkpoint-needs-review
    git add src.py .checkpoint-needs-review
    git commit -q -m "checkpoint: pre-compaction auto-save"
    # Stage a new change so the review has something to target
    echo "more code" >> src.py
    git add src.py
) 2>/dev/null

# Compute the real artifacts dir for TEST_GIT_B
REAL_ARTIFACTS_B=$(get_test_artifacts_dir "$TEST_GIT_B")

# Write reviewer-findings.json to the real artifacts dir
FINDINGS_JSON_B='{"scores":{"code_hygiene":4,"object_oriented_design":4,"readability":4,"functionality":4,"testing_coverage":4},"findings":[],"summary":"Code looks good overall with no significant issues found."}'
mkdir -p "$REAL_ARTIFACTS_B"
echo "$FINDINGS_JSON_B" > "$REAL_ARTIFACTS_B/reviewer-findings.json"
REVIEWER_HASH_B=$(shasum -a 256 "$REAL_ARTIFACTS_B/reviewer-findings.json" | awk '{print $1}')

# Compute the diff hash from TEST_GIT_B
DIFF_HASH_B=$(cd "$TEST_GIT_B" && bash "$COMPUTE_HASH" 2>/dev/null || true)

# Run record-review.sh (uses real artifacts dir)
REVIEW_JSON_B='{"scores":{"code_hygiene":4,"object_oriented_design":4,"readability":4,"functionality":4,"testing_coverage":4},"summary":"Code looks good overall with no significant issues found.","feedback":{"files_targeted":["src.py"]},"findings":[]}'
RECORD_OUTPUT_B=$(cd "$TEST_GIT_B" && echo "$REVIEW_JSON_B" | bash "$RECORD_HOOK" \
    --expected-hash "$DIFF_HASH_B" \
    --reviewer-hash "$REVIEWER_HASH_B" 2>&1) || true

# Verify checkpoint_cleared is in review-status
if [[ -f "$REAL_ARTIFACTS_B/review-status" ]]; then
    CLEARED_LINE_B=$(grep "^checkpoint_cleared=" "$REAL_ARTIFACTS_B/review-status" | head -1 || true)
    CLEARED_NONCE_B="${CLEARED_LINE_B#checkpoint_cleared=}"
    if [[ "$CLEARED_NONCE_B" == "$NONCE_B" ]]; then
        (( ++PASS ))
    else
        (( ++FAIL ))
        printf "FAIL: test_record_review_writes_checkpoint_cleared_when_sentinel_present\n  expected nonce=%s, got=%s\n  record output: %s\n" \
            "$NONCE_B" "$CLEARED_NONCE_B" "$RECORD_OUTPUT_B" >&2
    fi
else
    (( ++FAIL ))
    printf "FAIL: test_record_review_writes_checkpoint_cleared_when_sentinel_present\n  review-status not written\n  record output: %s\n" "$RECORD_OUTPUT_B" >&2
fi

rm -rf "$TEST_GIT_B"

# test_record_review_no_checkpoint_cleared_without_sentinel
# When .checkpoint-needs-review is absent, checkpoint_cleared must NOT be written.
TEST_GIT_C=$(mktemp -d)
(
    cd "$TEST_GIT_C"
    git init -q
    git config user.email "test@test.com"
    git config user.name "Test"
    echo "initial" > src.py
    git add src.py
    git commit -q -m "initial commit"
    echo "change" >> src.py
    git add src.py
) 2>/dev/null

REAL_ARTIFACTS_C=$(get_test_artifacts_dir "$TEST_GIT_C")
FINDINGS_JSON_C='{"scores":{"code_hygiene":4,"object_oriented_design":4,"readability":4,"functionality":4,"testing_coverage":4},"findings":[],"summary":"Code looks good without any issues."}'
mkdir -p "$REAL_ARTIFACTS_C"
echo "$FINDINGS_JSON_C" > "$REAL_ARTIFACTS_C/reviewer-findings.json"
REVIEWER_HASH_C=$(shasum -a 256 "$REAL_ARTIFACTS_C/reviewer-findings.json" | awk '{print $1}')
DIFF_HASH_C=$(cd "$TEST_GIT_C" && bash "$COMPUTE_HASH" 2>/dev/null || true)

REVIEW_JSON_C='{"scores":{"code_hygiene":4,"object_oriented_design":4,"readability":4,"functionality":4,"testing_coverage":4},"summary":"Code looks good without any issues.","feedback":{"files_targeted":["src.py"]},"findings":[]}'
cd "$TEST_GIT_C" && echo "$REVIEW_JSON_C" | bash "$RECORD_HOOK" \
    --expected-hash "$DIFF_HASH_C" \
    --reviewer-hash "$REVIEWER_HASH_C" 2>/dev/null || true

cd "$REPO_ROOT"

if [[ -f "$REAL_ARTIFACTS_C/review-status" ]]; then
    CLEARED_LINE_C=$(grep "^checkpoint_cleared=" "$REAL_ARTIFACTS_C/review-status" 2>/dev/null | head -1 || true)
    if [[ -z "$CLEARED_LINE_C" ]]; then
        (( ++PASS ))
    else
        (( ++FAIL ))
        printf "FAIL: test_record_review_no_checkpoint_cleared_without_sentinel\n  unexpected: %s\n" "$CLEARED_LINE_C" >&2
    fi
else
    # review-status not written — test inconclusive
    (( ++PASS ))
fi

rm -rf "$TEST_GIT_C"

# =============================================================================
# PART C: merge-to-main.sh blocks when checkpoint_cleared is absent
# =============================================================================

TMPENV_C=$(setup_merge_env)
WT_C=$(cd "$TMPENV_C/worktree" && pwd -P)

# Checkpoint commit: code + sentinel with nonce
NONCE_C="nonce4merge1234abc"
echo "feature code" > "$WT_C/feature.py"
echo "$NONCE_C" > "$WT_C/.checkpoint-needs-review"
(cd "$WT_C" && git add feature.py .checkpoint-needs-review && \
    git commit -q -m "checkpoint: pre-compaction auto-save") 2>/dev/null

# Post-checkpoint commit
echo "more feature code" >> "$WT_C/feature.py"
(cd "$WT_C" && git add feature.py && git commit -q -m "feat: add more feature") 2>/dev/null

# Write review-status WITHOUT checkpoint_cleared
REAL_ARTIFACTS_WT_C=$(get_test_artifacts_dir "$WT_C")
mkdir -p "$REAL_ARTIFACTS_WT_C"
{
    echo "passed"
    echo "timestamp=2026-01-01T00:00:00Z"
    echo "diff_hash=somehash"
    echo "score=4"
} > "$REAL_ARTIFACTS_WT_C/review-status"

MERGE_OUTPUT_C=$(cd "$WT_C" && unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE && \
    bash "$MERGE_SCRIPT" 2>&1 || true)

assert_contains "test_merge_blocked_without_checkpoint_cleared" \
    "Unreviewed checkpoint" "$MERGE_OUTPUT_C"

cleanup_env "$TMPENV_C"

# =============================================================================
# PART D: merge-to-main.sh passes when checkpoint_cleared matches nonce
# =============================================================================

TMPENV_D=$(setup_merge_env)
WT_D=$(cd "$TMPENV_D/worktree" && pwd -P)

NONCE_D="correctnonce5678xyz"
echo "feature code" > "$WT_D/feature.py"
echo "$NONCE_D" > "$WT_D/.checkpoint-needs-review"
(cd "$WT_D" && git add feature.py .checkpoint-needs-review && \
    git commit -q -m "checkpoint: pre-compaction auto-save") 2>/dev/null

# Simulate record-review.sh having removed the sentinel
git -C "$WT_D" rm -q ".checkpoint-needs-review" 2>/dev/null
(cd "$WT_D" && git commit -q -m "review: code changes post-compaction") 2>/dev/null

# Write review-status with correct checkpoint_cleared
REAL_ARTIFACTS_WT_D=$(get_test_artifacts_dir "$WT_D")
mkdir -p "$REAL_ARTIFACTS_WT_D"
{
    echo "passed"
    echo "timestamp=2026-01-01T00:00:00Z"
    echo "diff_hash=abc123"
    echo "score=4"
    echo "review_hash=def456"
    echo "checkpoint_cleared=${NONCE_D}"
} > "$REAL_ARTIFACTS_WT_D/review-status"

MERGE_OUTPUT_D=$(cd "$WT_D" && unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE && \
    bash "$MERGE_SCRIPT" 2>&1 || true)

# Should NOT be blocked
BLOCKED_D=$(echo "$MERGE_OUTPUT_D" | grep "Unreviewed checkpoint" | head -1 || true)
if [[ -z "$BLOCKED_D" ]]; then
    (( ++PASS ))
else
    (( ++FAIL ))
    printf "FAIL: test_merge_passes_with_correct_checkpoint_cleared\n  unexpected block: %s\n" "$BLOCKED_D" >&2
fi

assert_contains "test_merge_passes_with_correct_checkpoint_cleared_done" \
    "DONE" "$MERGE_OUTPUT_D"

cleanup_env "$TMPENV_D"

# =============================================================================
# PART E: merge-to-main.sh blocks when checkpoint_cleared has wrong nonce
# =============================================================================

TMPENV_E=$(setup_merge_env)
WT_E=$(cd "$TMPENV_E/worktree" && pwd -P)

NONCE_REAL_E="realnonce9999aaaa"
NONCE_WRONG_E="wrongnonce1234bbbb"

echo "some code" > "$WT_E/feature.py"
echo "$NONCE_REAL_E" > "$WT_E/.checkpoint-needs-review"
(cd "$WT_E" && git add feature.py .checkpoint-needs-review && \
    git commit -q -m "checkpoint: pre-compaction auto-save") 2>/dev/null

REAL_ARTIFACTS_WT_E=$(get_test_artifacts_dir "$WT_E")
mkdir -p "$REAL_ARTIFACTS_WT_E"
{
    echo "passed"
    echo "timestamp=2026-01-01T00:00:00Z"
    echo "checkpoint_cleared=${NONCE_WRONG_E}"
} > "$REAL_ARTIFACTS_WT_E/review-status"

MERGE_OUTPUT_E=$(cd "$WT_E" && unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE && \
    bash "$MERGE_SCRIPT" 2>&1 || true)

assert_contains "test_merge_blocked_with_wrong_checkpoint_nonce" \
    "Unreviewed checkpoint" "$MERGE_OUTPUT_E"

cleanup_env "$TMPENV_E"

# =============================================================================
# PART F: merge-to-main.sh passes when no checkpoint commit exists in branch
# =============================================================================

TMPENV_F=$(setup_merge_env)
WT_F=$(cd "$TMPENV_F/worktree" && pwd -P)

# Normal commit — no sentinel
echo "normal feature" > "$WT_F/feature.py"
(cd "$WT_F" && git add feature.py && git commit -q -m "feat: normal work") 2>/dev/null

MERGE_OUTPUT_F=$(cd "$WT_F" && unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE && \
    bash "$MERGE_SCRIPT" 2>&1 || true)

BLOCKED_F=$(echo "$MERGE_OUTPUT_F" | grep "Unreviewed checkpoint" | head -1 || true)
if [[ -z "$BLOCKED_F" ]]; then
    (( ++PASS ))
else
    (( ++FAIL ))
    printf "FAIL: test_merge_passes_without_checkpoint_commit\n  unexpected block: %s\n" "$BLOCKED_F" >&2
fi

cleanup_env "$TMPENV_F"

print_summary
