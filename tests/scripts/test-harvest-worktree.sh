#!/usr/bin/env bash
# tests/scripts/test-harvest-worktree.sh
# RED tests for plugins/dso/scripts/harvest-worktree.sh
#
# harvest-worktree.sh merges a worktree branch into the session branch,
# validating gate artifacts (test-gate-status, review-status) before merging.
#
# Usage: bash tests/scripts/test-harvest-worktree.sh
#
# Tests:
#   1. test_clean_merge_produces_commit — happy path merge with passing gates
#   2. test_exit2_when_test_gate_missing — exits 2 when test-gate-status absent
#   3. test_exit2_when_review_status_missing — exits 2 when review-status absent
#   4. test_exit2_when_test_gate_failed — exits 2 when test-gate-status=failed
#   5. test_exit1_on_non_test_index_conflict — exits 1 on non-.test-index conflict
#   6. test_merge_head_cleaned_on_failure — MERGE_HEAD removed after failure
#   7. test_no_merge_head_on_entry — error if MERGE_HEAD already exists
#   8. test_attest_source_in_status_files — attested files include attest_source
#   9. test_trap_cleans_merge_head_on_signal — MERGE_HEAD cleaned on SIGTERM
#  10. test_already_merged_branch_noop — no-op when branch already merged
#  11. test_conflict_diagnostic_printed_to_stderr — conflicted filename in stderr (bug 0fc6-c970)
#  12. test_nonexistent_branch_exits1_with_message — non-conflict git failure exits 1 with message (bug 0fc6-c970)

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR" && git rev-parse --show-toplevel)"

source "$SCRIPT_DIR/../lib/assert.sh"

HARVEST_SCRIPT="$REPO_ROOT/plugins/dso/scripts/harvest-worktree.sh"

# ── Helpers ──────────────────────────────────────────────────────────────────

_TEST_TMPDIRS=()
_cleanup_tmpdirs() {
    for d in "${_TEST_TMPDIRS[@]}"; do
        rm -rf "$d" 2>/dev/null || true
    done
}
trap _cleanup_tmpdirs EXIT

make_tmpdir() {
    local d
    d=$(mktemp -d)
    _TEST_TMPDIRS+=("$d")
    echo "$d"
}

# Create a bare "remote" repo and a working clone with a session branch,
# plus a worktree branch with a committed change and gate artifacts.
# Usage: setup_test_repo <tmpdir>
# Sets: SESSION_REPO, WORKTREE_BRANCH, ARTIFACTS_DIR
setup_test_repo() {
    local tmpdir="$1"
    local gate_status="${2:-passed}"  # test-gate-status value
    local review_status="${3:-passed}"  # review-status value
    local create_test_gate="${4:-yes}"
    local create_review="${5:-yes}"

    # Create a bare "origin"
    git init --bare "$tmpdir/origin.git" >/dev/null 2>&1

    # Clone it as the session repo
    git clone "$tmpdir/origin.git" "$tmpdir/session" >/dev/null 2>&1
    SESSION_REPO="$tmpdir/session"

    # Initial commit on main
    cd "$SESSION_REPO"
    git config user.email "test@test.com"
    git config user.name "Test"
    echo "initial" > file.txt
    git add file.txt
    git commit -m "initial commit" >/dev/null 2>&1
    git push origin HEAD:main >/dev/null 2>&1

    # Create session branch
    git checkout -b session-branch >/dev/null 2>&1

    # Create worktree branch from session-branch
    WORKTREE_BRANCH="worktree-test-$$-$RANDOM"
    git checkout -b "$WORKTREE_BRANCH" >/dev/null 2>&1

    # Make a change on the worktree branch
    echo "worktree change" > worktree-file.txt
    git add worktree-file.txt
    git commit -m "worktree change" >/dev/null 2>&1

    # Create artifacts directory for the worktree
    ARTIFACTS_DIR="$tmpdir/artifacts"
    mkdir -p "$ARTIFACTS_DIR"

    # Write gate artifacts
    local diff_hash
    diff_hash=$(git diff HEAD~1 HEAD | shasum -a 256 | cut -d' ' -f1)

    if [[ "$create_test_gate" == "yes" ]]; then
        cat > "$ARTIFACTS_DIR/test-gate-status" <<EOF
${gate_status}
diff_hash=${diff_hash}
timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)
tested_files=tests/scripts/test-example.sh
EOF
    fi

    if [[ "$create_review" == "yes" ]]; then
        cat > "$ARTIFACTS_DIR/review-status" <<EOF
${review_status}
timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)
diff_hash=${diff_hash}
score=4
review_hash=abc123def456
EOF
    fi

    # Switch back to session branch
    git checkout session-branch >/dev/null 2>&1
}

# =============================================================================
# Test 1: test_clean_merge_produces_commit
# Given: worktree branch with passing gate artifacts
# When: harvest-worktree.sh is invoked
# Then: merge commit is produced on session branch
# =============================================================================
echo "--- test_clean_merge_produces_commit ---"
_snapshot_fail

tmpdir=$(make_tmpdir)
setup_test_repo "$tmpdir" "passed" "passed"

commit_before=$(cd "$SESSION_REPO" && git rev-parse HEAD)

output=""
exit_code=0
output=$(cd "$SESSION_REPO" && bash "$HARVEST_SCRIPT" \
    "$WORKTREE_BRANCH" \
    "$ARTIFACTS_DIR" \
    2>&1) || exit_code=$?

assert_eq "clean merge exits 0" "0" "$exit_code"

# Verify a new commit was created (HEAD moved)
commit_after=$(cd "$SESSION_REPO" && git rev-parse HEAD)
assert_ne "HEAD moved after merge" "$commit_before" "$commit_after"

# Verify the merge brought the worktree file
assert_eq "worktree-file.txt exists after merge" "0" \
    "$(cd "$SESSION_REPO" && test -f worktree-file.txt && echo 0 || echo 1)"

assert_pass_if_clean "test_clean_merge_produces_commit"

# =============================================================================
# Test 2: test_exit2_when_test_gate_missing
# Given: worktree branch with NO test-gate-status artifact
# When: harvest-worktree.sh is invoked
# Then: exits 2
# =============================================================================
echo "--- test_exit2_when_test_gate_missing ---"
_snapshot_fail

tmpdir=$(make_tmpdir)
setup_test_repo "$tmpdir" "passed" "passed" "no" "yes"

exit_code=0
cd "$SESSION_REPO" && bash "$HARVEST_SCRIPT" \
    "$WORKTREE_BRANCH" \
    "$ARTIFACTS_DIR" \
    >/dev/null 2>&1 || exit_code=$?

assert_eq "missing test-gate-status exits 2" "2" "$exit_code"

assert_pass_if_clean "test_exit2_when_test_gate_missing"

# =============================================================================
# Test 3: test_exit2_when_review_status_missing
# Given: worktree branch with NO review-status artifact
# When: harvest-worktree.sh is invoked
# Then: exits 2
# =============================================================================
echo "--- test_exit2_when_review_status_missing ---"
_snapshot_fail

tmpdir=$(make_tmpdir)
setup_test_repo "$tmpdir" "passed" "passed" "yes" "no"

exit_code=0
cd "$SESSION_REPO" && bash "$HARVEST_SCRIPT" \
    "$WORKTREE_BRANCH" \
    "$ARTIFACTS_DIR" \
    >/dev/null 2>&1 || exit_code=$?

assert_eq "missing review-status exits 2" "2" "$exit_code"

assert_pass_if_clean "test_exit2_when_review_status_missing"

# =============================================================================
# Test 4: test_exit2_when_test_gate_failed
# Given: worktree branch with test-gate-status=failed
# When: harvest-worktree.sh is invoked
# Then: exits 2
# =============================================================================
echo "--- test_exit2_when_test_gate_failed ---"
_snapshot_fail

tmpdir=$(make_tmpdir)
setup_test_repo "$tmpdir" "failed" "passed"

exit_code=0
cd "$SESSION_REPO" && bash "$HARVEST_SCRIPT" \
    "$WORKTREE_BRANCH" \
    "$ARTIFACTS_DIR" \
    >/dev/null 2>&1 || exit_code=$?

assert_eq "failed test-gate-status exits 2" "2" "$exit_code"

assert_pass_if_clean "test_exit2_when_test_gate_failed"

# =============================================================================
# Test 5: test_exit1_on_non_test_index_conflict
# Given: session branch and worktree branch both modified same file (not .test-index)
# When: harvest-worktree.sh is invoked
# Then: exits 1 and merge is aborted
# =============================================================================
echo "--- test_exit1_on_non_test_index_conflict ---"
_snapshot_fail

tmpdir=$(make_tmpdir)
setup_test_repo "$tmpdir" "passed" "passed"

# Create a conflict: modify file.txt on session branch too
cd "$SESSION_REPO"
echo "session-side conflict content" > file.txt
git add file.txt
git commit -m "session conflict" >/dev/null 2>&1

# Also modify file.txt on worktree branch to create a real conflict
git checkout "$WORKTREE_BRANCH" >/dev/null 2>&1
echo "worktree-side conflict content" > file.txt
git add file.txt
git commit -m "worktree conflict" >/dev/null 2>&1
git checkout session-branch >/dev/null 2>&1

exit_code=0
cd "$SESSION_REPO" && bash "$HARVEST_SCRIPT" \
    "$WORKTREE_BRANCH" \
    "$ARTIFACTS_DIR" \
    >/dev/null 2>&1 || exit_code=$?

assert_eq "non-test-index conflict exits 1" "1" "$exit_code"

assert_pass_if_clean "test_exit1_on_non_test_index_conflict"

# =============================================================================
# Test 6: test_merge_head_cleaned_on_failure
# Given: a merge that will fail (missing gate artifact)
# When: harvest-worktree.sh exits with error
# Then: MERGE_HEAD does not exist in the repo
# =============================================================================
echo "--- test_merge_head_cleaned_on_failure ---"
_snapshot_fail

tmpdir=$(make_tmpdir)
setup_test_repo "$tmpdir" "passed" "passed" "no" "no"

exit_code=0
cd "$SESSION_REPO" && bash "$HARVEST_SCRIPT" \
    "$WORKTREE_BRANCH" \
    "$ARTIFACTS_DIR" \
    >/dev/null 2>&1 || exit_code=$?

# Script must exist and run (not exit 127)
assert_ne "script was found (not 127)" "127" "$exit_code"

merge_head_exists="no"
if [[ -f "$SESSION_REPO/.git/MERGE_HEAD" ]]; then
    merge_head_exists="yes"
fi
assert_eq "MERGE_HEAD cleaned after failure" "no" "$merge_head_exists"

assert_pass_if_clean "test_merge_head_cleaned_on_failure"

# =============================================================================
# Test 7: test_no_merge_head_on_entry
# Given: MERGE_HEAD already exists in the repo
# When: harvest-worktree.sh is invoked
# Then: exits with error (non-zero) without attempting merge
# =============================================================================
echo "--- test_no_merge_head_on_entry ---"
_snapshot_fail

tmpdir=$(make_tmpdir)
setup_test_repo "$tmpdir" "passed" "passed"

# Simulate stale MERGE_HEAD
cd "$SESSION_REPO"
git_dir=$(git rev-parse --git-dir)
echo "deadbeef" > "$git_dir/MERGE_HEAD"

exit_code=0
output=$(cd "$SESSION_REPO" && bash "$HARVEST_SCRIPT" \
    "$WORKTREE_BRANCH" \
    "$ARTIFACTS_DIR" \
    2>&1) || exit_code=$?

# Script must exist and run (not exit 127)
assert_ne "script was found (not 127)" "127" "$exit_code"
assert_ne "stale MERGE_HEAD causes non-zero exit" "0" "$exit_code"
assert_contains "error message mentions MERGE_HEAD" "MERGE_HEAD" "$output"

# Clean up stale MERGE_HEAD for safety
rm -f "$git_dir/MERGE_HEAD"

assert_pass_if_clean "test_no_merge_head_on_entry"

# =============================================================================
# Test 8: test_attest_source_in_status_files
# Given: worktree branch with passing gates
# When: harvest-worktree.sh completes successfully
# Then: attested status files in session artifacts contain attest_source field
# =============================================================================
echo "--- test_attest_source_in_status_files ---"
_snapshot_fail

tmpdir=$(make_tmpdir)
setup_test_repo "$tmpdir" "passed" "passed"

# Create a session artifacts dir for harvested results
SESSION_ARTIFACTS="$tmpdir/session-artifacts"
mkdir -p "$SESSION_ARTIFACTS"

exit_code=0
cd "$SESSION_REPO" && bash "$HARVEST_SCRIPT" \
    "$WORKTREE_BRANCH" \
    "$ARTIFACTS_DIR" \
    --session-artifacts "$SESSION_ARTIFACTS" \
    2>&1 || exit_code=$?

assert_eq "attest merge exits 0" "0" "$exit_code"

# Check that attested status files contain attest_source
test_gate_has_attest="no"
if [[ -f "$SESSION_ARTIFACTS/test-gate-status" ]]; then
    if grep -q "attest_source=" "$SESSION_ARTIFACTS/test-gate-status"; then
        test_gate_has_attest="yes"
    fi
fi
assert_eq "test-gate-status has attest_source" "yes" "$test_gate_has_attest"

review_has_attest="no"
if [[ -f "$SESSION_ARTIFACTS/review-status" ]]; then
    if grep -q "attest_source=" "$SESSION_ARTIFACTS/review-status"; then
        review_has_attest="yes"
    fi
fi
assert_eq "review-status has attest_source" "yes" "$review_has_attest"

assert_pass_if_clean "test_attest_source_in_status_files"

# =============================================================================
# Test 9: test_trap_cleans_merge_head_on_signal
# Given: harvest-worktree.sh is running a merge
# When: the process receives SIGTERM
# Then: MERGE_HEAD is cleaned up and index is restored
# =============================================================================
echo "--- test_trap_cleans_merge_head_on_signal ---"
_snapshot_fail

tmpdir=$(make_tmpdir)
setup_test_repo "$tmpdir" "passed" "passed"

# We create a wrapper that introduces a sleep so we can send SIGTERM
cat > "$tmpdir/slow-harvest.sh" <<'WRAPPER'
#!/usr/bin/env bash
# Source the real script's trap setup, then sleep to allow signal delivery
HARVEST_SCRIPT="$1"; shift
# Run harvest in background, capture PID
bash "$HARVEST_SCRIPT" "$@" &
HARVEST_PID=$!
# Give it a moment to start the merge
sleep 0.5
# Send SIGTERM
kill -TERM $HARVEST_PID 2>/dev/null || true
wait $HARVEST_PID 2>/dev/null || true
WRAPPER
chmod +x "$tmpdir/slow-harvest.sh"

# Pre-check: script must exist to test signal handling
if [[ ! -f "$HARVEST_SCRIPT" ]]; then
    (( ++FAIL ))
    printf "FAIL: %s\n  %s\n" "harvest-worktree.sh must exist for signal test" "script not found at $HARVEST_SCRIPT" >&2
else
    cd "$SESSION_REPO" && bash "$tmpdir/slow-harvest.sh" \
        "$HARVEST_SCRIPT" \
        "$WORKTREE_BRANCH" \
        "$ARTIFACTS_DIR" \
        >/dev/null 2>&1 || true

    merge_head_after_signal="no"
    if [[ -f "$SESSION_REPO/.git/MERGE_HEAD" ]]; then
        merge_head_after_signal="yes"
    fi
    assert_eq "MERGE_HEAD cleaned after SIGTERM" "no" "$merge_head_after_signal"
fi

assert_pass_if_clean "test_trap_cleans_merge_head_on_signal"

# =============================================================================
# Test 10: test_already_merged_branch_noop
# Given: worktree branch is already merged into session branch
# When: harvest-worktree.sh is invoked
# Then: exits 0 gracefully (no-op)
# =============================================================================
echo "--- test_already_merged_branch_noop ---"
_snapshot_fail

tmpdir=$(make_tmpdir)
setup_test_repo "$tmpdir" "passed" "passed"

# Merge the worktree branch manually first
cd "$SESSION_REPO"
git merge "$WORKTREE_BRANCH" --no-edit >/dev/null 2>&1

# Now invoke harvest — branch is already merged
exit_code=0
output=$(cd "$SESSION_REPO" && bash "$HARVEST_SCRIPT" \
    "$WORKTREE_BRANCH" \
    "$ARTIFACTS_DIR" \
    2>&1) || exit_code=$?

assert_eq "already-merged branch exits 0" "0" "$exit_code"

assert_pass_if_clean "test_already_merged_branch_noop"

# =============================================================================
# Test 11: test_conflict_diagnostic_printed_to_stderr (bug 0fc6-c970)
# Given: session branch and worktree branch both modified same file (not .test-index)
# When: harvest-worktree.sh exits 1 on conflict
# Then: stderr includes the conflicted filename so the operator knows what to fix
# =============================================================================
echo "--- test_conflict_diagnostic_printed_to_stderr ---"
_snapshot_fail

tmpdir=$(make_tmpdir)
setup_test_repo "$tmpdir" "passed" "passed"

# Create a conflict: modify file.txt on session branch
cd "$SESSION_REPO"
echo "session-side conflict content" > file.txt
git add file.txt
git commit -m "session conflict" >/dev/null 2>&1

# Also modify file.txt on worktree branch to create a real conflict
git checkout "$WORKTREE_BRANCH" >/dev/null 2>&1
echo "worktree-side conflict content" > file.txt
git add file.txt
git commit -m "worktree conflict" >/dev/null 2>&1
git checkout session-branch >/dev/null 2>&1

# Capture stderr to check diagnostic output
stderr_output=""
exit_code=0
stderr_output=$(cd "$SESSION_REPO" && bash "$HARVEST_SCRIPT" \
    "$WORKTREE_BRANCH" \
    "$ARTIFACTS_DIR" \
    2>&1 >/dev/null) || exit_code=$?

assert_eq "conflict exits 1" "1" "$exit_code"

# Verify that the conflicted filename appears in the diagnostic output
if echo "$stderr_output" | grep -q "file.txt"; then
    (( ++PASS ))
    echo "PASS: conflict diagnostic includes conflicted filename"
else
    (( ++FAIL ))
    echo "FAIL: conflict diagnostic missing conflicted filename in stderr" >&2
    echo "  stderr was: $stderr_output" >&2
fi

assert_pass_if_clean "test_conflict_diagnostic_printed_to_stderr"

# =============================================================================
# Test 12: test_nonexistent_branch_exits1_with_message (bug 0fc6-c970)
# Given: worktree branch name that does not exist (non-conflict git failure)
# When: harvest-worktree.sh is invoked
# Then: exits 1 and stderr includes "git merge failed" (not silent exit 0)
# =============================================================================
echo "--- test_nonexistent_branch_exits1_with_message ---"
_snapshot_fail

tmpdir=$(make_tmpdir)
setup_test_repo "$tmpdir" "passed" "passed"

# Use a branch name guaranteed not to exist
MISSING_BRANCH="nonexistent-branch-$$"

stderr_output=""
exit_code=0
stderr_output=$(cd "$SESSION_REPO" && bash "$HARVEST_SCRIPT" \
    "$MISSING_BRANCH" \
    "$ARTIFACTS_DIR" \
    2>&1 >/dev/null) || exit_code=$?

assert_eq "nonexistent branch exits 1" "1" "$exit_code"

if echo "$stderr_output" | grep -q "git merge failed"; then
    (( ++PASS ))
    echo "PASS: nonexistent branch produces git merge failed message"
else
    (( ++FAIL ))
    echo "FAIL: nonexistent branch did not produce git merge failed message" >&2
    echo "  stderr was: $stderr_output" >&2
fi

assert_pass_if_clean "test_nonexistent_branch_exits1_with_message"

# =============================================================================
print_summary
