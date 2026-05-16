#!/usr/bin/env bash
# tests/hooks/test-check-session-merge-only.sh
# Behavioral tests for plugins/dso/scripts/check-session-merge-only.sh
#
# This is a RED test file: all 4 test cases FAIL because the script does not
# exist yet. An exit gate at the top detects the missing script, counts each
# test as a FAIL (rather than skipping), then calls print_summary to exit
# nonzero so the RED condition is clearly surfaced.
#
# Test cases (4 — one per DD from story 53be-becc-af70-4f62):
#   1. non-merge commit + .sprint-active present → script rejects (exit nonzero)
#   2. merge commit + .sprint-active present    → script accepts (exit 0)
#   3. DSO_SPRINT_ACTIVE=0 + .sprint-active present → exit 0 + audit log written
#   4. no .sprint-active marker                → script accepts (exit 0)
#
# RED MARKER:
# tests/hooks/test-check-session-merge-only.sh [test_non_merge_with_sprint_active_rejected]

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

_SCRIPT="$PLUGIN_ROOT/plugins/dso/scripts/check-session-merge-only.sh"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

# ── Cleanup on exit ──────────────────────────────────────────────────────────
_TEST_TMPDIRS=()
_cleanup_test_tmpdirs() {
    for d in "${_TEST_TMPDIRS[@]}"; do
        rm -rf "$d" 2>/dev/null || true
    done
}
trap _cleanup_test_tmpdirs EXIT

# ── Helper: create a temp git repo with one initial commit ────────────────────
# Prints the repo directory path on stdout.
make_git_repo_with_commit() {
    local tmpdir
    tmpdir=$(mktemp -d)
    _TEST_TMPDIRS+=("$tmpdir")
    git -C "$tmpdir" init -q
    git -C "$tmpdir" config user.email "test@test.com"
    git -C "$tmpdir" config user.name "Test"
    git -C "$tmpdir" config commit.gpgsign false
    printf '# test repo\n' > "$tmpdir/README.md"
    git -C "$tmpdir" add README.md
    git -C "$tmpdir" commit -q -m "init"
    echo "$tmpdir"
}

# ── Helper: create a temp main repo + a linked worktree off of it ─────────────
# Prints the linked worktree directory path on stdout. The linked worktree
# satisfies the new git-common-dir != git-dir check in the hook, so the
# hook's marker-check / escape-hatch logic exercises end-to-end.
make_linked_worktree() {
    local main_repo
    main_repo=$(make_git_repo_with_commit)

    local wt_dir
    wt_dir=$(mktemp -d)
    rm -rf "$wt_dir"  # `git worktree add` requires a non-existent path
    _TEST_TMPDIRS+=("$wt_dir")

    # Create a linked worktree on a new branch off the existing HEAD.
    git -C "$main_repo" worktree add -q -b test-wt "$wt_dir" >/dev/null 2>&1
    echo "$wt_dir"
}

# ── Exit gate: mark all 4 tests as FAILed if script is missing ───────────────
if [[ ! -f "$_SCRIPT" ]]; then
    printf "FAIL: check-session-merge-only.sh not found — expected at %s\n" "$_SCRIPT" >&2
    printf "  All 4 behavioral cases counted as FAIL (RED phase — script not yet written)\n" >&2
    (( FAIL += 4 ))
    print_summary
fi

# ── Test 1: non-merge commit + .sprint-active present → rejected ──────────────
# Setup: temp git repo with a regular (non-merge) commit; .sprint-active present
# Expected: script exits nonzero (commit rejected)
test_non_merge_with_sprint_active_rejected() {
    local _repo
    _repo=$(make_linked_worktree)

    # Place .sprint-active marker at repo root
    touch "$_repo/.sprint-active"

    # The repo already has a regular (non-merge) HEAD commit from make_git_repo_with_commit.
    # Run the script from inside the repo.
    local exit_code=0
    ( cd "$_repo" && bash "$_SCRIPT" 2>/dev/null ) || exit_code=$?

    assert_ne \
        "test_non_merge_with_sprint_active_rejected: non-merge commit with .sprint-active exits nonzero" \
        "0" "$exit_code"
}

# ── Test 2: merge commit + .sprint-active present → accepted ─────────────────
# Setup: temp git repo; create .git/MERGE_HEAD to simulate a mid-merge state;
#        .sprint-active present
# Expected: script exits 0 (merge commit accepted)
test_merge_commit_with_sprint_active_accepted() {
    local _repo
    _repo=$(make_git_repo_with_commit)

    # Simulate git being mid-merge by writing a MERGE_HEAD file
    printf 'deadbeefdeadbeefdeadbeefdeadbeefdeadbeef\n' > "$_repo/.git/MERGE_HEAD"

    # Place .sprint-active marker
    touch "$_repo/.sprint-active"

    local exit_code=0
    ( cd "$_repo" && bash "$_SCRIPT" 2>/dev/null ) || exit_code=$?

    assert_eq \
        "test_merge_commit_with_sprint_active_accepted: merge commit with .sprint-active exits 0" \
        "0" "$exit_code"
}

# ── Test 3: DSO_SPRINT_ACTIVE=0 bypass → exit 0 + audit log written ──────────
# Setup: temp git repo; .sprint-active present; DSO_SPRINT_ACTIVE=0 env override;
#        DSO_ARTIFACTS_DIR points to a temp dir
# Expected: script exits 0 AND at least one file exists in DSO_ARTIFACTS_DIR
test_dso_sprint_active_override_exits_0_and_writes_audit_log() {
    local _repo _artifacts_dir
    _repo=$(make_linked_worktree)
    _artifacts_dir=$(mktemp -d)
    _TEST_TMPDIRS+=("$_artifacts_dir")

    touch "$_repo/.sprint-active"

    local exit_code=0
    (
        cd "$_repo"
        DSO_SPRINT_ACTIVE=0 DSO_ARTIFACTS_DIR="$_artifacts_dir" bash "$_SCRIPT" 2>/dev/null
    ) || exit_code=$?

    assert_eq \
        "test_dso_sprint_active_override_exits_0_and_writes_audit_log: DSO_SPRINT_ACTIVE=0 exits 0" \
        "0" "$exit_code"

    # Audit log: at least one file must exist in DSO_ARTIFACTS_DIR after the run
    local audit_file_count
    audit_file_count=$(find "$_artifacts_dir" -maxdepth 2 -type f 2>/dev/null | wc -l | tr -d ' ')
    assert_ne \
        "test_dso_sprint_active_override_exits_0_and_writes_audit_log: audit log written to artifacts dir" \
        "0" "$audit_file_count"
}

# ── Test 4: no .sprint-active marker → accepted ───────────────────────────────
# Setup: temp git repo WITHOUT .sprint-active
# Expected: script exits 0 (hook is inactive in non-sprint mode)
test_no_sprint_active_marker_accepted() {
    local _repo
    _repo=$(make_git_repo_with_commit)

    # Explicitly ensure no .sprint-active is present
    rm -f "$_repo/.sprint-active"

    local exit_code=0
    ( cd "$_repo" && bash "$_SCRIPT" 2>/dev/null ) || exit_code=$?

    assert_eq \
        "test_no_sprint_active_marker_accepted: no .sprint-active exits 0" \
        "0" "$exit_code"
}

# ── Test 5: .debug-active alone rejects non-merge commit ──────────────────────
test_debug_active_alone_rejects_non_merge() {
    local _repo
    _repo=$(make_linked_worktree)
    touch "$_repo/.debug-active"
    # No .sprint-active
    local exit_code=0
    ( cd "$_repo" && bash "$_SCRIPT" 2>/dev/null ) || exit_code=$?
    assert_ne \
        "test_debug_active_alone_rejects_non_merge: .debug-active alone rejects non-merge commit" \
        "0" "$exit_code"
}

# ── Test 6: .debug-active + MERGE_HEAD → accepted ─────────────────────────────
test_debug_active_with_merge_commit_accepted() {
    local _repo
    _repo=$(make_git_repo_with_commit)
    touch "$_repo/.debug-active"
    printf 'deadbeefdeadbeefdeadbeefdeadbeefdeadbeef\n' > "$_repo/.git/MERGE_HEAD"
    local exit_code=0
    ( cd "$_repo" && bash "$_SCRIPT" 2>/dev/null ) || exit_code=$?
    assert_eq \
        "test_debug_active_with_merge_commit_accepted: .debug-active + merge commit exits 0" \
        "0" "$exit_code"
}

# ── Test 7: DSO_DEBUG_ACTIVE=0 bypass → exit 0 + audit log ────────────────────
test_dso_debug_active_override_exits_0_and_writes_audit_log() {
    local _repo _artifacts_dir
    _repo=$(make_linked_worktree)
    _artifacts_dir=$(mktemp -d)
    _TEST_TMPDIRS+=("$_artifacts_dir")
    touch "$_repo/.debug-active"
    local exit_code=0
    (
        cd "$_repo"
        DSO_DEBUG_ACTIVE=0 DSO_ARTIFACTS_DIR="$_artifacts_dir" bash "$_SCRIPT" 2>/dev/null
    ) || exit_code=$?
    assert_eq \
        "test_dso_debug_active_override_exits_0_and_writes_audit_log: DSO_DEBUG_ACTIVE=0 exits 0" \
        "0" "$exit_code"
    local audit_file_count
    audit_file_count=$(find "$_artifacts_dir" -maxdepth 2 -type f 2>/dev/null | wc -l | tr -d ' ')
    assert_ne \
        "test_dso_debug_active_override_exits_0_and_writes_audit_log: audit log written" \
        "0" "$audit_file_count"
}

# ── Test 8: both markers, only DSO_SPRINT_ACTIVE=0 → still rejected ───────────
test_both_markers_sprint_escape_only_still_rejects() {
    local _repo
    _repo=$(make_linked_worktree)
    touch "$_repo/.sprint-active"
    touch "$_repo/.debug-active"
    local exit_code=0
    (
        cd "$_repo"
        DSO_SPRINT_ACTIVE=0 bash "$_SCRIPT" 2>/dev/null
    ) || exit_code=$?
    assert_ne \
        "test_both_markers_sprint_escape_only_still_rejects: both markers, sprint escape only still rejects" \
        "0" "$exit_code"
}

# ── Test 10: main repo (primary checkout) with .sprint-active → accepted ─────
# Bug 6e96-61bf: when merge-to-main.sh runs the post-merge version-bump commit
# in MAIN_REPO, the hook fires from MAIN_REPO context (shared .git/hooks).
# A stale .sprint-active marker at MAIN_REPO must NOT trigger rejection —
# the hook's enforcement target is linked worktrees, not the primary checkout.
test_main_repo_with_sprint_active_accepted() {
    local _repo
    _repo=$(make_git_repo_with_commit)

    # Primary checkout (no `git worktree add`): git-common-dir == git-dir.
    touch "$_repo/.sprint-active"

    local exit_code=0
    ( cd "$_repo" && bash "$_SCRIPT" 2>/dev/null ) || exit_code=$?

    assert_eq \
        "test_main_repo_with_sprint_active_accepted: primary checkout with .sprint-active exits 0 (hook only enforces in linked worktrees)" \
        "0" "$exit_code"
}

# ── Test 9: both markers + both env vars = 0 → accepted ───────────────────────
test_both_markers_both_escapes_accepted() {
    local _repo _artifacts_dir
    _repo=$(make_git_repo_with_commit)
    _artifacts_dir=$(mktemp -d)
    _TEST_TMPDIRS+=("$_artifacts_dir")
    touch "$_repo/.sprint-active"
    touch "$_repo/.debug-active"
    local exit_code=0
    (
        cd "$_repo"
        DSO_SPRINT_ACTIVE=0 DSO_DEBUG_ACTIVE=0 DSO_ARTIFACTS_DIR="$_artifacts_dir" bash "$_SCRIPT" 2>/dev/null
    ) || exit_code=$?
    assert_eq \
        "test_both_markers_both_escapes_accepted: both markers both env vars 0 exits 0" \
        "0" "$exit_code"
}

# ── Run all tests ─────────────────────────────────────────────────────────────
echo "=== test-check-session-merge-only ==="
echo ""

echo "--- Test 1: non-merge commit + .sprint-active → rejected ---"
test_non_merge_with_sprint_active_rejected
echo ""

echo "--- Test 2: merge commit + .sprint-active → accepted ---"
test_merge_commit_with_sprint_active_accepted
echo ""

echo "--- Test 3: DSO_SPRINT_ACTIVE=0 + .sprint-active → exit 0 + audit log ---"
test_dso_sprint_active_override_exits_0_and_writes_audit_log
echo ""

echo "--- Test 4: no .sprint-active → accepted ---"
test_no_sprint_active_marker_accepted
echo ""

echo "--- Test 5: .debug-active alone → rejected ---"
test_debug_active_alone_rejects_non_merge
echo ""

echo "--- Test 6: .debug-active + merge commit → accepted ---"
test_debug_active_with_merge_commit_accepted
echo ""

echo "--- Test 7: DSO_DEBUG_ACTIVE=0 + .debug-active → exit 0 + audit log ---"
test_dso_debug_active_override_exits_0_and_writes_audit_log
echo ""

echo "--- Test 8: both markers, sprint escape only → still rejects ---"
test_both_markers_sprint_escape_only_still_rejects
echo ""

echo "--- Test 9: both markers, both escapes → accepted ---"
test_both_markers_both_escapes_accepted
echo ""

echo "--- Test 10: main repo (primary checkout) + .sprint-active → accepted ---"
test_main_repo_with_sprint_active_accepted
echo ""

print_summary
