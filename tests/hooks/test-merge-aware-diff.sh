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
    git init --bare "$tmpdir/origin.git" --quiet

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

# ── Cleanup ──────────────────────────────────────────────────────────────────
rm -rf "$TMPDIR_MERGE" "$TMPDIR_CAPTURE" 2>/dev/null || true
cd "$PLUGIN_ROOT"

print_summary
