#!/usr/bin/env bash
# tests/hooks/test-merge-aware-diff.sh
# Tests that compute-diff-hash.sh and capture-review-diff.sh exclude
# incoming-only files during a merge, matching the review gate behavior.
#
# Bug: 1ded-89e6 — Review gate captures full merge diff including
# incoming-only files that were already reviewed on main.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DSO_PLUGIN_DIR="$PLUGIN_ROOT/plugins/dso"
COMPUTE_HASH="$DSO_PLUGIN_DIR/hooks/compute-diff-hash.sh"
CAPTURE_DIFF="$DSO_PLUGIN_DIR/scripts/capture-review-diff.sh"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

echo "=== test-merge-aware-diff.sh ==="

# ── Setup: create a temp repo simulating a merge scenario ────────────────────
_setup_merge_repo() {
    local tmpdir
    tmpdir=$(mktemp -d)

    # Create a bare origin to avoid push-to-checkout issues
    # Use -b main to ensure consistent branch naming across environments
    # (git init defaults to 'master' in CI without init.defaultBranch set)
    git init --bare -b main "$tmpdir/origin.git" --quiet

    # Clone to worktree
    git clone "$tmpdir/origin.git" "$tmpdir/repo" --quiet 2>/dev/null

    cd "$tmpdir/repo"
    git config user.email "test@test.com"
    git config user.name "Test"

    # Initial commit on main
    echo "initial" > base.txt
    git add base.txt
    git commit -m "initial" --quiet

    # Create a feature branch (simulates the worktree branch)
    git checkout -b feature --quiet

    # Add a file on the feature branch
    echo "feature work" > feature.txt
    git add feature.txt
    git commit -m "feature: add feature.txt" --quiet

    # Go back to main and add an incoming-only file
    git checkout main --quiet
    echo "incoming from main" > incoming.txt
    git add incoming.txt
    git commit -m "main: add incoming.txt" --quiet

    # Go back to feature and start a merge (no commit)
    git checkout feature --quiet
    git merge main --no-commit --no-edit 2>/dev/null || true

    # Now we're in a merge state:
    # - feature.txt was changed on the feature branch
    # - incoming.txt is incoming-only from main
    # MERGE_HEAD exists

    echo "$tmpdir"
}

# ── test_compute_diff_hash_excludes_incoming_only_during_merge ────────────────
echo ""
echo "--- test_compute_diff_hash_excludes_incoming_only_during_merge ---"
_snapshot_fail

TMPDIR_MERGE=$(_setup_merge_repo)
cd "$TMPDIR_MERGE/repo"

# Verify MERGE_HEAD exists (we're in a merge)
merge_head_exists=0
[ -f "$(git rev-parse --git-dir)/MERGE_HEAD" ] && merge_head_exists=1
assert_eq "setup: MERGE_HEAD exists" "1" "$merge_head_exists"

# Compute the hash — it should NOT include incoming.txt
# First, get the full diff to verify incoming.txt IS in the raw diff
full_diff=$(git diff HEAD 2>/dev/null)
has_incoming_in_full=0
echo "$full_diff" | grep -q "incoming.txt" && has_incoming_in_full=1
assert_eq "setup: incoming.txt is in the full diff" "1" "$has_incoming_in_full"

# Now run compute-diff-hash.sh twice:
# 1) During the merge (should exclude incoming-only)
# 2) After aborting the merge (only feature branch changes)
# If the hash correctly excludes incoming-only files, the merge hash
# should equal the non-merge hash (both see only feature branch changes)
export CLAUDE_PLUGIN_ROOT="$DSO_PLUGIN_DIR"
merge_hash=$(bash "$COMPUTE_HASH" 2>/dev/null) || true

# Abort the merge and get the hash of just the feature branch
git merge --abort 2>/dev/null || git reset --merge 2>/dev/null || true
nonmerge_hash=$(bash "$COMPUTE_HASH" 2>/dev/null) || true

assert_eq "test_compute_diff_hash_excludes_incoming_only_during_merge: merge hash equals non-merge hash" \
    "$nonmerge_hash" "$merge_hash"
assert_pass_if_clean "test_compute_diff_hash_excludes_incoming_only_during_merge"

# ── test_capture_review_diff_excludes_incoming_only_during_merge ──────────────
echo ""
echo "--- test_capture_review_diff_excludes_incoming_only_during_merge ---"
_snapshot_fail

TMPDIR_CAPTURE=$(_setup_merge_repo)
cd "$TMPDIR_CAPTURE/repo"

DIFF_OUT="$TMPDIR_CAPTURE/diff.txt"
STAT_OUT="$TMPDIR_CAPTURE/stat.txt"

export CLAUDE_PLUGIN_ROOT="$DSO_PLUGIN_DIR"
bash "$CAPTURE_DIFF" "$DIFF_OUT" "$STAT_OUT" 2>/dev/null || true

# The captured diff should NOT contain incoming.txt
diff_has_incoming=0
grep -q "incoming.txt" "$DIFF_OUT" 2>/dev/null && diff_has_incoming=1
assert_eq "test_capture_review_diff_excludes_incoming_only_during_merge: diff excludes incoming.txt" \
    "0" "$diff_has_incoming"

# The captured diff SHOULD contain feature.txt (worktree branch change)
diff_has_feature=0
grep -q "feature.txt" "$DIFF_OUT" 2>/dev/null && diff_has_feature=1
assert_eq "test_capture_review_diff_excludes_incoming_only_during_merge: diff includes feature.txt" \
    "1" "$diff_has_feature"

assert_pass_if_clean "test_capture_review_diff_excludes_incoming_only_during_merge"

# ── Setup: create a temp repo simulating a rebase scenario ───────────────────
# Scenario: worktree branch has 2 commits after the rebase base (onto).
# The rebase is in progress — REBASE_HEAD + rebase-merge/onto are present.
# Without REBASE_HEAD handling, the script falls through to HEAD~1 diff which
# only shows the most recent commit (worktree-feature.txt), missing the stat
# scoping for files from the full onto..HEAD range AND the script produces
# different output than when properly using the onto range.
#
# We construct the scenario so that:
#   - onto: commit that adds base.txt
#   - HEAD: commit on top of onto that adds worktree-feature.txt
#   - A pre-onto commit adds pre-onto.txt (exists in the repo history but not in onto..HEAD)
# The rebase-scoped diff (onto..HEAD) should include worktree-feature.txt but NOT pre-onto.txt.
# Without REBASE_HEAD handling, git diff HEAD~1 would show worktree-feature.txt
# but the stat path (git diff HEAD --stat) would also only show worktree-feature.txt.
# So we need pre-onto.txt to be in a diff range that *would* appear if fallback
# uses a broader range — specifically, we stage pre-onto.txt changes so they
# appear in git diff --staged (the fallback path).
_setup_rebase_repo() {
    local tmpdir
    tmpdir=$(mktemp -d)

    git init -b main "$tmpdir/repo" --quiet 2>/dev/null || git init "$tmpdir/repo" --quiet
    cd "$tmpdir/repo"
    git config user.email "test@test.com"
    git config user.name "Test"

    # Pre-onto commit: adds pre-onto.txt
    echo "pre-onto content" > pre-onto.txt
    git add pre-onto.txt
    git commit -m "pre: add pre-onto.txt" --quiet

    # Onto commit: this is the rebase target
    echo "base" > base.txt
    git add base.txt
    git commit -m "onto: add base.txt" --quiet
    local onto_sha
    onto_sha=$(git rev-parse HEAD)

    # Worktree-branch commit: adds worktree-feature.txt
    echo "worktree feature work" > worktree-feature.txt
    git add worktree-feature.txt
    git commit -m "feature: add worktree-feature.txt" --quiet
    local orig_head_sha
    orig_head_sha=$(git rev-parse HEAD)

    # Simulate REBASE_HEAD state:
    # - .git/REBASE_HEAD: the commit being replayed
    # - .git/rebase-merge/onto: the base we're rebasing onto
    # - .git/rebase-merge/orig-head: the original tip of the branch before rebasing
    local git_dir
    git_dir=$(git rev-parse --git-dir)
    echo "$orig_head_sha" > "$git_dir/REBASE_HEAD"
    mkdir -p "$git_dir/rebase-merge"
    echo "$onto_sha" > "$git_dir/rebase-merge/onto"
    echo "$orig_head_sha" > "$git_dir/rebase-merge/orig-head"

    # Stage a modification to pre-onto.txt so the fallback (git diff --staged)
    # would include it — this distinguishes rebase-scoped behavior (only onto..HEAD
    # files) from fallback behavior (staged changes, which includes pre-onto.txt).
    echo "modified" >> pre-onto.txt
    git add pre-onto.txt

    echo "$tmpdir"
    echo "$onto_sha"
}

# ── test_capture_diff_rebase_scopes_to_worktree ───────────────────────────────
echo ""
echo "--- test_capture_diff_rebase_scopes_to_worktree ---"
_snapshot_fail

_rebase_output=$(_setup_rebase_repo)
TMPDIR_REBASE=$(echo "$_rebase_output" | head -1)
_rebase_onto_sha=$(echo "$_rebase_output" | tail -1)
cd "$TMPDIR_REBASE/repo"

# Verify REBASE_HEAD state is set up correctly
rebase_head_exists=0
[ -f "$(git rev-parse --git-dir)/REBASE_HEAD" ] && rebase_head_exists=1
assert_eq "setup: REBASE_HEAD exists" "1" "$rebase_head_exists"

onto_file_exists=0
[ -f "$(git rev-parse --git-dir)/rebase-merge/onto" ] && onto_file_exists=1
assert_eq "setup: rebase-merge/onto exists" "1" "$onto_file_exists"

DIFF_REBASE_OUT="$TMPDIR_REBASE/diff.txt"
STAT_REBASE_OUT="$TMPDIR_REBASE/stat.txt"

export CLAUDE_PLUGIN_ROOT="$DSO_PLUGIN_DIR"
bash "$CAPTURE_DIFF" "$DIFF_REBASE_OUT" "$STAT_REBASE_OUT" 2>/dev/null || true

# DIFF FILE: must contain worktree-feature.txt (introduced in onto..HEAD range)
diff_has_worktree_file=0
grep -q "worktree-feature.txt" "$DIFF_REBASE_OUT" 2>/dev/null && diff_has_worktree_file=1
assert_eq "test_capture_diff_rebase_scopes_to_worktree: diff file contains worktree-branch file" \
    "1" "$diff_has_worktree_file"

# DIFF FILE: must NOT contain pre-onto.txt (only staged via fallback path, not in onto..HEAD)
diff_has_pre_onto=0
grep -q "pre-onto.txt" "$DIFF_REBASE_OUT" 2>/dev/null && diff_has_pre_onto=1
assert_eq "test_capture_diff_rebase_scopes_to_worktree: diff file excludes pre-onto staged file" \
    "0" "$diff_has_pre_onto"

# STAT FILE: must contain worktree-feature.txt
stat_has_worktree_file=0
grep -q "worktree-feature.txt" "$STAT_REBASE_OUT" 2>/dev/null && stat_has_worktree_file=1
assert_eq "test_capture_diff_rebase_scopes_to_worktree: stat file contains worktree-branch file" \
    "1" "$stat_has_worktree_file"

# STAT FILE: must NOT contain pre-onto.txt
stat_has_pre_onto=0
grep -q "pre-onto.txt" "$STAT_REBASE_OUT" 2>/dev/null && stat_has_pre_onto=1
assert_eq "test_capture_diff_rebase_scopes_to_worktree: stat file excludes pre-onto staged file" \
    "0" "$stat_has_pre_onto"

assert_pass_if_clean "test_capture_diff_rebase_scopes_to_worktree"

# ── test_capture_diff_rebase_failsafe ────────────────────────────────────────
echo ""
echo "--- test_capture_diff_rebase_failsafe ---"
_snapshot_fail

TMPDIR_FAILSAFE=$(mktemp -d)
git init -b main "$TMPDIR_FAILSAFE/repo" --quiet 2>/dev/null || git init "$TMPDIR_FAILSAFE/repo" --quiet
cd "$TMPDIR_FAILSAFE/repo"
git config user.email "test@test.com"
git config user.name "Test"

# Create two commits so HEAD~1 fallback is available
echo "first" > first.txt
git add first.txt
git commit -m "first" --quiet
echo "second work" > second.txt
git add second.txt
git commit -m "second" --quiet

# Simulate REBASE_HEAD WITHOUT the onto file (incomplete/corrupt rebase state)
_failsafe_git_dir=$(git rev-parse --git-dir)
echo "$(git rev-parse HEAD~1)" > "$_failsafe_git_dir/REBASE_HEAD"
# Deliberately omit: mkdir rebase-merge && echo ... > rebase-merge/onto

DIFF_FAILSAFE_OUT="$TMPDIR_FAILSAFE/diff.txt"
STAT_FAILSAFE_OUT="$TMPDIR_FAILSAFE/stat.txt"

export CLAUDE_PLUGIN_ROOT="$DSO_PLUGIN_DIR"
bash "$CAPTURE_DIFF" "$DIFF_FAILSAFE_OUT" "$STAT_FAILSAFE_OUT" 2>/dev/null || true

# Without onto file, script must NOT crash — it must produce a non-empty diff
# (falls back to full diff via HEAD~1 path)
failsafe_diff_nonempty=0
[ -s "$DIFF_FAILSAFE_OUT" ] && failsafe_diff_nonempty=1
assert_eq "test_capture_diff_rebase_failsafe: fallback produces non-empty diff" \
    "1" "$failsafe_diff_nonempty"

# The fallback diff should contain second.txt (the most recent commit)
failsafe_diff_has_content=0
grep -q "second.txt" "$DIFF_FAILSAFE_OUT" 2>/dev/null && failsafe_diff_has_content=1
assert_eq "test_capture_diff_rebase_failsafe: fallback diff contains recent commit content" \
    "1" "$failsafe_diff_has_content"

assert_pass_if_clean "test_capture_diff_rebase_failsafe"

# ── Cleanup ──────────────────────────────────────────────────────────────────
rm -rf "$TMPDIR_MERGE" "$TMPDIR_CAPTURE" "$TMPDIR_REBASE" "$TMPDIR_FAILSAFE" 2>/dev/null || true
cd "$PLUGIN_ROOT"

print_summary
