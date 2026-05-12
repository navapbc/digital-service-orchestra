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
    _repo=$(make_git_repo_with_commit)

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
    _repo=$(make_git_repo_with_commit)
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

print_summary
