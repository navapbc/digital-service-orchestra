#!/usr/bin/env bash
# tests/scripts/test-bug-reproducer-cafb.sh
# Reproducer for bug cafb-4b97-1703-41e3:
#   [Worktree Ancestry Gate]: squash merge rewrites code_version SHA ->
#   gate false-positives block valid bug investigations.
#
# Verifies that verify-session-provenance.sh correctly handles squash-merged
# commits by accepting the DSO-Story-Merge trailer (present in squash commits)
# as proof of provenance — independent of original commit SHA ancestry.
#
# Usage: bash tests/scripts/test-bug-reproducer-cafb.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"
PROVENANCE_SCRIPT="$REPO_ROOT/plugins/dso/scripts/verify-session-provenance.sh"

source "$REPO_ROOT/tests/lib/assert.sh"

echo "=== test-bug-reproducer-cafb.sh ==="
echo "Bug: squash-merged commits falsely flagged as un-provenanced; DSO-Story-Merge trailer not recognized"
echo ""

# ── Test 1: verify-session-provenance.sh still reads commit bodies ──────────
# PR-R1 update: the script previously used a DSO-Story-Merge trailer
# shortcut to mark commits provenanced without API verification. That
# shortcut was removed (audit Finding 3, self-attested claim ≠ evidence).
# The verifier still reads commit bodies for the DSO-Over-Bound: marker
# (acknowledged non-provenanced) but no longer greps for DSO-Story.
echo "Test 1: verify-session-provenance.sh still reads commit bodies (for DSO-Over-Bound marker)"
script_content="$(cat "$PROVENANCE_SCRIPT")"
assert_contains \
    "verify-session-provenance.sh still greps for DSO-Over-Bound: marker" \
    "DSO-Over-Bound:" \
    "$script_content"

# ── Test 2: Commit-body read mechanism unchanged ────────────────────────────
echo "Test 2: Provenance check reads commit body via git log --format=%B"
assert_contains \
    "script reads full commit body via git log --format=%B" \
    '--format="%B"' \
    "$script_content"

# ── Test 3: Squash commit with trailer + valid covering PR → exits 0 ─────────
# Post-PR-R1: the trailer is no longer load-bearing; provenance is established
# by the covering PR (PR1 = worktree-* → staged-*) having review-sub-pr
# passing. Use a `gh` shim to simulate that covering PR.
echo "Test 3: Script exits 0 when squash commit has covering PR with passing review-sub-pr"

# Create an isolated temp git repo for this test
_tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/cafb-test.XXXXXX")"
trap 'rm -rf "$_tmp_dir"' EXIT

_test_repo="$_tmp_dir/repo"
mkdir -p "$_test_repo"
git -C "$_test_repo" init -q
git -C "$_test_repo" config user.email "test@example.com"
git -C "$_test_repo" config user.name "Test"

# Create base commit on main
git -C "$_test_repo" commit --allow-empty -m "Initial commit (main baseline)" -q
_base_sha="$(git -C "$_test_repo" rev-parse HEAD)"

# Create a squash-merged commit that carries the DSO-Story-Merge trailer
# This simulates what GitHub produces when squash-merging a story branch:
# the original branch SHA is gone but the trailer is preserved in the squash commit.
git -C "$_test_repo" commit --allow-empty -m "feat: implement story (squash)

DSO-Story-Merge: story/abc123/def456" -q
_session_head="$(git -C "$_test_repo" rev-parse HEAD)"

# Run verify-session-provenance.sh against this synthetic repo
# DSO_BASE_SHA   → the base commit (simulates main)
# DSO_SESSION_HEAD → the squash commit (simulates the PR branch tip)
# DSO_REPO_PATH  → the synthetic repo
# DSO_ARTIFACT_DIR → temp dir to avoid polluting real /tmp
_artifact_dir="$(mktemp -d "${TMPDIR:-/tmp}/cafb-artifacts.XXXXXX")"
trap 'rm -rf "$_tmp_dir" "$_artifact_dir"' EXIT

# PR-R1: shim gh to simulate a covering PR with passing review-sub-pr.
_shim_dir="$(mktemp -d "${TMPDIR:-/tmp}/cafb-shim.XXXXXX")"
cat > "$_shim_dir/gh" <<'STUB'
#!/usr/bin/env bash
case "$1" in
  api)
    shift
    case "$1" in
      *commits/*/pulls)
        echo '[{"number": 777, "state": "closed", "merged_at": "2026-01-01T00:00:00Z", "head": {"sha": "deadbeef"}, "merge_commit_sha": "cafef00d"}]'
        ;;
      *pulls/777*) echo '{"number": 777, "head": {"sha": "deadbeef"}}' ;;
      *commits/*/check-runs*)
        echo '{"total_count": 1, "check_runs": [{"name": "review-sub-pr", "status": "completed", "conclusion": "success"}]}'
        ;;
      *) echo "{}" ;;
    esac ;;
  *) echo "{}" ;;
esac
STUB
chmod +x "$_shim_dir/gh"

actual_exit=0
PATH="$_shim_dir:$PATH" \
GH_REPO="test/test" \
DSO_REPO_PATH="$_test_repo" \
DSO_BASE_SHA="$_base_sha" \
DSO_SESSION_HEAD="$_session_head" \
DSO_ARTIFACT_DIR="$_artifact_dir" \
    bash "$PROVENANCE_SCRIPT" > /dev/null 2>&1 || actual_exit=$?

assert_eq \
    "verify-session-provenance exits 0 for squash commit with covering PR (review-sub-pr passing)" \
    "0" \
    "$actual_exit"
rm -rf "$_shim_dir"

# ── Test 4: Script exits 1 when squash commit lacks DSO-Story-Merge trailer ────
echo "Test 4: Script exits 1 when squash commit has no DSO-Story-Merge trailer"

# Create a second temp repo where the squash commit does NOT carry the trailer
_tmp_dir2="$(mktemp -d "${TMPDIR:-/tmp}/cafb-test2.XXXXXX")"
_test_repo2="$_tmp_dir2/repo"
mkdir -p "$_test_repo2"
git -C "$_test_repo2" init -q
git -C "$_test_repo2" config user.email "test@example.com"
git -C "$_test_repo2" config user.name "Test"

git -C "$_test_repo2" commit --allow-empty -m "Initial commit (main baseline)" -q
_base_sha2="$(git -C "$_test_repo2" rev-parse HEAD)"

# Squash commit WITHOUT trailer — no GitHub PR linkage, no trailer → unprovenanced
git -C "$_test_repo2" commit --allow-empty -m "feat: implement story (squash, no trailer)" -q
_session_head2="$(git -C "$_test_repo2" rev-parse HEAD)"

_artifact_dir2="$(mktemp -d "${TMPDIR:-/tmp}/cafb-artifacts2.XXXXXX")"

actual_exit2=0
# Disable gh API calls by pointing GH_REPO to a bogus value and limiting budget to 0
DSO_REPO_PATH="$_test_repo2" \
DSO_BASE_SHA="$_base_sha2" \
DSO_SESSION_HEAD="$_session_head2" \
DSO_ARTIFACT_DIR="$_artifact_dir2" \
DSO_GH_BUDGET="0" \
DSO_GH_REPO="no-such-owner/no-such-repo" \
    bash "$PROVENANCE_SCRIPT" > /dev/null 2>&1 || actual_exit2=$?

# Exit code MUST be 1 (unprovenanced) or 2 (budget exhausted) per the script's
# documented contract — both indicate not-provenanced. A != 0 check alone would
# accept any non-zero (e.g., 127 command-not-found or 5 permission-denied),
# masking infrastructure failures as successful negative-path validation.
if [[ "$actual_exit2" -eq 1 || "$actual_exit2" -eq 2 ]]; then
    echo "PASS: verify-session-provenance exits with documented code ($actual_exit2) for unprovenanced squash commit"
else
    echo "FAIL: verify-session-provenance exit code $actual_exit2 is neither 1 (unprovenanced) nor 2 (budget exhausted) — likely an infrastructure failure, not a contract validation"
    exit 1
fi

# Cleanup temp repos
rm -rf "$_tmp_dir2" "$_artifact_dir2"

print_summary
