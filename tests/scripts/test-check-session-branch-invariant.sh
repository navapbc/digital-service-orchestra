#!/usr/bin/env bash
# tests/scripts/test-check-session-branch-invariant.sh
# Behavioral tests for plugins/dso/scripts/check-session-branch-invariant.sh
#
# check-session-branch-invariant.sh is a post-hoc audit script that scans
# the current branch git log for merge commits from story/* branches and
# verifies each has a DSO-Story-Merge: trailer.
#
# Observable surfaces tested:
#   - exit code (0 = all clean, non-zero = missing trailer found)
#   - stderr content (offending commit SHA when trailer is missing)
#
# RED MARKER:
# tests/scripts/test-check-session-branch-invariant.sh [test_story_merge_missing_trailer_exits_nonzero]

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

_SCRIPT="$REPO_ROOT/plugins/dso/scripts/check-session-branch-invariant.sh"

source "$REPO_ROOT/tests/lib/assert.sh"

# ── Cleanup on exit ──────────────────────────────────────────────────────────
_TEST_TMPDIRS=()
_cleanup_test_tmpdirs() {
    local d
    for d in "${_TEST_TMPDIRS[@]+"${_TEST_TMPDIRS[@]}"}"; do
        rm -rf "$d" 2>/dev/null || true
    done
}
trap _cleanup_test_tmpdirs EXIT

# ── Helper: create a scratch git repo with one initial commit on main ─────────
# Prints the repo directory path on stdout.
make_git_repo() {
    local tmpdir
    tmpdir=$(mktemp -d)
    _TEST_TMPDIRS+=("$tmpdir")
    git -C "$tmpdir" init -q -b main
    git -C "$tmpdir" config user.email "test@test.com"
    git -C "$tmpdir" config user.name "Test"
    git -C "$tmpdir" config commit.gpgsign false
    git -C "$tmpdir" config merge.ff false
    printf '# test repo\n' > "$tmpdir/README.md"
    git -C "$tmpdir" add README.md
    git -C "$tmpdir" commit -q -m "init"
    printf "%s" "$tmpdir"
}

# ── Exit gate: count all 3 tests as FAIL if script is missing ─────────────────
if [[ ! -f "$_SCRIPT" ]]; then
    printf "FAIL: check-session-branch-invariant.sh not found — expected at %s\n" "$_SCRIPT" >&2
    printf "  All 3 behavioral cases counted as FAIL (RED phase — script not yet written)\n" >&2
    (( FAIL += 3 ))
    print_summary
fi

# ── Test 1: story/* merge commit MISSING DSO-Story-Merge: trailer ─────────────
# Given: a session branch whose log contains a merge commit from story/epic-1/story-1
#        with NO DSO-Story-Merge: trailer
# When:  check-session-branch-invariant.sh is run on that branch
# Then:  script exits non-zero AND prints the offending commit SHA to stderr
echo "--- test_story_merge_missing_trailer_exits_nonzero ---"
_repo1=$(make_git_repo)

# Create and merge a story branch without the required trailer
git -C "$_repo1" checkout -q -b story/epic-1/story-1
printf "task\n" > "$_repo1/task.txt"
git -C "$_repo1" add task.txt
git -C "$_repo1" commit -q -m "task commit"
git -C "$_repo1" checkout -q main
git -C "$_repo1" merge --no-ff story/epic-1/story-1 -m "Merge story/epic-1/story-1 — no trailer"

_offending_sha=$(git -C "$_repo1" log --format="%H" --merges -1)

_exit1=0
_stderr1=$(cd "$_repo1" && bash "$_SCRIPT" 2>&1 >/dev/null) || _exit1=$?

assert_ne \
    "test_story_merge_missing_trailer_exits_nonzero: missing trailer causes non-zero exit" \
    "0" "$_exit1"

assert_contains \
    "test_story_merge_missing_trailer_exits_nonzero: offending SHA printed to stderr" \
    "$_offending_sha" "$_stderr1"

# ── Test 2: story/* merge commit WITH DSO-Story-Merge: trailer ────────────────
# Given: a session branch whose log contains a merge commit from story/epic-1/story-1
#        WITH a valid DSO-Story-Merge: trailer
# When:  check-session-branch-invariant.sh is run on that branch
# Then:  script exits 0
echo "--- test_story_merge_with_trailer_exits_zero ---"
_repo2=$(make_git_repo)

git -C "$_repo2" checkout -q -b story/epic-1/story-1
printf "task\n" > "$_repo2/task.txt"
git -C "$_repo2" add task.txt
git -C "$_repo2" commit -q -m "task commit"
git -C "$_repo2" checkout -q main
git -C "$_repo2" merge --no-ff story/epic-1/story-1 \
    -m "$(printf 'Merge story/epic-1/story-1\n\nDSO-Story-Merge: story-id-123')"

_exit2=0
( cd "$_repo2" && bash "$_SCRIPT" 2>/dev/null ) || _exit2=$?

assert_eq \
    "test_story_merge_with_trailer_exits_zero: proper trailer causes exit 0" \
    "0" "$_exit2"

# ── Test 3: no merge commits from story/* branches at all ─────────────────────
# Given: a session branch with only regular commits (no story/* merges)
# When:  check-session-branch-invariant.sh is run on that branch
# Then:  script exits 0 (nothing to check)
echo "--- test_no_story_merges_exits_zero ---"
_repo3=$(make_git_repo)

# Add a plain commit (not a story merge)
printf "extra\n" > "$_repo3/extra.txt"
git -C "$_repo3" add extra.txt
git -C "$_repo3" commit -q -m "plain non-story commit"

_exit3=0
( cd "$_repo3" && bash "$_SCRIPT" 2>/dev/null ) || _exit3=$?

assert_eq \
    "test_no_story_merges_exits_zero: no story merges causes exit 0" \
    "0" "$_exit3"

print_summary
